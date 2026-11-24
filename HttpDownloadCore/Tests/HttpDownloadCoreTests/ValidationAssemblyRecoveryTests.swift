import XCTest
import DownloadSupport
@testable import HttpDownloadCore

final class RangeValidationTests: XCTestCase {
    let v = Validators(etag: "\"v1\"", lastModified: "Mon, 01 Jan 2024 00:00:00 GMT")
    func exp(_ lo: Int64 = 100, _ hi: Int64 = 199, total: Int64? = 1000) -> RangeExpectation { RangeExpectation(range: lo...hi, knownTotal: total, validators: v) }
    func r(_ code: Int, _ h: [String: String] = [:]) -> HTTPResponseInfo { HTTPResponseInfo(statusCode: code, headers: h) }

    func testAcceptedExactRange() {
        XCTAssertEqual(RangeResponseValidator.verdict(for: r(206, ["Content-Range": "bytes 100-199/1000", "Content-Length": "100", "ETag": "\"v1\""]), expecting: exp()), .accepted)
    }
    func testAcceptedWhenServerSendsNoValidatorsAndStarTotal() {
        XCTAssertEqual(RangeResponseValidator.verdict(for: r(206, ["Content-Range": "bytes 100-199/*"]), expecting: exp()), .accepted)
    }
    func testMissingAndMalformedContentRange() {
        XCTAssertEqual(RangeResponseValidator.verdict(for: r(206), expecting: exp()), .rangeMismatch("missing Content-Range"))
        XCTAssertEqual(RangeResponseValidator.verdict(for: r(206, ["Content-Range": "garbage"]), expecting: exp()), .rangeMismatch("invalid Content-Range"))
        XCTAssertEqual(RangeResponseValidator.verdict(for: r(206, ["Content-Range": "bytes */1000"]), expecting: exp()), .rangeMismatch("invalid Content-Range"))
    }
    func testWrongRangeIsRejectedNeverAssembled() {
        for header in ["bytes 0-99/1000", "bytes 100-150/1000", "bytes 101-199/1000", "bytes 100-250/1000"] {
            guard case .rangeMismatch = RangeResponseValidator.verdict(for: r(206, ["Content-Range": header]), expecting: exp()) else { return XCTFail(header) }
        }
    }
    func testDifferentTotalMeansFileChanged() {
        XCTAssertEqual(RangeResponseValidator.verdict(for: r(206, ["Content-Range": "bytes 100-199/2000"]), expecting: exp()), .fileChanged)
    }
    func testChangedEtagOn206MeansFileChanged() {
        XCTAssertEqual(RangeResponseValidator.verdict(for: r(206, ["Content-Range": "bytes 100-199/1000", "ETag": "\"v2\""]), expecting: exp()), .fileChanged)
    }
    func testContentLengthMustMatchRange() {
        guard case .rangeMismatch = RangeResponseValidator.verdict(for: r(206, ["Content-Range": "bytes 100-199/1000", "Content-Length": "99"]), expecting: exp()) else { return XCTFail() }
    }
    func testContentCodedRangeResponseIsRejected() {
        guard case .rangeMismatch = RangeResponseValidator.verdict(for: r(206, ["Content-Range": "bytes 100-199/1000", "Content-Encoding": "gzip"]), expecting: exp()) else { return XCTFail() }
    }
    func test200IsRangeIgnoredOrFileChanged() {
        XCTAssertEqual(RangeResponseValidator.verdict(for: r(200, ["ETag": "\"v1\""]), expecting: exp()), .rangeIgnored)
        XCTAssertEqual(RangeResponseValidator.verdict(for: r(200), expecting: exp()), .rangeIgnored)
        XCTAssertEqual(RangeResponseValidator.verdict(for: r(200, ["ETag": "\"v9\""]), expecting: exp()), .fileChanged)
    }
    func testStatusClasses() {
        XCTAssertEqual(RangeResponseValidator.verdict(for: r(416), expecting: exp()), .unsatisfiable)
        for c in [401, 403, 404, 410] { XCTAssertEqual(RangeResponseValidator.verdict(for: r(c), expecting: exp()), .accessDenied(c)) }
        for c in [408, 425, 429, 500, 502, 503, 504] { XCTAssertEqual(RangeResponseValidator.verdict(for: r(c), expecting: exp()), .retryable(c)) }
        for c in [301, 302, 400, 405] { XCTAssertEqual(RangeResponseValidator.verdict(for: r(c), expecting: exp()), .failed(c)) }
    }
    func testFullResponse() {
        XCTAssertEqual(RangeResponseValidator.verdictForFullResponse(r(200, ["Content-Length": "1000"]), expectedTotal: 1000, validators: v), .accepted)
        XCTAssertEqual(RangeResponseValidator.verdictForFullResponse(r(200, ["Content-Length": "999"]), expectedTotal: 1000, validators: v), .fileChanged)
        XCTAssertEqual(RangeResponseValidator.verdictForFullResponse(r(200, ["ETag": "\"other\""]), expectedTotal: nil, validators: v), .fileChanged)
        XCTAssertEqual(RangeResponseValidator.verdictForFullResponse(r(200, ["Content-Length": "5", "Content-Encoding": "gzip"]), expectedTotal: 1000, validators: Validators()), .accepted)
        guard case .rangeMismatch = RangeResponseValidator.verdictForFullResponse(r(206), expectedTotal: nil, validators: v) else { return XCTFail() }
        XCTAssertEqual(RangeResponseValidator.verdictForFullResponse(r(403), expectedTotal: nil, validators: v), .accessDenied(403))
    }
}

