import XCTest
@testable import DownloadSupport

final class UnifiedStatusTests: XCTestCase {
    func testClassification() {
        XCTAssertTrue(UnifiedStatus.downloading.isActive)
        XCTAssertTrue(UnifiedStatus.assembling.isActive)
        XCTAssertFalse(UnifiedStatus.paused.isActive)
        XCTAssertTrue(UnifiedStatus.completed.isTerminal)
        XCTAssertTrue(UnifiedStatus.failed.isTerminal)
        XCTAssertFalse(UnifiedStatus.needsAttention.isTerminal)
        XCTAssertTrue(UnifiedStatus.needsAttention.isResumable)
        XCTAssertFalse(UnifiedStatus.completed.isResumable)
    }
    func testCodableRoundTrip() throws {
        for s in UnifiedStatus.allCases {
            let data = try JSONEncoder().encode([s])
            XCTAssertEqual(try JSONDecoder().decode([UnifiedStatus].self, from: data), [s])
        }
    }
}

final class RetryPolicyTests: XCTestCase {
    func testBackoffDoublesAndCaps() {
        let p = RetryPolicy(maxRetries: 5, baseDelay: 1, maxDelay: 10, jitterFraction: 0)
        XCTAssertEqual(p.delay(afterFailures: 1), 1)
        XCTAssertEqual(p.delay(afterFailures: 2), 2)
        XCTAssertEqual(p.delay(afterFailures: 3), 4)
        XCTAssertEqual(p.delay(afterFailures: 4), 8)
        XCTAssertEqual(p.delay(afterFailures: 5), 10)   // capped
        XCTAssertEqual(p.delay(afterFailures: 50), 10)  // no overflow
    }
    func testJitterBounds() {
        let p = RetryPolicy(maxRetries: 3, baseDelay: 4, maxDelay: 100, jitterFraction: 0.25)
        XCTAssertEqual(p.delay(afterFailures: 1, randomUnit: 0), 3, accuracy: 1e-9)
        XCTAssertEqual(p.delay(afterFailures: 1, randomUnit: 0.5), 4, accuracy: 1e-9)
        XCTAssertEqual(p.delay(afterFailures: 1, randomUnit: 1), 5, accuracy: 1e-9)
    }
    func testShouldRetryBudget() {
        let p = RetryPolicy(maxRetries: 2)
        XCTAssertFalse(p.shouldRetry(afterFailures: 0))
        XCTAssertTrue(p.shouldRetry(afterFailures: 1))
        XCTAssertTrue(p.shouldRetry(afterFailures: 2))
        XCTAssertFalse(p.shouldRetry(afterFailures: 3))
    }
    func testSanitisedInit() {
        let p = RetryPolicy(maxRetries: -3, baseDelay: -1, maxDelay: -5, jitterFraction: 9)
        XCTAssertEqual(p.maxRetries, 0)
        XCTAssertEqual(p.baseDelay, 0)
        XCTAssertEqual(p.jitterFraction, 1)
    }
}

