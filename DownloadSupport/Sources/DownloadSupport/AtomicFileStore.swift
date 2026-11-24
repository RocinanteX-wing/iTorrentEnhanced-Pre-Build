import Foundation

public struct VersionedEnvelope<Payload: Codable>: Codable {
    public var schemaVersion: Int
    public var payload: Payload
}

public enum AtomicFileStoreError: Error, Equatable {
    case corrupt(String)
    case unsupportedVersion(found: Int, supported: Int)
}

/// A versioned JSON file that is replaced atomically. The previous good copy is kept as `<name>.bak`
/// and used if the primary file is unreadable.
public struct AtomicFileStore<Payload: Codable> {
    public let fileURL: URL
    public let schemaVersion: Int
    private let fileManager: FileManager

    public init(fileURL: URL, schemaVersion: Int = 1, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.schemaVersion = schemaVersion
        self.fileManager = fileManager
    }

    private var backupURL: URL { fileURL.appendingPathExtension("bak") }

    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Returns nil when no file has ever been saved.
    public func load() throws -> Payload? {
        let primaryExists = fileManager.fileExists(atPath: fileURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)
        if !primaryExists && !backupExists { return nil }

        var firstError: Error?
        for url in [fileURL, backupURL] where fileManager.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let envelope = try makeDecoder().decode(VersionedEnvelope<Payload>.self, from: data)
                if envelope.schemaVersion > schemaVersion {
                    throw AtomicFileStoreError.unsupportedVersion(found: envelope.schemaVersion, supported: schemaVersion)
                }
                return envelope.payload
            } catch let e as AtomicFileStoreError {
                throw e
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        let detail = firstError.map { String(describing: $0) } ?? "unreadable"
        throw AtomicFileStoreError.corrupt(detail)
    }

    public func save(_ payload: Payload) throws {
        let data = try makeEncoder().encode(VersionedEnvelope(schemaVersion: schemaVersion, payload: payload))
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.copyItem(at: fileURL, to: backupURL)
        }
        try data.write(to: fileURL, options: [.atomic])
    }

    public func remove() throws {
        for url in [fileURL, backupURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