final class ModelTests: XCTestCase {
    let url = URL(string: "https://example.com/f.bin")!

    func testInitClampsConnectionsAndFlagsInsecure() {
        XCTAssertEqual(HttpDownloadRecord(originalURL: url, filename: "f", connectionCount: 99).connectionCount, 16)
        XCTAssertEqual(HttpDownloadRecord(originalURL: url, filename: "f", connectionCount: 0).connectionCount, 1)
        XCTAssertFalse(HttpDownloadRecord(originalURL: url, filename: "f", connectionCount: 4).isInsecure)
        XCTAssertTrue(HttpDownloadRecord(originalURL: URL(string: "http://example.com/f")!, filename: "f", connectionCount: 4).isInsecure)
    }
    func testDownloadedBytesAndFraction() {
        var r = HttpDownloadRecord(originalURL: url, filename: "f", connectionCount: 4)
        r.totalBytes = 400
        r.chunks = [ChunkState(index: 0, start: 0, end: 99, phase: .done),
                    ChunkState(index: 1, start: 100, end: 199, phase: .inFlight, bytesReceived: 40),
                    ChunkState(index: 2, start: 200, end: 299),
                    ChunkState(index: 3, start: 300, end: 399, phase: .inFlight, bytesReceived: 5000)]  // bogus overshoot is clamped
        XCTAssertEqual(r.downloadedBytes, 100 + 40 + 100)
        XCTAssertEqual(r.fractionCompleted!, 240.0 / 400.0, accuracy: 1e-9)
        XCTAssertEqual(r.chunksDone, 1); XCTAssertEqual(r.chunksInFlight, 2); XCTAssertFalse(r.allChunksDone)
    }
    func testOpenEndedChunkCountsReceivedBytes() {
        var r = HttpDownloadRecord(originalURL: url, filename: "f", connectionCount: 1)
        r.chunks = [ChunkState(index: 0, start: 0, end: -1, phase: .inFlight, bytesReceived: 777)]
        XCTAssertEqual(r.downloadedBytes, 777); XCTAssertNil(r.fractionCompleted)
    }
    func testCodableRoundTrip() throws {
        var r = HttpDownloadRecord(originalURL: url, filename: "f.bin", connectionCount: 6, requestHeaders: ["Accept": "*/*"])
        r.status = .needsAttention; r.attention = .fileChanged
        r.validators = Validators(etag: "\"x\""); r.chunks = ChunkPlanner.plan(totalBytes: 50 << 20, acceptsRanges: true, connections: 6)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(HttpDownloadRecord.self, from: try enc.encode(r))
        XCTAssertEqual(back.id, r.id); XCTAssertEqual(back.attention, .fileChanged); XCTAssertEqual(back.chunks, r.chunks)
        XCTAssertEqual(back.validators, r.validators); XCTAssertEqual(back.connectionCount, 6)
    }
    func testURLKeyNormalisation() {
        func k(_ s: String) -> String? { URLKey.key(for: URL(string: s)!) }
        XCTAssertEqual(k("HTTPS://Example.COM:443/a/b?x=1#frag"), "https://example.com/a/b?x=1")
        XCTAssertEqual(k("http://example.com:80"), "http://example.com/")
        XCTAssertEqual(k("http://example.com:8080/a"), "http://example.com:8080/a")
        XCTAssertEqual(k("https://example.com/a?"), "https://example.com/a")
        XCTAssertNotEqual(k("https://example.com/a?x=1"), k("https://example.com/a?x=2"))
        XCTAssertNotEqual(k("http://example.com/a"), k("https://example.com/a"))
        XCTAssertNil(k("ftp://example.com/a")); XCTAssertNil(k("magnet:?xt=urn:btih:abc"))
    }
    func testSettingsAreClamped() {
        let s = HttpDownloadSettings(defaultConnections: 50, maxSimultaneousDownloads: 0)
        XCTAssertEqual(s.defaultConnections, 16); XCTAssertEqual(s.maxSimultaneousDownloads, 1)
        XCTAssertEqual(HttpDownloadSettings.default.defaultConnections, 4)
    }
}

