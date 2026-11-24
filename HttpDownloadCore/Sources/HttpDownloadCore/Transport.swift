import Foundation

/// One ranged (or whole-file) request for a chunk, handed to the transport.
public struct ChunkRequestSpec: Sendable, Equatable {
    public var downloadID: UUID
    public var chunkIndex: Int
    public var url: URL
    /// nil = request the whole resource without a `Range` header.
    public var range: ClosedRange<Int64>?
    public var ifRange: String?
    public var headers: [String: String]
    public var allowsCellular: Bool
    /// Where the transport must leave the downloaded body (a file in the parts folder).
    public var destination: URL
    /// Identifies this one request. Every event echoes it, so late events of a cancelled request are ignored.
    public var token: UUID

    public init(downloadID: UUID, chunkIndex: Int, url: URL, range: ClosedRange<Int64>?, ifRange: String?,
                headers: [String: String], allowsCellular: Bool, destination: URL, token: UUID = UUID()) {
        self.downloadID = downloadID; self.chunkIndex = chunkIndex; self.url = url; self.range = range
        self.ifRange = ifRange; self.headers = headers; self.allowsCellular = allowsCellular
        self.destination = destination; self.token = token
    }
}

public struct TransportFailure: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case cancelled, connectivity, insecureRedirect, other }
    public var kind: Kind
    public var message: String
    public init(kind: Kind, message: String) { self.kind = kind; self.message = message }
}

public enum TransportEvent: Sendable {
    case progress(id: UUID, chunk: Int, token: UUID, bytesReceived: Int64)
    /// The request completed at HTTP level. For 2xx answers the body is at `destination` (`fileSize` bytes);
    /// for anything else no file is kept and `fileSize` is 0.
    case finished(id: UUID, chunk: Int, token: UUID, response: HTTPResponseInfo, fileSize: Int64)
    case failed(id: UUID, chunk: Int, token: UUID, failure: TransportFailure)
}

public struct LiveChunk: Sendable, Hashable {
    public var key: LiveChunkKey
    public var token: UUID
    public init(key: LiveChunkKey, token: UUID) { self.key = key; self.token = token }
}

public struct ProbeResponses: Sendable {
    public var head: HTTPResponseInfo?
    public var rangeProbe: HTTPResponseInfo?
    public init(head: HTTPResponseInfo?, rangeProbe: HTTPResponseInfo?) { self.head = head; self.rangeProbe = rangeProbe }
}

/// The only part of the engine that touches the network. The production implementation uses a background
/// `URLSession`; tests use an in-memory fake server.
public protocol HttpTransport: AnyObject, Sendable {
    /// `HEAD` and `GET Range: bytes=0-0`, both with `Accept-Encoding: identity`. Nil = no answer.
    func probe(url: URL, headers: [String: String], allowsCellular: Bool) async -> ProbeResponses
    func start(_ spec: ChunkRequestSpec)
    /// `chunk == nil` cancels every request of that download.
    func cancel(downloadID: UUID, chunk: Int?)
    /// Requests the operating system still has running (after an app relaunch), with their tokens.
    func liveChunks() async -> Set<LiveChunk>
    var events: AsyncStream<TransportEvent> { get }
}

public protocol ManagerClock: Sendable {
    /// Monotonic seconds, for speed calculations.
    func now() -> TimeInterval
    func date() -> Date
}

public struct SystemManagerClock: ManagerClock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func date() -> Date { Date() }
}

public enum HttpDownloadError: Error, Equatable {
    case unsupportedURL
    case insecureNotAllowed
    case duplicate(existing: UUID)
    case unknownDownload(UUID)
    case invalidState(String)
}
