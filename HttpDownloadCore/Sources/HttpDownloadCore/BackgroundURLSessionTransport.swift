import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DownloadSupport

#if canImport(Darwin) || canImport(FoundationNetworking)

/// Production transport: one background `URLSession` shared by all HTTP downloads.
///
/// - Every chunk is one download task whose `taskDescription` is `"<downloadID>|<chunk>|<token>"`.
///   URLSession persists that string, so after an app relaunch (or a launch caused by the OS finishing
///   transfers) tasks can be matched to chunks without any separate manifest.
/// - TLS certificate validation is the system default: no authentication-challenge handler is installed.
/// - Requests use `Accept-Encoding: identity`, so byte counts and `Content-Range` describe the real file.
/// - A redirect from https to http is refused unless explicitly allowed.
/// - iOS decides when a background transfer runs and may stop it; it does not continue after the user
///   force-quits the app. The manager recovers such chunks on the next launch.
public final class BackgroundURLSessionTransport: NSObject, HttpTransport, URLSessionDownloadDelegate, @unchecked Sendable {
    public typealias PartURLProvider = @Sendable (UUID, Int) -> URL

    public let sessionIdentifier: String
    private let useBackgroundSession: Bool
    private let partURL: PartURLProvider
    private let allowInsecureRedirects: Bool

    private let lock = NSLock()
    private var started: [LiveChunkKey: UUID] = [:]
    private var cancelled: Set<UUID> = []
    private var finished: Set<UUID> = []
    private var blockedRedirects: Set<UUID> = []
    private var lastProgress: [UUID: (time: Date, bytes: Int64)] = [:]
    private var eventsCompletion: (@Sendable () -> Void)?
    private var _session: URLSession?
    private let delegateQueue: OperationQueue

    private let continuation: AsyncStream<TransportEvent>.Continuation
    public let events: AsyncStream<TransportEvent>

    /// - Parameter useBackgroundSession: `false` uses an ordinary session (for tests, which have no app bundle).
    public init(sessionIdentifier: String, useBackgroundSession: Bool = true, allowInsecureRedirects: Bool = false,
                partURL: @escaping PartURLProvider) {
        self.sessionIdentifier = sessionIdentifier
        self.useBackgroundSession = useBackgroundSession
        self.allowInsecureRedirects = allowInsecureRedirects
        self.partURL = partURL
        self.delegateQueue = OperationQueue()
        self.delegateQueue.maxConcurrentOperationCount = 1
        self.delegateQueue.name = "HttpDownloadCore.transport"
        var cont: AsyncStream<TransportEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
        super.init()
    }

    /// Creating the session is what makes iOS deliver events of transfers that finished while the app was not
    /// running, so call this as early as possible at launch.
    public func activate() { _ = session }

