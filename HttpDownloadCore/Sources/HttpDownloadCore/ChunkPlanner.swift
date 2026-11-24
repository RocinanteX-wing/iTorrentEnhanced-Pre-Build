import Foundation

public enum ChunkPhase: String, Codable, Sendable { case pending, inFlight, done }

/// One byte range of the file. `end` is inclusive; `end < start` means "until the stream ends" (unknown size).
public struct ChunkState: Codable, Sendable, Equatable, Identifiable {
    public var index: Int
    public var start: Int64
    public var end: Int64
    public var phase: ChunkPhase
    public var attempts: Int
    public var bytesReceived: Int64

    public init(index: Int, start: Int64, end: Int64, phase: ChunkPhase = .pending, attempts: Int = 0, bytesReceived: Int64 = 0) {
        self.index = index; self.start = start; self.end = end
        self.phase = phase; self.attempts = attempts; self.bytesReceived = bytesReceived
    }

    public var id: Int { index }
    public var isOpenEnded: Bool { end < start }
    public var length: Int64? { end >= start ? end - start + 1 : nil }
    public var range: ClosedRange<Int64>? { end >= start ? start...end : nil }
}

public enum ChunkPlanner {
    /// Splits a file into contiguous chunks (decision D5: small chunks, not one big segment per connection).
    /// - Unknown size, or no range support: one open-ended / whole-file chunk, no parallelism.
    /// - Otherwise: chunks of about `preferredChunkSize`, shrunk so every connection gets at least
    ///   `chunksPerConnection` chunks, clamped to `minChunkSize ... maxChunkSize`, and never more than `maxChunks`.
    public static func plan(totalBytes: Int64?, acceptsRanges: Bool, connections: Int,
                            config: ChunkingConfig = .default) -> [ChunkState] {
        guard let total = totalBytes, total >= 0 else {
            return [ChunkState(index: 0, start: 0, end: -1)]
        }
        if total == 0 { return [] }
        let conns = Int64(ConnectionLimits.clamp(connections))
        guard acceptsRanges, total >= config.minSizeForChunking else {
            return [ChunkState(index: 0, start: 0, end: total - 1)]
        }

        var size = config.preferredChunkSize
        let wanted = conns * Int64(config.chunksPerConnection)
        size = min(size, (total + wanted - 1) / wanted)
        size = min(max(size, config.minChunkSize), config.maxChunkSize)
        if (total + size - 1) / size > Int64(config.maxChunks) {
            size = (total + Int64(config.maxChunks) - 1) / Int64(config.maxChunks)
        }

        var chunks: [ChunkState] = []
        var start: Int64 = 0
        var index = 0
        while start < total {
            let end = min(start + size - 1, total - 1)
            chunks.append(ChunkState(index: index, start: start, end: end))
            start = end + 1
            index += 1
        }
        return chunks
    }
}