final class SpeedMeterTests: XCTestCase {
    func testCurrentAndAverageSpeed() {
        var m = SpeedMeter(windowSeconds: 5)
        m.record(totalBytes: 0, at: 0)
        m.record(totalBytes: 1000, at: 1)
        m.record(totalBytes: 2000, at: 2)
        XCTAssertEqual(m.currentSpeed(at: 2), 1000, accuracy: 1e-6)
        XCTAssertEqual(m.averageSpeed, 1000, accuracy: 1e-6)
    }
    func testWindowForgetsOldSamples() {
        var m = SpeedMeter(windowSeconds: 2)
        m.record(totalBytes: 0, at: 0)
        m.record(totalBytes: 10_000, at: 1)        // fast burst
        m.record(totalBytes: 10_100, at: 10)       // very slow afterwards
        m.record(totalBytes: 10_200, at: 11)
        XCTAssertEqual(m.currentSpeed(at: 11), 100, accuracy: 1e-6)
        XCTAssertGreaterThan(m.averageSpeed, m.currentSpeed(at: 11))
    }
    func testStalledReportsZero() {
        var m = SpeedMeter(windowSeconds: 3)
        m.record(totalBytes: 0, at: 0)
        m.record(totalBytes: 3000, at: 1)
        XCTAssertEqual(m.currentSpeed(at: 100), 0)
    }
    func testSparseUpdatesLongerThanTheWindowStillGiveASpeed() {
        var m = SpeedMeter(windowSeconds: 5)
        m.record(totalBytes: 0, at: 0)
        m.record(totalBytes: 6000, at: 6)                  // one update every 6 s, window is 5 s
        XCTAssertEqual(m.currentSpeed(at: 6), 1000, accuracy: 1e-6)
        m.record(totalBytes: 9000, at: 12)
        XCTAssertEqual(m.currentSpeed(at: 12), 500, accuracy: 1e-6)
        XCTAssertEqual(m.currentSpeed(at: 40), 0)          // but a real stall still reads 0
    }
    func testPauseExcludedFromAverage() {
        var m = SpeedMeter(windowSeconds: 5)
        m.record(totalBytes: 0, at: 0)
        m.record(totalBytes: 1000, at: 1)
        m.pause()
        m.resume(at: 1001, totalBytes: 1000)        // 1000 s pause
        m.record(totalBytes: 2000, at: 1002)
        XCTAssertEqual(m.activeTime, 2, accuracy: 1e-6)
        XCTAssertEqual(m.averageSpeed, 1000, accuracy: 1e-6)
    }
    func testEta() {
        var m = SpeedMeter(windowSeconds: 5)
        m.record(totalBytes: 0, at: 0)
        m.record(totalBytes: 500, at: 1)
        XCTAssertEqual(m.eta(remainingBytes: 1000, at: 1)!, 2, accuracy: 1e-6)
        XCTAssertEqual(m.eta(remainingBytes: 0, at: 1), 0)
        XCTAssertNil(SpeedMeter().eta(remainingBytes: 10, at: 0))
        XCTAssertNil(m.eta(remainingBytes: -1, at: 1))
    }
}

final class URLRedactionTests: XCTestCase {
    func testStripsCredentialsQueryAndFragment() {
        let u = URL(string: "https://user:pa55@example.com:8443/files/a.zip?token=SECRET&x=1#frag")!
        let r = URLRedaction.redacted(u)
        XCTAssertEqual(r, "https://example.com:8443/files/a.zip?…")
        XCTAssertFalse(r.contains("SECRET"))
        XCTAssertFalse(r.contains("pa55"))
    }
    func testNoQueryNoMarker() {
        XCTAssertEqual(URLRedaction.redacted(URL(string: "http://example.com/a/b.bin")!), "http://example.com/a/b.bin")
    }
    func testMasksOpaquePathSegments() {
        let token = String(repeating: "aB3dE6", count: 8)   // 48 chars
        let u = URL(string: "https://cdn.example.com/dl/\(token)/file.mp4")!
        let r = URLRedaction.redacted(u)
        XCTAssertFalse(r.contains(token))
        XCTAssertTrue(r.hasSuffix("/file.mp4"))
    }
    func testHeaderRedaction() {
        let h = ["Authorization": "Bearer abc", "cookie": "s=1", "Accept": "*/*", "X-Api-Key": "k"]
        let r = URLRedaction.redactedHeaders(h)
        XCTAssertEqual(r["Authorization"], "<redacted>")
        XCTAssertEqual(r["cookie"], "<redacted>")
        XCTAssertEqual(r["X-Api-Key"], "<redacted>")
        XCTAssertEqual(r["Accept"], "*/*")
        XCTAssertEqual(URLRedaction.strippingSensitiveHeaders(h), ["Accept": "*/*"])
    }
    func testRedactingURLsInsideMessages() {
        let msg = "The request to https://host.example/path/x.bin?sig=ABCDEF failed (-1009) while fetching http://other.example/y"
        let out = URLRedaction.redactingURLs(in: msg)
        XCTAssertFalse(out.contains("ABCDEF"))
        XCTAssertTrue(out.contains("https://host.example/path/x.bin?…"))
        XCTAssertTrue(out.contains("http://other.example/y"))
        XCTAssertTrue(out.contains("failed (-1009)"))
    }
}

