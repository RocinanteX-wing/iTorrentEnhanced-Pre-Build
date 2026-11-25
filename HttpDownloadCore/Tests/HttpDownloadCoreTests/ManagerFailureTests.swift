import XCTest
import DownloadSupport
@testable import HttpDownloadCore

final class ManagerFailureTests: ManagerTestCase {
    func data(_ name: String = "data.bin") -> URL { downloads.appendingPathComponent(name) }

    func testTransientNetworkErrorsAreRetried() async throws {
        let server = FakeServer(size: 24 * MiB); server.connectionFailures = 3
        let t = FakeTransport(server: server)
        let m = makeManager(t, settings: settings(retries: 5)); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await waitStatus(m, id, .completed))
        let r = await m.record(id)!
        XCTAssertGreaterThanOrEqual(r.retryCount, 3)
        XCTAssertEqual(try Data(contentsOf: data()), server.data)
    }

    func testServerBusyAnswersAreRetried() async throws {
        let server = FakeServer(size: 24 * MiB); server.forcedStatuses = [503, 429]
        let m = makeManager(FakeTransport(server: server)); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await waitStatus(m, id, .completed))
        await expectGE(await m.record(id)!.retryCount, 2)
        XCTAssertEqual(try Data(contentsOf: data()), server.data)
    }

    func testRetryBudgetExhaustedFailsThenManualRetryWorks() async throws {
        let server = FakeServer(size: 24 * MiB); server.connectionFailures = 10_000
        let t = FakeTransport(server: server)
        let m = makeManager(t, settings: settings(retries: 2)); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await waitStatus(m, id, .failed))
        let failed = await m.record(id)!
        XCTAssertTrue(failed.lastError?.contains("Giving up") == true)
        XCTAssertFalse(fm.fileExists(atPath: data().path))                      // an incomplete file is never presented as finished
        server.mutate { $0.connectionFailures = 0 }
        try await m.retry(id)
        await expectTrue(await waitStatus(m, id, .completed))
        XCTAssertEqual(try Data(contentsOf: data()), server.data)
    }

    func testWrongContentRangeIsNeverAssembled() async throws {
        let server = FakeServer(size: 24 * MiB); server.wrongContentRange = true
        let m = makeManager(FakeTransport(server: server), settings: settings(retries: 2)); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await waitStatus(m, id, .needsAttention))
        let r = await m.record(id)!
        XCTAssertEqual(r.attention, .rangeUnreliable)
        XCTAssertFalse(fm.fileExists(atPath: data().path))
        XCTAssertTrue(r.chunks.allSatisfy { $0.phase != .done })               // no mismatching chunk was accepted
    }

    func testExpiredLinkMidDownloadNeedsAttentionAndRetryKeepsFinishedChunks() async throws {
        let server = FakeServer(size: 40 * MiB)
        let t = FakeTransport(server: server); t.autoComplete = false
        let m = makeManager(t, settings: settings(connections: 2)); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await eventually { t.pendingCount() == 2 })
        t.release(id, 0)
        await expectTrue(await eventually { await m.record(id)?.chunks[0].phase == .done })
        server.mutate { $0.forcedStatuses = [403] }
        t.release(id, 1)
        await expectTrue(await waitStatus(m, id, .needsAttention))
        let r = await m.record(id)!
        XCTAssertEqual(r.attention, .accessDenied)
        XCTAssertEqual(r.chunks[0].phase, .done)                               // finished work is kept
        XCTAssertEqual(t.pendingCount(), 0)                                    // nothing keeps hammering the server
        server.mutate { $0.forcedStatuses = [] }
        t.autoComplete = true
        try await m.retry(id)
        await expectTrue(await waitStatus(m, id, .completed))
        XCTAssertEqual(t.startedSpecs().filter { $0.chunkIndex == 0 }.count, 1)
        XCTAssertEqual(try Data(contentsOf: data()), server.data)
    }

    func testFileChangedOnServerIsDetectedAndRetryRestartsCleanly() async throws {
        let server = FakeServer(size: 40 * MiB)
        let t = FakeTransport(server: server); t.autoComplete = false
        let m = makeManager(t, settings: settings(connections: 2)); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await eventually { t.pendingCount() == 2 })
        t.release(id, 0)
        await expectTrue(await eventually { await m.record(id)?.chunks[0].phase == .done })
        let replacement = FakeServer.makeData(40 * MiB, seed: 99)
        server.setData(replacement, etag: "\"v2\"")
        t.release(id, 1)                                                       // If-Range "v1" no longer matches -> 200 + new body
        await expectTrue(await waitStatus(m, id, .needsAttention))
        await expectEqual(await m.record(id)?.attention, .fileChanged)
        XCTAssertFalse(fm.fileExists(atPath: data().path))                     // old + new bytes were never stitched together
        t.autoComplete = true
        try await m.retry(id)
        await expectTrue(await waitStatus(m, id, .completed))
        XCTAssertEqual(try Data(contentsOf: data()), replacement)
    }

    func testProbeRefusalsMapToNeedsAttention() async throws {
        let t = FakeTransport(server: FakeServer(size: 1 * MiB))
        t.probeOverride = ProbeResponses(head: HTTPResponseInfo(statusCode: 401), rangeProbe: HTTPResponseInfo(statusCode: 401))
        let m = makeManager(t); await m.start()
        let a = try await m.add(url: url)
        await expectTrue(await waitStatus(m, a, .needsAttention))
        await expectEqual(await m.record(a)?.attention, .authenticationRequired)
        t.probeOverride = ProbeResponses(head: HTTPResponseInfo(statusCode: 404), rangeProbe: HTTPResponseInfo(statusCode: 404))
        let b = try await m.add(url: URL(string: "https://files.example/gone.bin")!)
        await expectTrue(await waitStatus(m, b, .needsAttention))
        await expectEqual(await m.record(b)?.attention, .accessDenied)
        XCTAssertEqual(t.startedCount(), 0)
    }

    func testUnavailableServerIsProbedAgainThenRecovers() async throws {
        let t = FakeTransport(server: FakeServer(size: 4 * MiB))
        t.failNextProbes(3)                                                     // three 503s, then the server is healthy
        let m = makeManager(t, settings: settings(retries: 5)); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await waitStatus(m, id, .completed))
        await expectEqual(await m.record(id)!.retryCount, 3)                    // exactly the three failed probes
        XCTAssertEqual(t.probesServed, 4)
    }

    func testProbeRetryBudgetExhaustedFailsInsteadOfLoopingForever() async throws {
        let t = FakeTransport(server: FakeServer(size: 4 * MiB))
        t.failNextProbes(1_000)
        let m = makeManager(t, settings: settings(retries: 2)); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await waitStatus(m, id, .failed))
        XCTAssertEqual(t.probesServed, 3)                                       // first try + 2 retries, then it stops
        let failedRecord = await m.record(id)
        XCTAssertTrue(failedRecord?.lastError?.contains("could not be reached") == true)
        t.failNextProbes(0)
        try await m.retry(id)                                                   // a manual retry gets a fresh budget
        await expectTrue(await waitStatus(m, id, .completed))
    }

    func testInsufficientSpaceNeedsAttentionWithoutDownloading() async throws {
        let t = FakeTransport(server: FakeServer(size: 40 * MiB))
        let m = makeManager(t, space: FixedSpace(bytes: 1 * MiB32)); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await waitStatus(m, id, .needsAttention))
        await expectEqual(await m.record(id)?.attention, .insufficientSpace)
        XCTAssertEqual(t.startedCount(), 0)
        XCTAssertFalse(fm.fileExists(atPath: data().path))
    }

    func testStatisticsExposeConnectionsAndChunkProgress() async throws {
        let t = FakeTransport(server: FakeServer(size: 64 * MiB)); t.autoComplete = false
        let m = makeManager(t, settings: settings(connections: 4)); await m.start()
        let id = try await m.add(url: url)
        await expectTrue(await eventually { t.pendingCount() == 4 })
        t.release(id, 0)
        await expectTrue(await eventually { await m.record(id)?.chunks[0].phase == .done })
        let s = await m.statistics(for: id)!
        XCTAssertEqual(s.configuredConnections, 4); XCTAssertEqual(s.activeConnections, 4)
        XCTAssertEqual(s.chunksDone, 1); XCTAssertEqual(s.chunksTotal, 8)
        XCTAssertEqual(s.totalBytes, Int64(64 * MiB)); XCTAssertGreaterThan(s.downloadedBytes, 0)
        t.autoComplete = true; t.releaseAll()
        await expectTrue(await waitStatus(m, id, .completed))
        await expectEqual(await m.statistics(for: id)?.chunksDone, 8)
    }

    func testSecretsNeverReachDiskOrErrorText() async throws {
        let t = FakeTransport(server: FakeServer(size: 24 * MiB)); t.autoComplete = false
        let m = makeManager(t, settings: settings(retries: 5)); await m.start()
        let id = try await m.add(url: url, headers: ["Authorization": "Bearer TOPSECRET", "Accept": "*/*"])
        await expectTrue(await eventually { t.pendingCount() > 0 })
        let spec = t.startedSpecs()[0]
        XCTAssertEqual(spec.headers["Authorization"], "Bearer TOPSECRET")       // used in memory for this session
        t.emit(.failed(id: id, chunk: spec.chunkIndex, token: spec.token,
                       failure: TransportFailure(kind: .connectivity, message: "could not load https://files.example/pub/data.bin?sig=TOPSECRET2 (-1009)")))
        await expectTrue(await eventually { await m.record(id)?.lastError != nil })
        await m.flush()
        let saved = try String(contentsOf: store.appendingPathComponent("downloads.json"))
        XCTAssertFalse(saved.contains("TOPSECRET"))                             // covers both the header and the URL token
        let err = await m.record(id)!.lastError!
        XCTAssertFalse(err.contains("TOPSECRET2")); XCTAssertTrue(err.contains("-1009"))
    }
}

