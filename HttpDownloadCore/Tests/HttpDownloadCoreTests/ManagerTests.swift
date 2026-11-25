import XCTest
import DownloadSupport
@testable import HttpDownloadCore

struct FixedSpace: FreeSpaceProviding { var bytes: Int64; func availableBytes(at url: URL) throws -> Int64 { bytes } }

class ManagerTestCase: XCTestCase {
    let fm = FileManager.default
    var root: URL!
    var downloads: URL { root.appendingPathComponent("Documents/Downloads") }
    var store: URL { root.appendingPathComponent("AppSupport/HttpDownloads") }

    override func setUpWithError() throws { root = fm.temporaryDirectory.appendingPathComponent("mgr-\(UUID().uuidString)") }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    func settings(retries: Int = 3, connections: Int = 4, simultaneous: Int = 3, insecure: Bool = true) -> HttpDownloadSettings {
        HttpDownloadSettings(defaultConnections: connections, maxSimultaneousDownloads: simultaneous, allowInsecureHTTP: insecure,
                             retry: RetryPolicy(maxRetries: retries, baseDelay: 0, maxDelay: 0, jitterFraction: 0))
    }

    func makeManager(_ transport: FakeTransport, settings s: HttpDownloadSettings? = nil, space: FreeSpaceProviding = FixedSpace(bytes: 1 << 40)) -> HttpDownloadManager {
        HttpDownloadManager(persistence: DownloadPersistenceManager(rootDirectory: store), transport: transport, downloadsDirectory: downloads,
                            settings: s ?? settings(), spaceGuard: DiskSpaceGuard(provider: space, minimumHeadroom: 0, headroomFraction: 0),
                            persistInterval: 0, sleeper: { _ in await Task.yield() })
    }

    func eventually(_ seconds: TimeInterval = 30, _ cond: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if await cond() { return true }; try? await Task.sleep(nanoseconds: 3_000_000) }
        return await cond()
    }
    func waitStatus(_ m: HttpDownloadManager, _ id: UUID, _ s: UnifiedStatus, _ t: TimeInterval = 30) async -> Bool {
        await eventually(t) { await m.record(id)?.status == s }
    }

    // Plain (non-autoclosure, non-generic-async) helpers: call sites write `await expectEqual(await x, y)`.
    func expectTrue(_ v: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(v, file: file, line: line) }
    func expectFalse(_ v: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(v, file: file, line: line) }
    func expectEqual<T: Equatable>(_ x: T, _ y: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(x, y, file: file, line: line) }
    func expectGE<T: Comparable>(_ x: T, _ y: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertGreaterThanOrEqual(x, y, file: file, line: line) }
    func expectNil<T>(_ x: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNil(x, file: file, line: line) }
    let url = URL(string: "https://files.example/pub/data.bin")!
    let MiB = 1 << 20
}