final class FileAssemblerTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default
    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("asm-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    var final: URL { root.appendingPathComponent("Downloads") }
    var work: URL { root.appendingPathComponent("Downloads/.incoming") }

    func makeParts(_ blobs: [Data]) throws -> [AssemblyPart] {
        try blobs.enumerated().map { i, d in
            let u = root.appendingPathComponent("part-\(i)")
            try d.write(to: u)
            return AssemblyPart(url: u, expectedLength: Int64(d.count))
        }
    }
    func filesIn(_ dir: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
    func bytes(_ n: Int, seed: UInt8) -> Data { FakeServer.makeData(n, seed: Int(seed)) }

    func testJoinsPartsInOrderAndByteExact() throws {
        let blobs = [bytes(300_000, seed: 1), bytes(1, seed: 2), bytes(250_001, seed: 3)]
        var reported: [Int64] = []
        let out = try FileAssembler(bufferSize: 64 * 1024).assemble(parts: try makeParts(blobs), expectedTotal: blobs.reduce(0) { $0 + Int64($1.count) },
                                                                   finalDirectory: final, desiredFilename: "movie.mkv", workDirectory: work) { reported.append($0) }
        XCTAssertEqual(out.lastPathComponent, "movie.mkv")
        XCTAssertEqual(try Data(contentsOf: out), blobs.reduce(Data(), +))
        XCTAssertEqual(reported.last, 550_002)
        XCTAssertEqual(reported, reported.sorted())
    }
    func testNothingElseLeftInDownloadsFolder() throws {
        _ = try FileAssembler().assemble(parts: try makeParts([bytes(10, seed: 1)]), expectedTotal: 10, finalDirectory: final, desiredFilename: "a.bin", workDirectory: work)
        XCTAssertEqual(filesIn(final).filter { $0 != ".incoming" }, ["a.bin"])
        XCTAssertEqual(filesIn(work), [])                       // temp file was moved, not left behind
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("part-0").path))   // parts removed after success
    }
    func testExistingNameGetsSuffixInsteadOfOverwriting() throws {
        try fm.createDirectory(at: final, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: final.appendingPathComponent("a.bin"))
        let out = try FileAssembler().assemble(parts: try makeParts([bytes(4, seed: 9)]), expectedTotal: 4, finalDirectory: final, desiredFilename: "a.bin", workDirectory: work)
        XCTAssertEqual(out.lastPathComponent, "a (1).bin")
        XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("a.bin")), Data("old".utf8))
    }
    func testMaliciousNameCannotEscapeFolder() throws {
        let out = try FileAssembler().assemble(parts: try makeParts([bytes(2, seed: 1)]), expectedTotal: 2, finalDirectory: final, desiredFilename: "../../evil.sh", workDirectory: work)
        XCTAssertEqual(out.deletingLastPathComponent().standardizedFileURL.path, final.standardizedFileURL.path)
        XCTAssertEqual(out.lastPathComponent, "evil.sh")
    }
    func testMissingPartWritesNothing() throws {
        var parts = try makeParts([bytes(5, seed: 1), bytes(5, seed: 2)])
        try fm.removeItem(at: parts[1].url)
        XCTAssertThrowsError(try FileAssembler().assemble(parts: parts, expectedTotal: 10, finalDirectory: final, desiredFilename: "a", workDirectory: work)) {
            XCTAssertEqual($0 as? AssemblyError, .partMissing(index: 1))
        }
        XCTAssertFalse(fm.fileExists(atPath: final.path))
        parts = []
    }
    func testWrongSizedPartIsRejected() throws {
        var parts = try makeParts([bytes(5, seed: 1), bytes(5, seed: 2)])
        parts[0].expectedLength = 6
        XCTAssertThrowsError(try FileAssembler().assemble(parts: parts, expectedTotal: nil, finalDirectory: final, desiredFilename: "a", workDirectory: work)) {
            XCTAssertEqual($0 as? AssemblyError, .partSizeMismatch(index: 0, expected: 6, actual: 5))
        }
        XCTAssertFalse(fm.fileExists(atPath: final.path))
        XCTAssertTrue(fm.fileExists(atPath: parts[0].url.path))   // parts untouched, download can be repaired
    }
    func testTotalMismatchIsRejected() throws {
        XCTAssertThrowsError(try FileAssembler().assemble(parts: try makeParts([bytes(5, seed: 1)]), expectedTotal: 6, finalDirectory: final, desiredFilename: "a", workDirectory: work)) {
            XCTAssertEqual($0 as? AssemblyError, .totalMismatch(expected: 6, actual: 5))
        }
        XCTAssertFalse(fm.fileExists(atPath: final.path))
    }
    func testUnknownTotalAllowsAnyConsistentParts() throws {
        let out = try FileAssembler().assemble(parts: [AssemblyPart(url: try makeParts([bytes(7, seed: 1)])[0].url, expectedLength: nil)], expectedTotal: nil,
                                               finalDirectory: final, desiredFilename: "s.bin", workDirectory: work)
        XCTAssertEqual(try Data(contentsOf: out).count, 7)
    }
    func testZeroByteFile() throws {
        let out = try FileAssembler().assemble(parts: [], expectedTotal: 0, finalDirectory: final, desiredFilename: "empty", workDirectory: work)
        XCTAssertEqual(try Data(contentsOf: out).count, 0)
    }
    func testConsumePolicyDeletesPartsAsItGoes() throws {
        let parts = try makeParts([bytes(100, seed: 1), bytes(100, seed: 2)])
        _ = try FileAssembler().assemble(parts: parts, expectedTotal: 200, finalDirectory: final, desiredFilename: "c.bin", workDirectory: work, policy: .consumeAsWritten)
        XCTAssertTrue(parts.allSatisfy { !fm.fileExists(atPath: $0.url.path) })
    }
    func testFailureAfterConsumingIsReportedAndLeavesNoPartialFile() throws {
        // The "downloads" path is a regular file, so the final move cannot succeed after the parts were consumed.
        let blocker = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let parts = try makeParts([bytes(10, seed: 1)])
        XCTAssertThrowsError(try FileAssembler().assemble(parts: parts, expectedTotal: 10, finalDirectory: blocker, desiredFilename: "a", workDirectory: work, policy: .consumeAsWritten)) {
            guard case AssemblyError.failedAfterConsuming = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(filesIn(work), [])                       // temporary file cleaned up
    }
    func testKeepPolicyFailureKeepsParts() throws {
        let blocker = root.appendingPathComponent("blocker2")
        try Data("x".utf8).write(to: blocker)
        let parts = try makeParts([bytes(10, seed: 1)])
        XCTAssertThrowsError(try FileAssembler().assemble(parts: parts, expectedTotal: 10, finalDirectory: blocker, desiredFilename: "a", workDirectory: work)) {
            guard case AssemblyError.io = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(fm.fileExists(atPath: parts[0].url.path))
    }
}

final class StatisticsTests: XCTestCase {
    func testSnapshotNumbers() {
        var r = HttpDownloadRecord(originalURL: URL(string: "https://e.com/f")!, filename: "f", connectionCount: 8)
        r.totalBytes = 10_000; r.retryCount = 3
        r.chunks = [ChunkState(index: 0, start: 0, end: 4999, phase: .done), ChunkState(index: 1, start: 5000, end: 9999, phase: .inFlight, bytesReceived: 1000)]
        var t = StatisticsTracker()
        t.update(downloadedBytes: 0, at: 0)
        t.update(downloadedBytes: 6000, at: 6)
        let s = t.snapshot(for: r, activeConnections: 1, now: 6)
        XCTAssertEqual(s.downloadedBytes, 6000); XCTAssertEqual(s.currentSpeed, 1000, accuracy: 1e-6)
        XCTAssertEqual(s.averageSpeed, 1000, accuracy: 1e-6); XCTAssertEqual(s.eta!, 4, accuracy: 1e-6)
        XCTAssertEqual(s.activeConnections, 1); XCTAssertEqual(s.configuredConnections, 8)
        XCTAssertEqual(s.retryCount, 3); XCTAssertEqual(s.chunksTotal, 2); XCTAssertEqual(s.chunksDone, 1); XCTAssertEqual(s.chunksInFlight, 1)
        XCTAssertEqual(s.fraction!, 0.6, accuracy: 1e-9)
    }
    func testUnknownTotalHasNoEtaOrFraction() {
        var r = HttpDownloadRecord(originalURL: URL(string: "https://e.com/f")!, filename: "f", connectionCount: 1)
        r.chunks = [ChunkState(index: 0, start: 0, end: -1, phase: .inFlight, bytesReceived: 500)]
        var t = StatisticsTracker(); t.update(downloadedBytes: 0, at: 0); t.update(downloadedBytes: 500, at: 1)
        let s = t.snapshot(for: r, activeConnections: 1, now: 1)
        XCTAssertNil(s.eta); XCTAssertNil(s.fraction)
    }
    func testManagerKeepsIndependentTrackers() {
        let m = DownloadStatisticsManager()
        let a = UUID(), b = UUID()
        m.update(id: a, downloadedBytes: 0, at: 0); m.update(id: a, downloadedBytes: 100, at: 1)
        m.update(id: b, downloadedBytes: 0, at: 0); m.update(id: b, downloadedBytes: 900, at: 1)
        var ra = HttpDownloadRecord(id: a, originalURL: URL(string: "https://e.com/a")!, filename: "a", connectionCount: 4)
        ra.chunks = [ChunkState(index: 0, start: 0, end: 999, phase: .inFlight, bytesReceived: 100)]
        XCTAssertEqual(m.snapshot(for: ra, activeConnections: 1, now: 1).currentSpeed, 100, accuracy: 1e-6)
        m.remove(id: a)
        XCTAssertEqual(m.snapshot(for: ra, activeConnections: 0, now: 1).currentSpeed, 0)
    }
}

final class PersistenceTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("pm-\(UUID().uuidString)") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testSaveLoadAndSensitiveHeadersNeverReachDisk() throws {
        let pm = DownloadPersistenceManager(rootDirectory: root)
        XCTAssertEqual(try pm.load(), [])
        var r = HttpDownloadRecord(originalURL: URL(string: "https://e.com/f")!, filename: "f", connectionCount: 4,
                                   requestHeaders: ["Authorization": "Bearer TOP-SECRET", "Cookie": "sid=SECRET", "Accept": "*/*"])
        r.chunks = ChunkPlanner.plan(totalBytes: 20 << 20, acceptsRanges: true, connections: 4)
        try pm.save([r])
        let raw = try String(contentsOf: root.appendingPathComponent("downloads.json"))
        XCTAssertFalse(raw.contains("TOP-SECRET")); XCTAssertFalse(raw.contains("SECRET"))
        let loaded = try pm.load()
        XCTAssertEqual(loaded.count, 1); XCTAssertEqual(loaded[0].requestHeaders, ["Accept": "*/*"]); XCTAssertEqual(loaded[0].chunks, r.chunks)
        XCTAssertEqual(r.requestHeaders.count, 3)               // the in-memory record keeps them for this session
    }
    func testPartLayoutAndCleanup() throws {
        let pm = DownloadPersistenceManager(rootDirectory: root)
        let id = UUID()
        let p = pm.partURL(for: id, chunk: 7)
        XCTAssertEqual(p.lastPathComponent, "chunk-000007.part")
        XCTAssertTrue(p.path.contains("/Parts/\(id.uuidString)/"))
        XCTAssertNil(pm.partLength(for: id, chunk: 7))
        try FileManager.default.createDirectory(at: pm.partsDirectory(for: id), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 123).write(to: p)
        XCTAssertEqual(pm.partLength(for: id, chunk: 7), 123)
        pm.removeParts(for: id)
        XCTAssertNil(pm.partLength(for: id, chunk: 7))
    }
}