final class ManagerRecoveryTests: ManagerTestCase {
    func testRestartContinuesFromPersistedChunksWithoutRepeatingFinishedOnes() async throws {
        let server = FakeServer(size: 48 * MiB)
        let t1 = FakeTransport(server: server); t1.autoComplete = false
        let m1 = makeManager(t1, settings: settings(connections: 2)); await m1.start()
        let id = try await m1.add(url: url)
        await expectTrue(await eventually { t1.pendingCount() == 2 })
        t1.release(id, 0)
        await expectTrue(await eventually { t1.startedCount() >= 3 })           // chunk 2 started after chunk 0 finished
        t1.release(id, 1)
        await expectTrue(await eventually { await m1.record(id)?.chunks[1].phase == .done })
        await m1.flush()                                                        // "the app is killed here"

        let t2 = FakeTransport(server: server)
        let m2 = makeManager(t2, settings: settings(connections: 2)); await m2.start()
        await expectTrue(await waitStatus(m2, id, .completed))
        let requested = Set(t2.startedSpecs().map(\.chunkIndex))
        XCTAssertFalse(requested.contains(0)); XCTAssertFalse(requested.contains(1))   // finished chunks were found on disk
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("data.bin")), server.data)
    }

    func testRelaunchReattachesToBackgroundRequestsStillRunning() async throws {
        let server = FakeServer(size: 32 * MiB)
        let t1 = FakeTransport(server: server); t1.autoComplete = false
        let m1 = makeManager(t1, settings: settings(connections: 2)); await m1.start()
        let id = try await m1.add(url: url)
        await expectTrue(await eventually { t1.pendingCount() == 2 })
        let live = t1.startedSpecs()
        await m1.flush()

        let t2 = FakeTransport(server: server)
        t2.liveOnRelaunch = Set(live.map { LiveChunk(key: LiveChunkKey(id: $0.downloadID, index: $0.chunkIndex), token: $0.token) })
        let m2 = makeManager(t2, settings: settings(connections: 2)); await m2.start()
        let afterStart = await m2.record(id)!
        XCTAssertEqual(afterStart.status, .downloading)
        XCTAssertEqual(afterStart.chunks.filter { $0.phase == .inFlight }.count, 2)  // adopted, not restarted
        XCTAssertFalse(t2.startedSpecs().contains { live.map(\.chunkIndex).contains($0.chunkIndex) })
        // the OS finishes the two background transfers while the app is relaunching
        for spec in live {
            if case .response(let resp, let body) = server.outcome(for: spec) {
                try FileManager.default.createDirectory(at: spec.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try body.write(to: spec.destination)
                t2.emit(.finished(id: id, chunk: spec.chunkIndex, token: spec.token, response: resp, fileSize: Int64(body.count)))
            }
        }
        await expectTrue(await waitStatus(m2, id, .completed))
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("data.bin")), server.data)
    }

    func testRelaunchWithAllChunksOnDiskJustAssembles() async throws {
        // The persisted state of an app that was killed while assembling: every chunk finished, every part on disk.
        let server = FakeServer(size: 24 * MiB)
        let pm = DownloadPersistenceManager(rootDirectory: store)
        var rec = HttpDownloadRecord(originalURL: url, filename: "data.bin", connectionCount: 4)
        rec.totalBytes = Int64(server.data.count); rec.acceptsRanges = true; rec.validators = Validators(etag: "\"v1\"")
        rec.chunks = ChunkPlanner.plan(totalBytes: rec.totalBytes, acceptsRanges: true, connections: 4)
        for i in rec.chunks.indices {
            rec.chunks[i].phase = .done
            let c = rec.chunks[i]
            try fm.createDirectory(at: pm.partsDirectory(for: rec.id), withIntermediateDirectories: true)
            try server.data.subdata(in: Int(c.start)..<Int(c.end + 1)).write(to: pm.partURL(for: rec.id, chunk: c.index))
        }
        rec.status = .assembling
        try pm.save([rec])

        let t = FakeTransport(server: server)
        let m = makeManager(t); await m.start()
        await expectTrue(await waitStatus(m, rec.id, .completed))
        XCTAssertEqual(t.startedCount(), 0)                                      // no network needed
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("data.bin")), server.data)
    }

    func testRelaunchWithAMissingPartDownloadsOnlyThatChunk() async throws {
        let server = FakeServer(size: 24 * MiB)
        let pm = DownloadPersistenceManager(rootDirectory: store)
        var rec = HttpDownloadRecord(originalURL: url, filename: "data.bin", connectionCount: 4)
        rec.totalBytes = Int64(server.data.count); rec.acceptsRanges = true; rec.validators = Validators(etag: "\"v1\"")
        rec.chunks = ChunkPlanner.plan(totalBytes: rec.totalBytes, acceptsRanges: true, connections: 4)
        for i in rec.chunks.indices {
            rec.chunks[i].phase = .done
            let c = rec.chunks[i]
            try fm.createDirectory(at: pm.partsDirectory(for: rec.id), withIntermediateDirectories: true)
            if c.index != 2 { try server.data.subdata(in: Int(c.start)..<Int(c.end + 1)).write(to: pm.partURL(for: rec.id, chunk: c.index)) }
        }
        rec.status = .assembling
        try pm.save([rec])
        let t = FakeTransport(server: server)
        let m = makeManager(t); await m.start()
        await expectTrue(await waitStatus(m, rec.id, .completed))
        XCTAssertEqual(t.startedSpecs().map(\.chunkIndex), [2])                  // only the damaged chunk is fetched again
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("data.bin")), server.data)
    }

    func testOrphanedPartFoldersAreCleanedUp() async throws {
        let orphan = store.appendingPathComponent("Parts/\(UUID().uuidString)")
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: orphan.appendingPathComponent("chunk-000000.part"))
        let m = makeManager(FakeTransport(server: FakeServer(size: 1))); await m.start()
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
    }
}

extension ManagerTestCase { var MiB32: Int64 { 1 << 20 } }