final class AtomicFileStoreTests: XCTestCase {
    struct Doc: Codable, Equatable { var name: String; var n: Int; var when: Date }
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("afs-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testMissingFileLoadsNil() throws {
        XCTAssertNil(try AtomicFileStore<Doc>(fileURL: dir.appendingPathComponent("a.json")).load())
    }
    func testRoundTripCreatesDirectories() throws {
        let store = AtomicFileStore<[Doc]>(fileURL: dir.appendingPathComponent("deep/er/a.json"))
        let docs = [Doc(name: "x", n: 1, when: Date(timeIntervalSince1970: 1_700_000_000))]
        try store.save(docs)
        XCTAssertEqual(try store.load(), docs)
    }
    func testBackupUsedWhenPrimaryCorrupt() throws {
        let url = dir.appendingPathComponent("a.json")
        let store = AtomicFileStore<[Int]>(fileURL: url)
        try store.save([1])
        try store.save([1, 2])                       // primary = [1,2], backup = [1]
        try Data("{ not json".utf8).write(to: url)   // corrupt the primary
        XCTAssertEqual(try store.load(), [1])
    }
    func testCorruptWithoutBackupThrows() throws {
        let url = dir.appendingPathComponent("a.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: url)
        XCTAssertThrowsError(try AtomicFileStore<[Int]>(fileURL: url).load()) { e in
            guard case AtomicFileStoreError.corrupt = e else { return XCTFail("wrong error \(e)") }
        }
    }
    func testNewerSchemaIsRejectedNotMisread() throws {
        let url = dir.appendingPathComponent("a.json")
        try AtomicFileStore<[Int]>(fileURL: url, schemaVersion: 3).save([9])
        XCTAssertThrowsError(try AtomicFileStore<[Int]>(fileURL: url, schemaVersion: 2).load()) { e in
            XCTAssertEqual(e as? AtomicFileStoreError, .unsupportedVersion(found: 3, supported: 2))
        }
    }
    func testRemove() throws {
        let store = AtomicFileStore<[Int]>(fileURL: dir.appendingPathComponent("a.json"))
        try store.save([1]); try store.save([2])
        try store.remove()
        XCTAssertNil(try store.load())
    }
}

final class DiskSpaceGuardTests: XCTestCase {
    struct Fixed: FreeSpaceProviding { var bytes: Int64; func availableBytes(at url: URL) throws -> Int64 { bytes } }

    func testEnoughSpacePasses() throws {
        let g = DiskSpaceGuard(provider: Fixed(bytes: 1_000_000), minimumHeadroom: 1000, headroomFraction: 0)
        XCTAssertNoThrow(try g.ensure(requiredBytes: 998_000, at: URL(fileURLWithPath: "/x")))
    }
    func testInsufficientSpaceThrowsWithNumbers() {
        let g = DiskSpaceGuard(provider: Fixed(bytes: 1_000_000), minimumHeadroom: 1000, headroomFraction: 0)
        XCTAssertThrowsError(try g.ensure(requiredBytes: 999_500, at: URL(fileURLWithPath: "/x"))) { e in
            XCTAssertEqual(e as? DiskSpaceError, .insufficient(required: 1_000_500, available: 1_000_000))
        }
    }
    func testFractionalHeadroomDominatesForLargeFiles() {
        let g = DiskSpaceGuard(provider: Fixed(bytes: 0), minimumHeadroom: 10, headroomFraction: 0.1)
        XCTAssertEqual(g.requiredWithHeadroom(1000), 1100)
    }
    func testSystemProviderReportsPositiveForExistingAndMissingPaths() throws {
        let p = SystemFreeSpaceProvider()
        XCTAssertGreaterThan(try p.availableBytes(at: FileManager.default.temporaryDirectory), 0)
        XCTAssertGreaterThan(try p.availableBytes(at: FileManager.default.temporaryDirectory.appendingPathComponent("no/such/dir")), 0)
    }
}
