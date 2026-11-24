import Foundation
import DownloadSupport

public enum AttentionReason: String, Codable, Sendable, Equatable {
    case accessDenied            // link expired / forbidden / not found
    case authenticationRequired  // credentials that are not stored are needed
    case fileChanged             // the server's file is no longer the one we started
    case insufficientSpace
    case rangeUnreliable         // server answers range requests inconsistently
}

/// Everything that must survive an app restart for one HTTP download.
public struct HttpDownloadRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var kind: String
    public var originalURL: URL
    public var currentURL: URL
    public var filename: String
    /// The user typed the name; a server-suggested name must not replace it.
    public var hasCustomFilename: Bool
    public var status: UnifiedStatus
    public var attention: AttentionReason?
    public var lastError: String?
    public var totalBytes: Int64?
    public var acceptsRanges: Bool?
    public var validators: Validators
    public var connectionCount: Int
    public var chunks: [ChunkState]
    public var retryCount: Int
    /// `http://` (or an insecure redirect): the UI shows "Not encrypted".
    public var isInsecure: Bool
    public var requestHeaders: [String: String]
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    /// Path of the finished file relative to the downloads directory.
    public var finalFilename: String?

    public init(id: UUID = UUID(), originalURL: URL, filename: String, connectionCount: Int,
                requestHeaders: [String: String] = [:], createdAt: Date = Date()) {
        self.id = id
        self.kind = "http"
        self.originalURL = originalURL
        self.currentURL = originalURL
        self.filename = filename
        self.hasCustomFilename = false
        self.status = .queued
        self.attention = nil
        self.lastError = nil
        self.totalBytes = nil
        self.acceptsRanges = nil
        self.validators = Validators()
        self.connectionCount = ConnectionLimits.clamp(connectionCount)
        self.chunks = []
        self.retryCount = 0
        self.isInsecure = originalURL.scheme?.lowercased() == "http"
        self.requestHeaders = requestHeaders
        self.createdAt = createdAt
        self.startedAt = nil
        self.completedAt = nil
        self.finalFilename = nil
    }

    public var urlKey: String { URLKey.key(for: originalURL) ?? originalURL.absoluteString }

    public var downloadedBytes: Int64 {
        chunks.reduce(into: Int64(0)) { sum, c in
            switch c.phase {
            case .done: sum += c.length ?? c.bytesReceived
            case .inFlight: sum += min(c.bytesReceived, c.length ?? c.bytesReceived)
            case .pending: break
            }
        }
    }

    public var fractionCompleted: Double? {
        guard let t = totalBytes, t > 0 else { return status == .completed ? 1 : nil }
        return min(1, Double(downloadedBytes) / Double(t))
    }

    public var allChunksDone: Bool { !chunks.isEmpty && chunks.allSatisfy { $0.phase == .done } }
    public var chunksDone: Int { chunks.filter { $0.phase == .done }.count }
    public var chunksInFlight: Int { chunks.filter { $0.phase == .inFlight }.count }
}

/// Normalises URLs so the same download is not queued twice.
public enum URLKey {
    public static func key(for url: URL) -> String? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        c.fragment = nil
        var out = "\(scheme)://\(host)"
        if let port = c.port, !(scheme == "http" && port == 80), !(scheme == "https" && port == 443) { out += ":\(port)" }
        let path = c.percentEncodedPath
        out += path.isEmpty ? "/" : path
        if let q = c.percentEncodedQuery, !q.isEmpty { out += "?\(q)" }
        return out
    }
}