final class ManagerDownloadTests: ManagerTestCase {
    func testDownloadsInChunksAndAssemblesByteExactly() async throws {
        let server = FakeServer(size: 40 * MiB + 123)
        let t = FakeTransport(server: server)
        let m = makeManager(t); await m.start()
        let id = try await m.add(url: url)
        let ok = await waitStatus(m, id, .completed); await expectTrue(ok)
        let r = await m.record(id)!
        XCTAssertEqual(r.finalFilename, "data.bin")
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("data.bin")), server.data)
        XCTAssertGreaterThan(r.chunks.count, 4)                                  // D5: many chunks, not one per connection
        XCTAssertTrue(r.chunks.allSatisfy { $0.phase == .done })
        XCTAssertLessThanOrEqual(t.maxConcurrent, 4)
        XCTAssertFalse(fm.fileExists(atPath: store.appendingPathComponent("Parts/\(id.uuidString)").path))   // parts cleaned up
        XCTAssertEqual(r.totalBytes, Int64(40 * MiB + 123))
        let ls = (try fm.contentsOfDirectory(atPath: downloads.path)).filter { $0 != ".incoming" }
        XCTAssertEqual(ls, ["data.bin"])
        XCTAssertTrue(t.startedSpecs().allSatisfy { $0.range != nil && $0.ifRange == "\"v1\"" })
    }

    func testNeverMoreRequestsThanConfiguredConnections() async throws {
        let server = FakeServer(size: 64 * MiB)
        let t = FakeTransport(server: server); t.autoComplete = false
        let m = makeManager(t); await m.start()
        let id = try await m.add(url: url, connections: 3)
        await expectTrue(await eventually { t.pendingCount() == 3 })
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(t.pendingCount(), 3)                                      // saturated but never above the limit
        t.release(t.pendingKeys()[0].id, t.pendingKeys()[0].chunk)
        await expectTrue(await eventually { t.startedCount() >= 4 })                // a freed slot is refilled
        XCTAssertLessThanOrEqual(t.pendingCount(), 3)
        t.autoComplete = true; t.releaseAll()
        await expectTrue(await waitStatus(m, id, .completed))
        XCTAssertLessThanOrEqual(t.maxConcurrent, 3)
    }

    func testSingleConnectionConfiguration() async throws {
        let t = FakeTransport(server: FakeServer(size: 20 * MiB)); t.autoComplete = false
        let m = makeManager(t); await m.start()
        let id = try await m.add(url: url, connections: 1)
        await expectTrue(await eventually { t.pendingCount() == 1 })
        t.autoComplete = true; t.releaseAll()
        await expectTrue(await waitStatus(m, id, .completed)); await expectEqual(t.maxConcurrent, 1)
    }

    func testServerWithoutRangeSupportUsesOneRequestWithoutRangeHeader() async throws {
        let server = FakeServer(size: 10 * MiB); server.supportsRanges = false
        let t = FakeTransport(server: server)
        let m = makeManager(t); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await waitStatus(m, id, .completed))
        XCTAssertEqual(t.startedCount(), 1); XCTAssertNil(t.startedSpecs()[0].range)
        await expectEqual(await m.record(id)?.acceptsRanges, false)
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("data.bin")), server.data)
    }

    func testServerThatIgnoresRangeAfterProbeFallsBackToSingleStream() async throws {
        let server = FakeServer(size: 30 * MiB); server.ignoreRangeForChunks = true
        let t = FakeTransport(server: server)
        let m = makeManager(t); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await waitStatus(m, id, .completed))
        let r = await m.record(id)!
        XCTAssertEqual(r.acceptsRanges, false)
        XCTAssertGreaterThanOrEqual(r.retryCount, 1)
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("data.bin")), server.data)   // no corrupted assembly
        XCTAssertNil(t.startedSpecs().last?.range)
    }

    func testUnknownSizeStreamCompletesAndLearnsTheSize() async throws {
        let server = FakeServer(size: 3 * MiB + 5); server.knownLength = false
        let t = FakeTransport(server: server)
        let m = makeManager(t); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await waitStatus(m, id, .completed))
        await expectEqual(await m.record(id)?.totalBytes, Int64(3 * MiB + 5))
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("data.bin")), server.data)
    }

    func testEmptyFile() async throws {
        let server = FakeServer(size: 0)
        let m = makeManager(FakeTransport(server: server)); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await waitStatus(m, id, .completed))
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("data.bin")).count, 0)
    }

    func testFilenameFromContentDispositionUnlessUserChoseOne() async throws {
        let server = FakeServer(size: 1 * MiB); server.contentDisposition = "attachment; filename=\"Real Name.iso\""
        let t = FakeTransport(server: server)
        let m = makeManager(t); await m.start()
        let a = try await m.add(url: url)
        let b = try await m.add(url: URL(string: "https://files.example/other.bin")!, filename: "mine.bin")
        await expectTrue(await waitStatus(m, a, .completed)); await expectTrue(await waitStatus(m, b, .completed))
        await expectEqual(await m.record(a)?.finalFilename, "Real Name.iso")
        await expectEqual(await m.record(b)?.finalFilename, "mine.bin")
    }

    func testExistingFileIsNotOverwritten() async throws {
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: downloads.appendingPathComponent("data.bin"))
        let m = makeManager(FakeTransport(server: FakeServer(size: 1 * MiB))); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await waitStatus(m, id, .completed))
        await expectEqual(await m.record(id)?.finalFilename, "data (1).bin")
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("data.bin")), Data("precious".utf8))
    }
}