final class RecoveryTests: XCTestCase {
    let url = URL(string: "https://e.com/f")!
    func record(_ status: UnifiedStatus, chunks: [ChunkState]) -> HttpDownloadRecord {
        var r = HttpDownloadRecord(originalURL: url, filename: "f", connectionCount: 4)
        r.status = status; r.totalBytes = 400; r.acceptsRanges = true; r.chunks = chunks
        return r
    }
    func four(_ phases: [ChunkPhase], received: [Int64] = [0, 0, 0, 0]) -> [ChunkState] {
        (0..<4).map { ChunkState(index: $0, start: Int64($0) * 100, end: Int64($0) * 100 + 99, phase: phases[$0], bytesReceived: received[$0]) }
    }
    func run(_ r: HttpDownloadRecord, live: Set<Int> = [], files: [Int: Int64] = [:], auto: Bool = true) -> (HttpDownloadRecord, RecoveryAction) {
        let rep = RecoveryPlanner.reconcile(records: [r], liveChunks: Set(live.map { LiveChunkKey(id: r.id, index: $0) }),
                                            partLength: { _, i in files[i] }, autoResume: auto)
        return (rep.records[0], rep.actions[r.id]!)
    }

    func testDoneChunkWithMissingOrShortFileGoesBackToPending() {
        let (r, a) = run(record(.downloading, chunks: four([.done, .done, .pending, .pending])), files: [0: 100, 1: 60])
        XCTAssertEqual(r.chunks.map(\.phase), [.done, .pending, .pending, .pending])
        XCTAssertEqual(a, .resume); XCTAssertEqual(r.status, .queued)
    }
    func testInFlightWithLiveTaskStaysInFlight() {
        let (r, a) = run(record(.downloading, chunks: four([.done, .inFlight, .pending, .pending], received: [0, 40, 0, 0])), live: [1], files: [0: 100])
        XCTAssertEqual(r.chunks[1].phase, .inFlight); XCTAssertEqual(r.chunks[1].bytesReceived, 40)
        XCTAssertEqual(r.status, .downloading); XCTAssertEqual(a, .resume)
    }
    func testInFlightFinishedWhileAppWasAwayBecomesDone() {
        let (r, _) = run(record(.downloading, chunks: four([.done, .done, .done, .inFlight])), files: [0: 100, 1: 100, 2: 100, 3: 100])
        XCTAssertEqual(r.chunks.map(\.phase), [.done, .done, .done, .done])
        XCTAssertEqual(r.status, .assembling)
    }
    func testAllDoneRequestsAssembly() {
        let (r, a) = run(record(.downloading, chunks: four([.done, .done, .done, .done])), files: [0: 100, 1: 100, 2: 100, 3: 100])
        XCTAssertEqual(a, .assemble); XCTAssertEqual(r.status, .assembling)
    }
    func testInterruptedAssemblyWithAllPartsPresentAssemblesAgain() {
        let (_, a) = run(record(.assembling, chunks: four([.done, .done, .done, .done])), files: [0: 100, 1: 100, 2: 100, 3: 100])
        XCTAssertEqual(a, .assemble)
    }
    func testInterruptedAssemblyWithMissingPartResumesDownloadingThatChunk() {
        let (r, a) = run(record(.assembling, chunks: four([.done, .done, .done, .done])), files: [0: 100, 1: 100, 2: 100])
        XCTAssertEqual(r.chunks.map(\.phase), [.done, .done, .done, .pending]); XCTAssertEqual(a, .resume)
    }
    func testWithoutAutoResumeActiveItemsBecomePaused() {
        let (r, a) = run(record(.downloading, chunks: four([.done, .inFlight, .pending, .pending])), files: [0: 100], auto: false)
        XCTAssertEqual(r.status, .paused); XCTAssertEqual(a, RecoveryAction.none)
        XCTAssertEqual(r.chunks[1].phase, .pending)
    }
    func testItemNeverProbedRestartsOrPauses() {
        XCTAssertEqual(run(record(.probing, chunks: []), auto: true).0.status, .queued)
        XCTAssertEqual(run(record(.probing, chunks: []), auto: false).0.status, .paused)
    }
    func testTerminalAndAttentionItemsAreNotRestarted() {
        for s in [UnifiedStatus.completed, .failed, .needsAttention, .paused] {
            let (r, a) = run(record(s, chunks: four([.done, .pending, .pending, .pending])), files: [0: 100])
            XCTAssertEqual(r.status, s); XCTAssertEqual(a, RecoveryAction.none)
        }
    }
    func testPausedItemStillHasChunkBookkeepingRepaired() {
        let (r, _) = run(record(.paused, chunks: four([.done, .inFlight, .pending, .pending], received: [0, 77, 0, 0])), files: [0: 50])
        XCTAssertEqual(r.chunks.map(\.phase), [.pending, .pending, .pending, .pending])   // chunk 0 file is short
        XCTAssertTrue(r.chunks.allSatisfy { $0.bytesReceived == 0 })
    }
    func testQueuedItemWithChunksIsResumed() {
        XCTAssertEqual(run(record(.queued, chunks: four([.pending, .pending, .pending, .pending]))).1, .resume)
        XCTAssertEqual(run(record(.queued, chunks: [])).1, RecoveryAction.none)
    }
    func testOtherItemsAreNotAffectedByLiveChunksOfADifferentDownload() {
        let a = record(.downloading, chunks: four([.inFlight, .pending, .pending, .pending]))
        let b = record(.downloading, chunks: four([.inFlight, .pending, .pending, .pending]))
        let rep = RecoveryPlanner.reconcile(records: [a, b], liveChunks: [LiveChunkKey(id: a.id, index: 0)], partLength: { _, _ in nil }, autoResume: false)
        XCTAssertEqual(rep.records[0].chunks[0].phase, .inFlight)
        XCTAssertEqual(rep.records[1].chunks[0].phase, .pending)
        XCTAssertEqual(rep.records[1].status, .paused)
    }
}
