import Foundation

/// Tracks transfer speed from cumulative byte counts. Time is passed in, so it is trivially testable.
/// - `currentSpeed`: bytes/s over a short sliding window.
/// - `averageSpeed`: bytes/s over *active* time only (paused time is not counted).
public struct SpeedMeter: Sendable, Equatable {
    private struct Sample: Sendable, Equatable { var time: TimeInterval; var bytes: Int64 }

    public let windowSeconds: TimeInterval
    private var samples: [Sample] = []
    private var startBytes: Int64 = 0
    private var lastTime: TimeInterval?
    private var lastBytes: Int64 = 0
    private var activeSeconds: TimeInterval = 0
    private var paused = false
    private var started = false

    public init(windowSeconds: TimeInterval = 5) {
        self.windowSeconds = max(0.1, windowSeconds)
    }

    /// Record the cumulative number of bytes received at `time` (seconds, any monotonic origin).
    public mutating func record(totalBytes: Int64, at time: TimeInterval) {
        if !started {
            started = true
            startBytes = totalBytes
        } else if let last = lastTime, !paused {
            activeSeconds += max(0, time - last)
        }
        lastTime = time
        lastBytes = totalBytes
        samples.append(Sample(time: time, bytes: totalBytes))
        // Drop samples older than the window, but keep the newest one before it: with sparse updates
        // (fewer than two samples inside the window) it serves as the baseline for the speed.
        let cutoff = time - windowSeconds
        if let firstKept = samples.firstIndex(where: { $0.time >= cutoff }), firstKept > 1 {
            samples.removeFirst(firstKept - 1)
        }
    }

    public mutating func pause() { paused = true }

    /// Resume after a pause; the gap does not count towards the average.
    public mutating func resume(at time: TimeInterval, totalBytes: Int64) {
        paused = false
        samples.removeAll(keepingCapacity: true)
        lastTime = time
        lastBytes = totalBytes
        samples.append(Sample(time: time, bytes: totalBytes))
        if !started { started = true; startBytes = totalBytes }
    }

    public mutating func reset() { self = SpeedMeter(windowSeconds: windowSeconds) }

    public func currentSpeed(at now: TimeInterval) -> Double {
        let cutoff = now - windowSeconds
        let inWindow = samples.filter { $0.time >= cutoff && $0.time <= now }
        let first: Sample
        let last: Sample
        if inWindow.count >= 2 {
            first = inWindow[0]; last = inWindow[inWindow.count - 1]
        } else if inWindow.count == 1, let older = samples.last(where: { $0.time < cutoff }) {
            first = older; last = inWindow[0]            // sparse updates: use the sample just before the window
        } else {
            return 0                                      // nothing recent: stalled
        }
        let dt = last.time - first.time
        guard dt > 0 else { return 0 }
        return Double(max(0, last.bytes - first.bytes)) / dt
    }

    public var averageSpeed: Double {
        guard started, activeSeconds > 0 else { return 0 }
        return Double(max(0, lastBytes - startBytes)) / activeSeconds
    }

    public var activeTime: TimeInterval { activeSeconds }

    /// Estimated seconds remaining, using the current speed and falling back to the average.
    public func eta(remainingBytes: Int64, at now: TimeInterval) -> TimeInterval? {
        guard remainingBytes >= 0 else { return nil }
        if remainingBytes == 0 { return 0 }
        let speed = currentSpeed(at: now)
        let effective = speed > 0 ? speed : averageSpeed
        guard effective > 0 else { return nil }
        return Double(remainingBytes) / effective
    }
}
