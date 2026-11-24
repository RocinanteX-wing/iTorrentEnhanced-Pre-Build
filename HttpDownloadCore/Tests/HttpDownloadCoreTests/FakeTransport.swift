import Foundation
import DownloadSupport
@testable import HttpDownloadCore

/// An in-memory HTTP server that understands Range / If-Range / validators and can misbehave on demand.
final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    var data: Data
    var etag: String? = "\"v1\""
    var lastModified: String? = "Mon, 01 Jan 2024 00:00:00 GMT"
    var supportsRanges = true
    var ignoreRangeForChunks = false      // probe says "206" but real requests get 200 + full body
    var wrongContentRange = false
    var knownLength = true
    var contentDisposition: String?
    var forcedStatuses: [Int] = []        // consumed one per chunk request: [503, 503] = two failures first
    var connectionFailures = 0            // number of chunk requests that die with a network error
    private(set) var rangeLog: [ClosedRange<Int64>?] = []

    init(size: Int) { data = FakeServer.makeData(size) }
    /// Position-dependent test data, built block-wise so that tens of MiB are cheap even in a debug build:
    /// every 4 KiB block has its own fill byte and a 16-byte header derived from the block number, so a misordered,
    /// duplicated or shifted chunk changes the bytes.
    static func makeData(_ n: Int, seed: Int = 7) -> Data {
        var d = Data(count: n)
        d.withUnsafeMutableBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var block = 0, i = 0
            while i < n {
                let end = min(i + 4096, n)
                memset(p + i, Int32(UInt8(truncatingIfNeeded: block &* 31 &+ seed)), end - i)
                for k in 0..<min(16, end - i) { p[i + k] = UInt8(truncatingIfNeeded: (block &+ k) &* 131 &+ seed) }
                i = end; block += 1
            }
        }
        return d
    }

    func setData(_ d: Data, etag: String?) { lock.lock(); data = d; self.etag = etag; lock.unlock() }
    func mutate(_ body: (FakeServer) -> Void) { lock.lock(); body(self); lock.unlock() }

    private func baseHeaders() -> [String: String] {
        var h: [String: String] = [:]
        if let e = etag { h["ETag"] = e }
        if let l = lastModified { h["Last-Modified"] = l }
        if let cd = contentDisposition { h["Content-Disposition"] = cd }
        return h
    }

    func probe() -> ProbeResponses {
        lock.lock(); defer { lock.unlock() }
        var head = baseHeaders()
        if knownLength { head["Content-Length"] = "\(data.count)" }
        if supportsRanges { head["Accept-Ranges"] = "bytes" }
        let headResp = HTTPResponseInfo(statusCode: 200, headers: head)
        var rp = baseHeaders()
        if supportsRanges && data.count > 0 {
            rp["Content-Range"] = "bytes 0-0/\(knownLength ? "\(data.count)" : "*")"; rp["Content-Length"] = "1"
            return ProbeResponses(head: headResp, rangeProbe: HTTPResponseInfo(statusCode: 206, headers: rp))
        }
        if knownLength { rp["Content-Length"] = "\(data.count)" }
        return ProbeResponses(head: headResp, rangeProbe: HTTPResponseInfo(statusCode: 200, headers: rp))
    }

    enum Outcome { case connectionError, response(HTTPResponseInfo, Data) }

    func outcome(for spec: ChunkRequestSpec) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        rangeLog.append(spec.range)
        if connectionFailures > 0 { connectionFailures -= 1; return .connectionError }
        if !forcedStatuses.isEmpty { return .response(HTTPResponseInfo(statusCode: forcedStatuses.removeFirst()), Data()) }
        var h = baseHeaders()
        let total = data.count
        if let range = spec.range, supportsRanges, !ignoreRangeForChunks {
            if let ir = spec.ifRange, ir != etag, ir != lastModified {           // validator mismatch: full new representation
                h["Content-Length"] = "\(total)"
                return .response(HTTPResponseInfo(statusCode: 200, headers: h), data)
            }
            let lo = Int(range.lowerBound)
            if lo >= total { return .response(HTTPResponseInfo(statusCode: 416, headers: ["Content-Range": "bytes */\(total)"]), Data()) }
            let hi = min(Int(range.upperBound), total - 1)
            h["Content-Range"] = wrongContentRange ? "bytes \(lo + 1)-\(hi + 1)/\(total)" : "bytes \(lo)-\(hi)/\(total)"
            h["Content-Length"] = "\(hi - lo + 1)"
            return .response(HTTPResponseInfo(statusCode: 206, headers: h), data.subdata(in: lo..<(hi + 1)))
        }
        if knownLength { h["Content-Length"] = "\(total)" }
        return .response(HTTPResponseInfo(statusCode: 200, headers: h), data)
    }
}