final class ManagerQueueTests: ManagerTestCase {
    func testDuplicatesAreRejectedAcrossUrlVariants() async throws {
        let m = makeManager(FakeTransport(server: FakeServer(size: 1 * MiB))); await m.start()
        let id = try await m.add(url: URL(string: "https://Files.Example:443/pub/data.bin#x")!)
        do { _ = try await m.add(url: url); XCTFail("duplicate accepted") }
        catch { XCTAssertEqual(error as? HttpDownloadError, .duplicate(existing: id)) }
        let other = try await m.add(url: URL(string: "https://files.example/pub/data.bin?v=2")!)
        XCTAssertNotEqual(other, id)
    }
    func testUnsupportedAndInsecureURLs() async throws {
        let strict = makeManager(FakeTransport(server: FakeServer(size: 1)), settings: settings(insecure: false)); await strict.start()
        do { _ = try await strict.add(url: URL(string: "ftp://x/y")!); XCTFail() } catch { await expectEqual(error as? HttpDownloadError, .unsupportedURL) }
        do { _ = try await strict.add(url: URL(string: "http://x/y")!); XCTFail() } catch { await expectEqual(error as? HttpDownloadError, .insecureNotAllowed) }
        let open = makeManager(FakeTransport(server: FakeServer(size: 1 * MiB)), settings: settings(insecure: true)); await open.start()
        let id = try await open.add(url: URL(string: "http://plain.example/f.bin")!)
        await expectEqual(await open.record(id)?.isInsecure, true)                  // UI shows "Not encrypted"
        await expectTrue(await waitStatus(open, id, .completed))
        await expectEqual(await open.record(id)?.isInsecure, true)
    }
    func testMaxSimultaneousDownloadsIsRespected() async throws {
        let t = FakeTransport(server: FakeServer(size: 16 * MiB)); t.autoComplete = false
        let m = makeManager(t, settings: settings(connections: 2, simultaneous: 2)); await m.start()
        let ids = [try await m.add(url: URL(string: "https://a.example/1.bin")!), try await m.add(url: URL(string: "https://a.example/2.bin")!),
                   try await m.add(url: URL(string: "https://a.example/3.bin")!)]
        await expectTrue(await eventually { t.pendingCount() == 4 })                // 2 downloads x 2 connections
        let statuses = await ids.asyncMap { await m.record($0)!.status }
        XCTAssertEqual(statuses.filter { $0 == .queued }.count, 1)
        t.autoComplete = true; t.releaseAll()
        for id in ids { await expectTrue(await waitStatus(m, id, .completed)) }
    }
    func testConnectionCountClampAndChangeWhilePaused() async throws {
        let t = FakeTransport(server: FakeServer(size: 64 * MiB)); t.autoComplete = false
        let m = makeManager(t); await m.start()
        let id = try await m.add(url: url, connections: 99)
        await expectEqual(await m.record(id)?.connectionCount, 16)
        await expectTrue(await eventually { t.pendingCount() == 8 || t.pendingCount() == 16 || t.pendingCount() > 4 })
        try await m.pause(id)
        try await m.setConnections(id, to: 2)
        try await m.resume(id)
        await expectTrue(await eventually { t.pendingCount() == 2 })
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(t.pendingCount(), 2)
        t.autoComplete = true; t.releaseAll()
        await expectTrue(await waitStatus(m, id, .completed))
    }
    func testRemoveDeletesRecordPartsAndOptionallyFile() async throws {
        let t = FakeTransport(server: FakeServer(size: 16 * MiB)); t.autoComplete = false
        let m = makeManager(t); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await eventually { t.pendingCount() > 0 })
        try await m.remove(id, deleteFiles: true)
        await expectNil(await m.record(id)); await expectEqual(t.pendingCount(), 0)
        XCTAssertFalse(fm.fileExists(atPath: store.appendingPathComponent("Parts/\(id.uuidString)").path))
        do { try await m.pause(id); XCTFail() } catch { await expectEqual(error as? HttpDownloadError, .unknownDownload(id)) }
    }
}

