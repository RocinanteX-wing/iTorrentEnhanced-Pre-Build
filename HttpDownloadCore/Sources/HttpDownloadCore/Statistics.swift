import Foundation
import DownloadSupport

/// Per-download numbers for the details screen.
public struct DownloadStatistics: Sendable, Equatable {
    public var downloadedBytes: Int64
    public var totalBytes: Int64?
    public var currentSpeed: Double
    public var averageSpeed: Double
    public var eta: TimeInterval?
    public var activeConnections: Int
    public var configuredConnections: Int
    public var retryCount: Int
    public var chunksTotal: Int
    public var chunksDone: Int
    public var chunksInFlight: Int
    public var activeSeconds: TimeInterval

    public var fraction: Double? {
        guard let t = totalBytes, t > 0 else { return nil }
        return min(1, Double(downloadedBytes) / Double(t))
    }
}

public struct StatisticsTracker: Sendable, Equatable {
    private var meter = SpeedMeter()
    public init() {}

    public mutating func update(downloadedBytes: Int64, at time: TimeInterval) { meter.record(totalBytes: downloadedBytes, at: time) }
    public mutating func pause() { meter.pause() }
    public mutating func resume(at time: TimeInterval, downloadedBytes: Int64) { meter.resume(at: time, totalBytes: downloadedBytes) }

    public func snapshot(for record: HttpDownloadRecord, activeConnections: Int, now: TimeInterval) -> DownloadStatistics {
        let downloaded = record.downloadedBytes
        let remaining = record.totalBytes.map { max(0, $0 - downloaded) }
        return DownloadStatistics(
            downloadedBytes: downloaded,
            totalBytes: record.totalBytes,
            currentSpeed: meter.currentSpeed(at: now),
            averageSpeed: meter.averageSpeed,
            eta: remaining.flatMap { meter.eta(remainingBytes: $0, at: now) },
            activeConnections: activeConnections,
            configuredConnections: record.connectionCount,
            retryCount: record.retryCount,
            chunksTotal: record.chunks.count,
            chunksDone: record.chunksDone,
            chunksInFlight: record.chunksInFlight,
            activeSeconds: meter.activeTime
        )
    }
}

/// Thread-safe registry of trackers, one per download.
public final class DownloadStatisticsManager: @unchecked Sendable {
    private var trackers: [UUID: StatisticsTracker] = [:]
    private let lock = NSLock()
    public init() {}

    public func update(id: UUID, downloadedBytes: Int64, at time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        trackers[id, default: StatisticsTracker()].update(downloadedBytes: downloadedBytes, at: time)
    }
    public func pause(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        trackers[id, default: StatisticsTracker()].pause()
    }
    public func resume(id: UUID, at time: TimeInterval, downloadedBytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        trackers[id, default: StatisticsTracker()].resume(at: time, downloadedBytes: downloadedBytes)
    }
    public func snapshot(for record: HttpDownloadRecord, activeConnections: Int, now: TimeInterval) -> DownloadStatistics {
        lock.lock(); defer { lock.unlock() }
        return (trackers[record.id] ?? StatisticsTracker()).snapshot(for: record, activeConnections: activeConnections, now: now)
    }
    public func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        trackers[id] = nil
    }
}
