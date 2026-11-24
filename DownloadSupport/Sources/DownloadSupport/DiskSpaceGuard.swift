import Foundation

public protocol FreeSpaceProviding: Sendable {
    func availableBytes(at url: URL) throws -> Int64
}

/// Reports free space of the volume that holds `url` (or its nearest existing ancestor).
public struct SystemFreeSpaceProvider: FreeSpaceProviding {
    public init() {}

    public func availableBytes(at url: URL) throws -> Int64 {
        let fm = FileManager.default
        var probe = url
        while !fm.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        #if canImport(Darwin)
        if let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        #endif
        let attrs = try fm.attributesOfFileSystem(forPath: probe.path)
        if let free = attrs[.systemFreeSize] as? NSNumber { return free.int64Value }
        throw CocoaError(.fileReadUnknown)
    }
}

public enum DiskSpaceError: Error, Equatable {
    case insufficient(required: Int64, available: Int64)
}

public struct DiskSpaceGuard: Sendable {
    public let provider: FreeSpaceProviding
    /// Always keep at least this much free on top of the requirement.
    public let minimumHeadroom: Int64
    /// Additional headroom as a fraction of the requirement.
    public let headroomFraction: Double

    public init(provider: FreeSpaceProviding = SystemFreeSpaceProvider(),
                minimumHeadroom: Int64 = 50 * 1024 * 1024,
                headroomFraction: Double = 0.02) {
        self.provider = provider
        self.minimumHeadroom = max(0, minimumHeadroom)
        self.headroomFraction = max(0, headroomFraction)
    }

    public func requiredWithHeadroom(_ requiredBytes: Int64) -> Int64 {
        let extra = max(minimumHeadroom, Int64(Double(max(0, requiredBytes)) * headroomFraction))
        return max(0, requiredBytes) + extra
    }

    /// Throws `DiskSpaceError.insufficient` when the volume cannot hold `requiredBytes` plus headroom.
    public func ensure(requiredBytes: Int64, at url: URL) throws {
        let needed = requiredWithHeadroom(requiredBytes)
        let available = try provider.availableBytes(at: url)
        if available < needed {
            throw DiskSpaceError.insufficient(required: needed, available: available)
        }
    }
}
