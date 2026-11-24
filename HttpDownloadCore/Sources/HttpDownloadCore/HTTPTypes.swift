import Foundation
import DownloadSupport

/// A transport-independent view of an HTTP response. Header names are stored lower-cased.
public struct HTTPResponseInfo: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var url: URL?

    public init(statusCode: Int, headers: [String: String] = [:], url: URL? = nil) {
        self.statusCode = statusCode
        var lowered: [String: String] = [:]
        for (k, v) in headers { lowered[k.lowercased()] = v }
        self.headers = lowered
        self.url = url
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public var contentLength: Int64? {
        guard let raw = header("content-length"),
              let v = Int64(raw.trimmingCharacters(in: .whitespaces)), v >= 0 else { return nil }
        return v
    }

    /// True when the body is content-coded (gzip, br...), so lengths describe the encoded form.
    public var hasContentEncoding: Bool {
        guard let e = header("content-encoding")?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return !e.isEmpty && e != "identity"
    }
}

public enum ValidatorMatch: Equatable, Sendable { case same, different, unknown }

/// `ETag` / `Last-Modified`, used to detect that a file changed between pause and resume.
public struct Validators: Codable, Sendable, Equatable {
    public var etag: String?
    public var lastModified: String?

    public init(etag: String? = nil, lastModified: String? = nil) {
        self.etag = etag?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        self.lastModified = lastModified?.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    public init(response: HTTPResponseInfo) {
        self.init(etag: response.header("etag"), lastModified: response.header("last-modified"))
    }

    public var isEmpty: Bool { etag == nil && lastModified == nil }

    /// Value for an `If-Range` header: a *strong* ETag if there is one, else `Last-Modified`.
    /// (`If-Range` must not carry a weak ETag.)
    public var ifRangeValue: String? {
        if let e = etag, !e.hasPrefix("W/") { return e }
        return lastModified
    }

    public func compare(to other: Validators) -> ValidatorMatch {
        if let a = etag, let b = other.etag {
            return Validators.opaqueTag(a) == Validators.opaqueTag(b) ? .same : .different
        }
        if let a = lastModified, let b = other.lastModified { return a == b ? .same : .different }
        return .unknown
    }

    private static func opaqueTag(_ t: String) -> String { t.hasPrefix("W/") ? String(t.dropFirst(2)) : t }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public enum ConnectionLimits {
    public static let minimum = 1
    public static let maximum = 16
    public static let `default` = 4
    public static func clamp(_ n: Int) -> Int { min(max(n, minimum), maximum) }
}

public struct ChunkingConfig: Codable, Sendable, Equatable {
    public var preferredChunkSize: Int64
    public var minChunkSize: Int64
    public var maxChunkSize: Int64
    public var maxChunks: Int
    /// Below this size a file is fetched as one piece.
    public var minSizeForChunking: Int64
    /// Aim for at least this many chunks per connection, so a failed or slow connection never holds a big share.
    public var chunksPerConnection: Int

    public init(preferredChunkSize: Int64 = 8 << 20, minChunkSize: Int64 = 512 << 10, maxChunkSize: Int64 = 64 << 20,
                maxChunks: Int = 4096, minSizeForChunking: Int64 = 2 << 20, chunksPerConnection: Int = 2) {
        self.chunksPerConnection = max(1, chunksPerConnection)
        self.preferredChunkSize = max(1, preferredChunkSize)
        self.minChunkSize = max(1, minChunkSize)
        self.maxChunkSize = max(self.minChunkSize, maxChunkSize)
        self.maxChunks = max(1, maxChunks)
        self.minSizeForChunking = max(0, minSizeForChunking)
    }

    public static let `default` = ChunkingConfig()
}

public struct HttpDownloadSettings: Codable, Sendable, Equatable {
    public var defaultConnections: Int
    public var maxSimultaneousDownloads: Int
    /// Plain `http://` is allowed (every such item is flagged "Not encrypted").
    public var allowInsecureHTTP: Bool
    public var allowsCellular: Bool
    public var chunking: ChunkingConfig
    public var retry: RetryPolicy

    public init(defaultConnections: Int = ConnectionLimits.default, maxSimultaneousDownloads: Int = 3,
                allowInsecureHTTP: Bool = true, allowsCellular: Bool = false,
                chunking: ChunkingConfig = .default, retry: RetryPolicy = .default) {
        self.defaultConnections = ConnectionLimits.clamp(defaultConnections)
        self.maxSimultaneousDownloads = min(max(1, maxSimultaneousDownloads), 8)
        self.allowInsecureHTTP = allowInsecureHTTP
        self.allowsCellular = allowsCellular
        self.chunking = chunking
        self.retry = retry
    }

    public static let `default` = HttpDownloadSettings()
}
