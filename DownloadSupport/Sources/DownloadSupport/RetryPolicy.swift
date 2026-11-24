import Foundation

/// Exponential back-off with optional jitter. Pure and deterministic when `randomUnit` is supplied.
public struct RetryPolicy: Codable, Sendable, Equatable {
    /// Retries allowed after the first failure (5 means up to 6 attempts in total).
    public var maxRetries: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    /// 0 ... 1. A value of 0.25 spreads each delay by +/-25 %.
    public var jitterFraction: Double

    public init(maxRetries: Int = 5, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 60, jitterFraction: Double = 0.25) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(self.baseDelay, maxDelay)
        self.jitterFraction = min(max(0, jitterFraction), 1)
    }

    public static let `default` = RetryPolicy()

    /// `failures` counts failed attempts so far (1 after the first failure).
    public func shouldRetry(afterFailures failures: Int) -> Bool {
        failures >= 1 && failures <= maxRetries
    }

    /// Delay before the next attempt. `randomUnit` in 0 ... 1 (0.5 = no jitter).
    public func delay(afterFailures failures: Int, randomUnit: Double = 0.5) -> TimeInterval {
        guard failures >= 1 else { return 0 }
        let exponent = min(failures - 1, 30)
        let raw = min(baseDelay * pow(2, Double(exponent)), maxDelay)
        let unit = min(max(0, randomUnit), 1)
        let factor = 1 + jitterFraction * (2 * unit - 1)
        return max(0, raw * factor)
    }
}
