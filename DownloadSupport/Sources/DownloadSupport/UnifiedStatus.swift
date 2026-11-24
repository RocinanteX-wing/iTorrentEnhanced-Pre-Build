import Foundation

/// Status vocabulary shared by every download engine (HTTP now, HLS later).
/// Engines may map their richer internal states onto this for the unified list.
public enum UnifiedStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case probing
    case downloading
    case paused
    case retrying
    case assembling
    case completed
    case failed
    case needsAttention

    /// The engine is currently doing work for this item.
    public var isActive: Bool {
        switch self {
        case .probing, .downloading, .retrying, .assembling: return true
        default: return false
        }
    }

    /// No further transitions happen without a user action.
    public var isTerminal: Bool { self == .completed || self == .failed }

    /// The user may press "resume / retry".
    public var isResumable: Bool {
        switch self {
        case .paused, .failed, .needsAttention: return true
        default: return false
        }
    }
}
