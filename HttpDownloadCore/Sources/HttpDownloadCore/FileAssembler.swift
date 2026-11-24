import Foundation

public struct AssemblyPart: Sendable, Equatable {
    public var url: URL
    public var expectedLength: Int64?
    public init(url: URL, expectedLength: Int64?) { self.url = url; self.expectedLength = expectedLength }
}

public enum AssemblyError: Error, Equatable {
    case partMissing(index: Int)
    case partSizeMismatch(index: Int, expected: Int64, actual: Int64)
    case totalMismatch(expected: Int64, actual: Int64)
    case io(String)
    /// Part files were already deleted when the failure happened: the download must restart.
    case failedAfterConsuming(String)
}

public enum PartPolicy: Sendable {
    /// Needs room for parts + final file, but a failure leaves the parts intact.
    case keepUntilFinished
    /// Deletes each part once copied, so peak usage is about one file; a failure forces a restart.
    case consumeAsWritten
}

/// Joins downloaded chunks into the final file safely:
/// 1. every part is checked first (nothing is written if any part is missing or the wrong size),
/// 2. the data goes to a temporary file on the same volume,
/// 3. the finished file is moved into place atomically under a unique name.
/// A partial file therefore never appears in the downloads folder.
public struct FileAssembler {
    private let fileManager: FileManager
    private let bufferSize: Int

    public init(fileManager: FileManager = .default, bufferSize: Int = 1 << 20) {
        self.fileManager = fileManager
        self.bufferSize = max(4096, bufferSize)
    }

    @discardableResult
    public func assemble(parts: [AssemblyPart], expectedTotal: Int64?, finalDirectory: URL, desiredFilename: String,
                         workDirectory: URL, policy: PartPolicy = .keepUntilFinished,
                         progress: ((Int64) -> Void)? = nil) throws -> URL {
        // 1. verify before touching anything
        var actualTotal: Int64 = 0
        for (i, part) in parts.enumerated() {
            guard let attrs = try? fileManager.attributesOfItem(atPath: part.url.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { throw AssemblyError.partMissing(index: i) }
            if let expected = part.expectedLength, expected != size {
                throw AssemblyError.partSizeMismatch(index: i, expected: expected, actual: size)
            }
            actualTotal += size
        }
        if let expected = expectedTotal, expected != actualTotal {
            throw AssemblyError.totalMismatch(expected: expected, actual: actualTotal)
        }

        // 2. stream into a temporary file
        do { try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true) }
        catch { throw AssemblyError.io("cannot create work directory: \(error.localizedDescription)") }
        let temp = workDirectory.appendingPathComponent("\(UUID().uuidString).assembling")
        guard fileManager.createFile(atPath: temp.path, contents: nil) else { throw AssemblyError.io("cannot create temporary file") }

        var consumedAny = false
        func fail(_ message: String) -> AssemblyError {
            try? fileManager.removeItem(at: temp)
            return consumedAny ? .failedAfterConsuming(message) : .io(message)
        }

        do {
            let out = try FileHandle(forWritingTo: temp)
            defer { try? out.close() }
            var written: Int64 = 0
            for part in parts {
                let input = try FileHandle(forReadingFrom: part.url)
                defer { try? input.close() }
                while true {
                    guard let data = try input.read(upToCount: bufferSize), !data.isEmpty else { break }
                    try out.write(contentsOf: data)
                    written += Int64(data.count)
                    progress?(written)
                }
                if policy == .consumeAsWritten {
                    try fileManager.removeItem(at: part.url)
                    consumedAny = true
                }
            }
            try out.synchronize()
            let size = (try fileManager.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.int64Value ?? -1
            if size != actualTotal { throw AssemblyError.totalMismatch(expected: actualTotal, actual: size) }
        } catch let e as AssemblyError {
            throw (consumedAny ? AssemblyError.failedAfterConsuming(String(describing: e)) : e).cleaning(temp, fileManager)
        } catch {
            throw fail(error.localizedDescription)
        }

        // 3. move into place atomically under a unique name
        let name = FilenameSanitizer.sanitize(desiredFilename)
        do {
            try fileManager.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
            var lastError: Error?
            for _ in 0..<5 {
                let unique = UniqueFilename.resolve(name) { fileManager.fileExists(atPath: finalDirectory.appendingPathComponent($0).path) }
                let destination = finalDirectory.appendingPathComponent(unique)
                do {
                    try fileManager.moveItem(at: temp, to: destination)
                    if policy == .keepUntilFinished { for p in parts { try? fileManager.removeItem(at: p.url) } }
                    return destination
                } catch { lastError = error }
            }
            throw lastError ?? CocoaError(.fileWriteUnknown)
        } catch {
            throw fail("cannot move the finished file into place: \(error.localizedDescription)")
        }
    }
}

private extension AssemblyError {
    func cleaning(_ temp: URL, _ fm: FileManager) -> AssemblyError {
        try? fm.removeItem(at: temp)
        return self
    }
}