final class ManagerPauseResumeTests: ManagerTestCase {
    func testPauseStopsRequestsAndResumeDoesNotRepeatFinishedChunks() async throws {
        let server = FakeServer(size: 40 * MiB)
        let t = FakeTransport(server: server); t.autoComplete = false
        let m = makeManager(t, settings: settings(connections: 2)); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await eventually { t.pendingCount() == 2 })
        let first = t.pendingKeys().sorted { $0.chunk < $1.chunk }[0]
        t.release(first.id, first.chunk)                                         // chunk 0 finishes
        await expectTrue(await eventually { await m.record(id)?.chunks.first?.phase == .done })
        try await m.pause(id)
        let afterPause = await m.record(id)!
        XCTAssertEqual(afterPause.status, .paused)
        XCTAssertEqual(t.pendingCount(), 0)
        XCTAssertTrue(afterPause.chunks.filter { $0.phase == .inFlight }.isEmpty)
        XCTAssertEqual(afterPause.chunks[0].phase, .done)
        let startedBefore = t.startedCount()
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(t.startedCount(), startedBefore)                          // nothing runs while paused
        try await m.resume(id)
        t.autoComplete = true; t.releaseAll()
        await expectTrue(await waitStatus(m, id, .completed))
        XCTAssertEqual(t.startedSpecs().filter { $0.chunkIndex == 0 }.count, 1)  // finished chunk was kept, not downloaded again
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("data.bin")), server.data)
    }
    func testStaleEventsOfCancelledRequestsAreIgnored() async throws {
        let server = FakeServer(size: 20 * MiB)
        let t = FakeTransport(server: server); t.autoComplete = false
        let m = makeManager(t, settings: settings(connections: 1)); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await eventually { t.pendingCount() == 1 })
        let old = t.startedSpecs()[0]
        try await m.pause(id)
        // a late "finished" from the cancelled request must neither complete the chunk nor touch files
        t.emit(.finished(id: id, chunk: old.chunkIndex, token: old.token, response: HTTPResponseInfo(statusCode: 206), fileSize: 7))
        try? await Task.sleep(nanoseconds: 40_000_000)
        let r = await m.record(id)!
        XCTAssertEqual(r.status, .paused); XCTAssertTrue(r.chunks.allSatisfy { $0.phase == .pending })
    }
    func testPauseResumeOnlyAllowedInRightStates() async throws {
        let t = FakeTransport(server: FakeServer(size: 1 * MiB))
        let m = makeManager(t); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await waitStatus(m, id, .completed))
        do { try await m.pause(id); XCTFail() } catch { guard case HttpDownloadError.invalidState = error else { return XCTFail("\(error)") } }
        do { try await m.resume(id); XCTFail() } catch { guard case HttpDownloadError.invalidState = error else { return XCTFail("\(error)") } }
        do { try await m.retry(id); XCTFail() } catch { guard case HttpDownloadError.invalidState = error else { return XCTFail("\(error)") } }
    }
}

extension Sequence {
    func asyncMap<T>(_ f: (Element) async -> T) async -> [T] { var out: [T] = []; for e in self { out.append(await f(e)) }; return out }
}