    private var session: URLSession {
        lock.lock(); defer { lock.unlock() }
        if let s = _session { return s }
        let cfg: URLSessionConfiguration
        #if canImport(Darwin)
        if useBackgroundSession {
            cfg = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
            cfg.sessionSendsLaunchEvents = true
            cfg.isDiscretionary = false
        } else {
            cfg = URLSessionConfiguration.default
        }
        cfg.waitsForConnectivity = true
        #else
        cfg = URLSessionConfiguration.default          // non-Darwin hosts only type-check this file; the app runs on iOS
        #endif
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)
        _session = s
        return s
    }

    /// Call from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public func setBackgroundEventsCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); eventsCompletion = handler; lock.unlock()
        activate()
    }

    // MARK: HttpTransport

    public func probe(url: URL, headers: [String: String], allowsCellular: Bool) async -> ProbeResponses {
        async let head = Self.probeRequest(url: url, headers: headers, method: "HEAD", range: nil, cellular: allowsCellular, allowInsecureRedirects: allowInsecureRedirects)
        async let ranged = Self.probeRequest(url: url, headers: headers, method: "GET", range: "bytes=0-0", cellular: allowsCellular, allowInsecureRedirects: allowInsecureRedirects)
        return ProbeResponses(head: await head, rangeProbe: await ranged)
    }

    public func start(_ spec: ChunkRequestSpec) {
        var request = URLRequest(url: spec.url)
        request.httpMethod = "GET"
        for (k, v) in spec.headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let r = spec.range {
            request.setValue("bytes=\(r.lowerBound)-\(r.upperBound)", forHTTPHeaderField: "Range")
            if let ir = spec.ifRange { request.setValue(ir, forHTTPHeaderField: "If-Range") }
        }
        request.allowsCellularAccess = spec.allowsCellular
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.downloadTask(with: request)
        task.taskDescription = Self.encode(id: spec.downloadID, chunk: spec.chunkIndex, token: spec.token)
        lock.lock(); started[LiveChunkKey(id: spec.downloadID, index: spec.chunkIndex)] = spec.token; lock.unlock()
        task.resume()
    }

    public func cancel(downloadID: UUID, chunk: Int?) {
        lock.lock()
        for (key, token) in started where key.id == downloadID && (chunk == nil || key.index == chunk) {
            cancelled.insert(token); started[key] = nil
        }
        lock.unlock()
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            for t in tasks {
                guard let d = Self.decode(t.taskDescription), d.id == downloadID, chunk == nil || d.chunk == chunk else { continue }
                self.lock.lock(); self.cancelled.insert(d.token); self.lock.unlock()
                t.cancel()
            }
        }
    }

    public func liveChunks() async -> Set<LiveChunk> {
        let session = self.session
        return await withCheckedContinuation { cont in
            session.getAllTasks { tasks in
                var out = Set<LiveChunk>()
                for t in tasks where t.state == .running || t.state == .suspended {
                    if let d = Self.decode(t.taskDescription) {
                        out.insert(LiveChunk(key: LiveChunkKey(id: d.id, index: d.chunk), token: d.token))
                    }
                }
                cont.resume(returning: out)
            }
        }
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let d = Self.decode(downloadTask.taskDescription) else { return }
        let now = Date()
        lock.lock()
        let last = lastProgress[d.token]
        let due = last == nil || now.timeIntervalSince(last!.time) >= 0.25 || totalBytesWritten - last!.bytes >= 512 * 1024
        if due { lastProgress[d.token] = (now, totalBytesWritten) }
        let skip = cancelled.contains(d.token)
        lock.unlock()
        if due && !skip {
            continuation.yield(.progress(id: d.id, chunk: d.chunk, token: d.token, bytesReceived: totalBytesWritten))
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let d = Self.decode(downloadTask.taskDescription) else { return }
        lock.lock()
        let wasCancelled = cancelled.contains(d.token)
        let blocked = blockedRedirects.contains(d.token)
        finished.insert(d.token)
        started[LiveChunkKey(id: d.id, index: d.chunk)] = nil
        lastProgress[d.token] = nil
        lock.unlock()
        if wasCancelled { return }                                   // never write files for cancelled requests
        if blocked {
            continuation.yield(.failed(id: d.id, chunk: d.chunk, token: d.token,
                                       failure: TransportFailure(kind: .insecureRedirect, message: "redirect to http was blocked")))
            return
        }
        guard let http = downloadTask.response as? HTTPURLResponse else {
            continuation.yield(.failed(id: d.id, chunk: d.chunk, token: d.token, failure: TransportFailure(kind: .other, message: "no HTTP response")))
            return
        }
        let info = Self.info(from: http)
        var size: Int64 = 0
        if http.statusCode == 200 || http.statusCode == 206 {
            let fm = FileManager.default
            let destination = partURL(d.id, d.chunk)
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: location, to: destination)        // must happen before this callback returns
                size = (try fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            } catch {
                continuation.yield(.failed(id: d.id, chunk: d.chunk, token: d.token,
                                           failure: TransportFailure(kind: .other, message: "could not store the downloaded chunk: \(error.localizedDescription)")))
                return
            }
        }
        continuation.yield(.finished(id: d.id, chunk: d.chunk, token: d.token, response: info, fileSize: size))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let d = Self.decode(task.taskDescription) else { return }
        lock.lock()
        let wasFinished = finished.remove(d.token) != nil
        let wasCancelled = cancelled.remove(d.token) != nil
        blockedRedirects.remove(d.token)
        started[LiveChunkKey(id: d.id, index: d.chunk)] = nil
        lastProgress[d.token] = nil
        lock.unlock()
        guard let error, !wasFinished, !wasCancelled else { return }
        let ns = error as NSError
        let kind: TransportFailure.Kind
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCancelled: kind = .cancelled
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                 NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff: kind = .connectivity
            default: kind = .other
            }
        } else { kind = .other }
        continuation.yield(.failed(id: d.id, chunk: d.chunk, token: d.token,
                                   failure: TransportFailure(kind: kind, message: "\(ns.domain) \(ns.code): \(URLRedaction.redactingURLs(in: ns.localizedDescription))")))
    }

    /// Refuse https -> http downgrades; never forward credentials to a different host.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let fromScheme = task.originalRequest?.url?.scheme?.lowercased()
        let toScheme = request.url?.scheme?.lowercased()
        if fromScheme == "https", toScheme == "http", !allowInsecureRedirects {
            if let d = Self.decode(task.taskDescription) { lock.lock(); blockedRedirects.insert(d.token); lock.unlock() }
            completionHandler(nil)
            return
        }
        var next = request
        if task.originalRequest?.url?.host != request.url?.host {
            for name in URLRedaction.sensitiveHeaderNames { next.setValue(nil, forHTTPHeaderField: name) }
        }
        completionHandler(next)
    }

    #if canImport(Darwin)
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock(); let handler = eventsCompletion; eventsCompletion = nil; lock.unlock()
        if let handler { DispatchQueue.main.async { handler() } }
    }
    #endif

    // MARK: helpers

    static func encode(id: UUID, chunk: Int, token: UUID) -> String { "\(id.uuidString)|\(chunk)|\(token.uuidString)" }

    static func decode(_ description: String?) -> (id: UUID, chunk: Int, token: UUID)? {
        guard let parts = description?.split(separator: "|"), parts.count == 3,
              let id = UUID(uuidString: String(parts[0])), let chunk = Int(parts[1]), let token = UUID(uuidString: String(parts[2])) else { return nil }
        return (id, chunk, token)
    }

    static func info(from r: HTTPURLResponse) -> HTTPResponseInfo {
        var headers: [String: String] = [:]
        for (k, v) in r.allHeaderFields { if let k = k as? String, let v = v as? String { headers[k] = v } }
        return HTTPResponseInfo(statusCode: r.statusCode, headers: headers, url: r.url)
    }

    /// Reads only the response headers (the body is cancelled as soon as headers arrive, so a server that ignores
    /// `Range` can never make us download or buffer the whole file during a probe).
    private static func probeRequest(url: URL, headers: [String: String], method: String, range: String?,
                                     cellular: Bool, allowInsecureRedirects: Bool) async -> HTTPResponseInfo? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.allowsCellularAccess = cellular
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }

        let collector = ProbeCollector(allowInsecureRedirects: allowInsecureRedirects)
        let session = URLSession(configuration: .ephemeral, delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return await withCheckedContinuation { cont in
            collector.install(cont)
            session.dataTask(with: request).resume()
        }
    }
}

private final class ProbeCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<HTTPResponseInfo?, Never>?
    private let allowInsecureRedirects: Bool

    init(allowInsecureRedirects: Bool) { self.allowInsecureRedirects = allowInsecureRedirects }

    func install(_ c: CheckedContinuation<HTTPResponseInfo?, Never>) { lock.lock(); continuation = c; lock.unlock() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); self.response = response as? HTTPURLResponse; lock.unlock()
        completionHandler(.cancel)                                  // headers are all we need
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if task.originalRequest?.url?.scheme?.lowercased() == "https", request.url?.scheme?.lowercased() == "http", !allowInsecureRedirects {
            completionHandler(nil); return
        }
        var next = request
        if task.originalRequest?.url?.host != request.url?.host {
            for name in URLRedaction.sensitiveHeaderNames { next.setValue(nil, forHTTPHeaderField: name) }
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let c = continuation; continuation = nil
        let r = response
        lock.unlock()
        c?.resume(returning: r.map { BackgroundURLSessionTransport.info(from: $0) })
    }
}

#endif