final class FakeTransport: HttpTransport, @unchecked Sendable {
    struct Key: Hashable { var id: UUID; var chunk: Int }
    private let lock = NSLock()
    let server: FakeServer
    private let cont: AsyncStream<TransportEvent>.Continuation
    let events: AsyncStream<TransportEvent>
    /// false = requests stay pending until `release` is called (to test concurrency, pause, relaunch)
    var autoComplete = true
    private(set) var pending: [Key: ChunkRequestSpec] = [:]
    private(set) var maxConcurrent = 0
    private(set) var started: [ChunkRequestSpec] = []
    private(set) var cancelled: [UUID] = []
    var liveOnRelaunch: Set<LiveChunk> = []
    var probeOverride: ProbeResponses?

    init(server: FakeServer) {
        self.server = server
        var c: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { c = $0 }
        cont = c
    }

    func probe(url: URL, headers: [String: String], allowsCellular: Bool) async -> ProbeResponses { probeOverride ?? server.probe() }

    func start(_ spec: ChunkRequestSpec) {
        lock.lock()
        pending[Key(id: spec.downloadID, chunk: spec.chunkIndex)] = spec
        started.append(spec)
        maxConcurrent = max(maxConcurrent, pending.count)
        let auto = autoComplete
        lock.unlock()
        if auto { Task { self.release(spec.downloadID, spec.chunkIndex) } }
    }

    func cancel(downloadID: UUID, chunk: Int?) {
        lock.lock(); defer { lock.unlock() }
        cancelled.append(downloadID)
        for k in pending.keys where k.id == downloadID && (chunk == nil || chunk == k.chunk) { pending[k] = nil }
    }

    func liveChunks() async -> Set<LiveChunk> { liveOnRelaunch }
    var events_: AsyncStream<TransportEvent> { events }

    func pendingCount() -> Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    func pendingKeys() -> [Key] { lock.lock(); defer { lock.unlock() }; return Array(pending.keys) }
    func startedCount() -> Int { lock.lock(); defer { lock.unlock() }; return started.count }
    func startedSpecs() -> [ChunkRequestSpec] { lock.lock(); defer { lock.unlock() }; return started }

    /// Completes one pending request the way the server would answer it.
    func release(_ id: UUID, _ chunk: Int) {
        lock.lock()
        guard let spec = pending.removeValue(forKey: Key(id: id, chunk: chunk)) else { lock.unlock(); return }
        lock.unlock()
        switch server.outcome(for: spec) {
        case .connectionError:
            cont.yield(.failed(id: id, chunk: chunk, token: spec.token, failure: TransportFailure(kind: .connectivity, message: "The network connection was lost.")))
        case .response(let resp, let body):
            var size: Int64 = 0
            if (200..<300).contains(resp.statusCode) {
                try? FileManager.default.createDirectory(at: spec.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? body.write(to: spec.destination)
                size = Int64(body.count)
            }
            cont.yield(.progress(id: id, chunk: chunk, token: spec.token, bytesReceived: size))
            cont.yield(.finished(id: id, chunk: chunk, token: spec.token, response: resp, fileSize: size))
        }
    }

    func releaseAll() { for k in pendingKeys() { release(k.id, k.chunk) } }
    func emit(_ e: TransportEvent) { cont.yield(e) }
}
