import Foundation
import DownloadSupport

/// Owns the on-disk layout of the HTTP engine:
/// `<root>/downloads.json`        the queue (versioned, atomic, with a backup copy)
/// `<root>/Parts/<id>/chunk-N.part` downloaded chunks, kept apart from finished files.
public final class DownloadPersistenceManager: @unchecked Sendable {
    public static let schemaVersion = 1

    public let rootDirectory: URL
    private let store: AtomicFileStore<[HttpDownloadRecord]>
    private let fileManager: FileManager

    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.store = AtomicFileStore(fileURL: rootDirectory.appendingPathComponent("downloads.json"),
                                     schemaVersion: DownloadPersistenceManager.schemaVersion, fileManager: fileManager)
    }

    public var partsRoot: URL { rootDirectory.appendingPathComponent("Parts", isDirectory: true) }

    public func partsDirectory(for id: UUID) -> URL {
        partsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func partURL(for id: UUID, chunk index: Int) -> URL {
        partsDirectory(for: id).appendingPathComponent(String(format: "chunk-%06d.part", index))
    }

    public func partLength(for id: UUID, chunk index: Int) -> Int64? {
        let path = partURL(for: id, chunk: index).path
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    public func load() throws -> [HttpDownloadRecord] { try store.load() ?? [] }

    /// Credentials-bearing headers (Authorization, Cookie...) are never written to disk.
    public func save(_ records: [HttpDownloadRecord]) throws {
        let safe = records.map { r -> HttpDownloadRecord in
            var copy = r
            copy.requestHeaders = URLRedaction.strippingSensitiveHeaders(r.requestHeaders)
            return copy
        }
        try store.save(safe)
    }

    /// Deletes chunk folders that belong to no known download (e.g. after a crash while removing one).
    public func removeOrphanedParts(keeping ids: Set<UUID>) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: partsRoot.path) else { return }
        for name in names where UUID(uuidString: name).map({ !ids.contains($0) }) ?? true {
            try? fileManager.removeItem(at: partsRoot.appendingPathComponent(name))
        }
    }

    public func removeParts(for id: UUID) {
        try? fileManager.removeItem(at: partsDirectory(for: id))
    }
}
