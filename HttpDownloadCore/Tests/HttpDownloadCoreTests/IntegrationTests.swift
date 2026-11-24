import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DownloadSupport
@testable import HttpDownloadCore

/// End-to-end tests of the real transport + manager against tools/http_test_server.py.
/// They run only when HTTP_TEST_SERVER (e.g. http://127.0.0.1:8765) is set, so a plain `swift test` skips them.
final class IntegrationTests: ManagerTestCase {
    var base: String { ProcessInfo.processInfo.environment["HTTP_TEST_SERVER"] ?? "" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(base.isEmpty, "set HTTP_TEST_SERVER to run the integration tests")
        _ = try fetchJSON("/reset")
    }

    func fetchJSON(_ path: String) throws -> [String: Any] {
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: URL(string: base + path)!) { data, _, _ in result = data; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 20)
        guard let data = result else { throw URLError(.cannotConnectToHost) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func file(_ size: Int, _ query: String = "") -> URL { URL(string: "\(base)/file/\(size)\(query.isEmpty ? "" : "?" + query)")! }

    /// The server's body, regenerated: 4 KiB blocks each holding their own block number (8 bytes, repeated).
    func expected(_ size: Int, seed: UInt64 = 0) -> Data {
        var d = Data(capacity: size)
        var b: UInt64 = 0
        while d.count < size {
            var be = (b ^ seed).bigEndian
            let eight = withUnsafeBytes(of: &be) { Data($0) }
            let blk = Data(repeating: 0, count: 0) + Data((0..<512).flatMap { _ in eight })
            d.append(blk.prefix(min(4096, size - d.count)))
            b += 1
        }
        return d
    }

    func makeReal(_ s: HttpDownloadSettings? = nil) -> HttpDownloadManager {
        let pm = DownloadPersistenceManager(rootDirectory: store)
        let t = BackgroundURLSessionTransport(sessionIdentifier: "it.\(UUID().uuidString)", useBackgroundSession: false,
                                              partURL: { pm.partURL(for: $0, chunk: $1) })
        return HttpDownloadManager(persistence: pm, transport: t, downloadsDirectory: downloads, settings: s ?? settings(),
                                   spaceGuard: DiskSpaceGuard(provider: FixedSpace(bytes: 1 << 40), minimumHeadroom: 0, headroomFraction: 0),
                                   persistInterval: 0, sleeper: { _ in await Task.yield() })
    }

    func downloaded(_ name: String) throws -> Data { try Data(contentsOf: downloads.appendingPathComponent(name)) }

    func testChunkedRangeDownloadIsByteExactAndRespectsConnections() async throws {
        let size = 24 * MiB + 777
        let m = makeReal(settings(connections: 4)); await m.start()
        let id = try await m.add(url: file(size, "slow=40000000"))
        await expectTrue(await waitStatus(m, id, .completed, 60))
        XCTAssertEqual(try downloaded("\(size)"), expected(size))
        let log = try fetchJSON("/log")
        let reqs = (log["requests"] as? [[String: Any]]) ?? []
        let ranged = reqs.filter { ($0["range"] as? String) != nil && ($0["range"] as? String) != "bytes=0-0" }
        XCTAssertGreaterThan(ranged.count, 4)                                       // chunked, not one request per connection
        XCTAssertTrue(ranged.allSatisfy { ($0["if_range"] as? String) == "\"v1\"" })
        XCTAssertTrue(reqs.allSatisfy { ($0["accept_encoding"] as? String) == "identity" })
        XCTAssertLessThanOrEqual((log["max_active"] as? Int) ?? 99, 4 + 2)         // + the two probe requests may overlap briefly
    }

    func testServerWithoutRangeSupport() async throws {
        let size = 6 * MiB + 1
        let m = makeReal(); await m.start()
        let id = try await m.add(url: file(size, "ranges=0"))
        await expectTrue(await waitStatus(m, id, .completed, 60))
        XCTAssertEqual(try downloaded("\(size)"), expected(size))
        await expectEqual(await m.record(id)?.acceptsRanges, false)
    }

    func testServerIgnoringRangeFallsBackToSingleStream() async throws {
        let size = 12 * MiB
        let m = makeReal(); await m.start()
        let id = try await m.add(url: file(size, "ignore_range=1"))
        await expectTrue(await waitStatus(m, id, .completed, 60))
        XCTAssertEqual(try downloaded("\(size)"), expected(size))
        await expectEqual(await m.record(id)?.acceptsRanges, false)
    }

    func testWrongContentRangeIsRefused() async throws {
        let m = makeReal(settings(retries: 1)); await m.start()
        let id = try await m.add(url: file(12 * MiB, "bad_range=1"))
        await expectTrue(await waitStatus(m, id, .needsAttention, 60))
        await expectEqual(await m.record(id)?.attention, .rangeUnreliable)
        XCTAssertFalse(fm.fileExists(atPath: downloads.appendingPathComponent("\(12 * MiB)").path))
    }

    func testBusyServerIsRetried() async throws {
        let size = 3 * MiB
        let m = makeReal(); await m.start()
        let id = try await m.add(url: file(size, "fail=503&times=2"))
        await expectTrue(await waitStatus(m, id, .completed, 60))
        XCTAssertEqual(try downloaded("\(size)"), expected(size))
        let retries = await m.record(id)!.retryCount
        XCTAssertGreaterThanOrEqual(retries, 1)
    }

    func testConnectionDroppedMidBodyIsRetried() async throws {
        let size = 12 * MiB
        let m = makeReal(settings(retries: 6)); await m.start()
        let id = try await m.add(url: file(size, "drop_after=300000&drop_times=2"))
        await expectTrue(await waitStatus(m, id, .completed, 60))
        XCTAssertEqual(try downloaded("\(size)"), expected(size))
        let retries = await m.record(id)!.retryCount
        XCTAssertGreaterThanOrEqual(retries, 1)
    }

    func testRedirectIsFollowed() async throws {
        let size = 2 * MiB
        let m = makeReal(); await m.start()
        let id = try await m.add(url: file(size, "redirect=1&cd=moved.bin"))
        await expectTrue(await waitStatus(m, id, .completed, 60))
        XCTAssertEqual(try downloaded("moved.bin"), expected(size))
    }

    func testUnknownLengthStream() async throws {
        let size = 3 * MiB + 5
        let m = makeReal(); await m.start()
        let id = try await m.add(url: file(size, "nolen=1&ranges=0"))
        await expectTrue(await waitStatus(m, id, .completed, 60))
        XCTAssertEqual(try downloaded("\(size)"), expected(size))
        await expectEqual(await m.record(id)?.totalBytes, Int64(size))
    }

    func testHeadRefusedStillWorksThroughRangeProbe() async throws {
        let size = 5 * MiB
        let m = makeReal(); await m.start()
        let id = try await m.add(url: file(size, "head=405"))
        await expectTrue(await waitStatus(m, id, .completed, 60))
        XCTAssertEqual(try downloaded("\(size)"), expected(size))
    }

    func testMissingFileNeedsAttention() async throws {
        let m = makeReal(); await m.start()
        let id = try await m.add(url: URL(string: "\(base)/nope/1")!)
        await expectTrue(await waitStatus(m, id, .needsAttention, 30))
        await expectEqual(await m.record(id)?.attention, .accessDenied)
    }

    func testPauseAndResumeAgainstARealServer() async throws {
        let size = 24 * MiB
        let m = makeReal(settings(connections: 2)); await m.start()
        let id = try await m.add(url: file(size, "slow=6000000"))
        await expectTrue(await eventually(30) { await m.record(id)?.chunksDone ?? 0 >= 1 })
        try await m.pause(id)
        await expectEqual(await m.record(id)?.status, .paused)
        let doneBefore = await m.record(id)!.chunksDone
        try await m.resume(id)
        await expectTrue(await waitStatus(m, id, .completed, 90))
        XCTAssertGreaterThanOrEqual(doneBefore, 1)
        XCTAssertEqual(try downloaded("\(size)"), expected(size))
    }
}

