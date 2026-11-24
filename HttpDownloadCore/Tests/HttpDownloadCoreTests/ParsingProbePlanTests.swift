import XCTest
@testable import HttpDownloadCore

final class ContentRangeTests: XCTestCase {
    func testValid() {
        XCTAssertEqual(ContentRange.parse("bytes 0-99/1234"), ContentRange(start: 0, end: 99, total: 1234))
        XCTAssertEqual(ContentRange.parse("bytes 0-0/1"), ContentRange(start: 0, end: 0, total: 1))
        XCTAssertEqual(ContentRange.parse("  Bytes 5-9/*  "), ContentRange(start: 5, end: 9, total: nil))
    }
    func testUnsatisfied() {
        let cr = ContentRange.parse("bytes */1234")
        XCTAssertEqual(cr?.isUnsatisfied, true)
        XCTAssertEqual(cr?.total, 1234)
    }
    func testInvalid() {
        for bad in ["", "items 0-1/2", "bytes 0-1", "bytes 5-1/10", "bytes 0-10/10", "bytes a-b/10", "bytes 0-1/x", "bytes -1-5/10"] {
            XCTAssertNil(ContentRange.parse(bad), bad)
        }
    }
}

final class ContentDispositionTests: XCTestCase {
    func testQuoted() { XCTAssertEqual(ContentDisposition.filename(from: "attachment; filename=\"report 2024.pdf\""), "report 2024.pdf") }
    func testUnquoted() { XCTAssertEqual(ContentDisposition.filename(from: "attachment; filename=data.zip"), "data.zip") }
    func testEscapedQuoteAndSemicolonInside() {
        XCTAssertEqual(ContentDisposition.filename(from: "attachment; filename=\"a;b \\\"c\\\".txt\""), "a;b \"c\".txt")
    }
    func testExtendedPreferredOverPlain() {
        let h = "attachment; filename=\"fallback.txt\"; filename*=UTF-8''%E2%82%AC%20rates.txt"
        XCTAssertEqual(ContentDisposition.filename(from: h), "€ rates.txt")
    }
    func testLatin1Extended() {
        XCTAssertEqual(ContentDisposition.filename(from: "attachment; filename*=ISO-8859-1''caf%E9.txt"), "café.txt")
    }
    func testBrokenPercentEncodingFallsBackToPlain() {
        XCTAssertEqual(ContentDisposition.filename(from: "attachment; filename*=UTF-8''%zz; filename=\"ok.bin\""), "ok.bin")
    }
    func testNoFilename() {
        XCTAssertNil(ContentDisposition.filename(from: "inline"))
        XCTAssertNil(ContentDisposition.filename(from: "attachment; name=x"))
    }
}

final class FilenameTests: XCTestCase {
    func testPathTraversalAndSeparators() {
        XCTAssertEqual(FilenameSanitizer.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(FilenameSanitizer.sanitize("..\\..\\windows\\evil.exe"), "evil.exe")
        XCTAssertEqual(FilenameSanitizer.sanitize("/"), "download")
        XCTAssertEqual(FilenameSanitizer.sanitize(".."), "download")
        XCTAssertEqual(FilenameSanitizer.sanitize("."), "download")
    }
    func testReservedAndControlCharacters() {
        XCTAssertEqual(FilenameSanitizer.sanitize("a:b*c?d\"e<f>g|h.txt"), "a_b_c_d_e_f_g_h.txt")
        XCTAssertEqual(FilenameSanitizer.sanitize("tab\there\n.bin"), "tab_here_.bin")
    }
    func testLeadingAndTrailingDots() {
        XCTAssertEqual(FilenameSanitizer.sanitize(".hidden"), "hidden")
        XCTAssertEqual(FilenameSanitizer.sanitize("name. . "), "name")
    }
    func testLongNamesKeepExtension() {
        let long = String(repeating: "a", count: 400) + ".mkv"
        let s = FilenameSanitizer.sanitize(long)
        XCTAssertLessThanOrEqual(s.utf8.count, FilenameSanitizer.maxBytes)
        XCTAssertTrue(s.hasSuffix(".mkv"))
    }
    func testUnicodeLongNameIsNotCutMidCharacter() {
        let long = String(repeating: "日本語", count: 100) + ".txt"
        let s = FilenameSanitizer.sanitize(long)
        XCTAssertLessThanOrEqual(s.utf8.count, FilenameSanitizer.maxBytes)
        XCTAssertTrue(s.hasSuffix(".txt"))
        XCTAssertNotNil(String(data: Data(s.utf8), encoding: .utf8))
    }
    func testResolverOrder() {
        let url = URL(string: "https://x.example/dir/My%20File.iso?token=1")!
        XCTAssertEqual(FilenameResolver.resolve(contentDisposition: "attachment; filename=\"from-header.bin\"", url: url), "from-header.bin")
        XCTAssertEqual(FilenameResolver.resolve(contentDisposition: nil, url: url), "My File.iso")
        XCTAssertEqual(FilenameResolver.resolve(contentDisposition: "attachment; filename=\"..\"", url: url), "My File.iso")
        XCTAssertEqual(FilenameResolver.resolve(contentDisposition: nil, url: URL(string: "https://x.example/")!), "download")
    }
    func testUniqueFilename() {
        let taken: Set<String> = ["a.zip", "a (1).zip", "noext", "noext (1)"]
        XCTAssertEqual(UniqueFilename.resolve("fresh.zip") { taken.contains($0) }, "fresh.zip")
        XCTAssertEqual(UniqueFilename.resolve("a.zip") { taken.contains($0) }, "a (2).zip")
        XCTAssertEqual(UniqueFilename.resolve("noext") { taken.contains($0) }, "noext (2)")
    }
}

final class ValidatorsTests: XCTestCase {
    func testIfRangePrefersStrongEtag() {
        XCTAssertEqual(Validators(etag: "\"abc\"", lastModified: "Mon").ifRangeValue, "\"abc\"")
        XCTAssertEqual(Validators(etag: "W/\"abc\"", lastModified: "Mon").ifRangeValue, "Mon")   // weak ETag not allowed in If-Range
        XCTAssertNil(Validators().ifRangeValue)
    }
    func testCompare() {
        XCTAssertEqual(Validators(etag: "\"a\"").compare(to: Validators(etag: "\"a\"")), .same)
        XCTAssertEqual(Validators(etag: "\"a\"").compare(to: Validators(etag: "W/\"a\"")), .same)
        XCTAssertEqual(Validators(etag: "\"a\"").compare(to: Validators(etag: "\"b\"")), .different)
        XCTAssertEqual(Validators(lastModified: "X").compare(to: Validators(lastModified: "Y")), .different)
        XCTAssertEqual(Validators(etag: "\"a\"", lastModified: "X").compare(to: Validators(etag: "\"b\"", lastModified: "X")), .different)
        XCTAssertEqual(Validators(etag: "\"a\"").compare(to: Validators()), .unknown)
        XCTAssertEqual(Validators(etag: " ").etag, nil)
    }
    func testResponseHeadersAreCaseInsensitive() {
        let r = HTTPResponseInfo(statusCode: 200, headers: ["ETag": "\"x\"", "LAST-MODIFIED": "Tue"])
        XCTAssertEqual(Validators(response: r), Validators(etag: "\"x\"", lastModified: "Tue"))
    }
}

final class ProbeTests: XCTestCase {
    let url = URL(string: "https://files.example/pub/big.iso")!
    func resp(_ code: Int, _ h: [String: String] = [:], url: URL? = nil) -> HTTPResponseInfo { HTTPResponseInfo(statusCode: code, headers: h, url: url) }

    func testRangeProbeIsAuthoritative() throws {
        let head = resp(200, ["Content-Length": "1000", "Accept-Ranges": "none"])
        let probe = resp(206, ["Content-Range": "bytes 0-0/5000", "ETag": "\"e1\"", "Content-Length": "1"])
        let r = try ProbeInterpreter.interpret(head: head, rangeProbe: probe, requestedURL: url)
        XCTAssertTrue(r.acceptsRanges)
        XCTAssertEqual(r.totalBytes, 5000)
        XCTAssertEqual(r.validators.etag, "\"e1\"")
        XCTAssertEqual(r.suggestedFilename, "big.iso")
    }
    func testHeadFailsButRangeProbeWorks() throws {
        let r = try ProbeInterpreter.interpret(head: resp(405), rangeProbe: resp(206, ["Content-Range": "bytes 0-0/42"]), requestedURL: url)
        XCTAssertTrue(r.acceptsRanges); XCTAssertEqual(r.totalBytes, 42)
    }
    func testServerIgnoringRangeAnswers200() throws {
        let r = try ProbeInterpreter.interpret(head: resp(200, ["Content-Length": "77"]), rangeProbe: resp(200, ["Content-Length": "77"]), requestedURL: url)
        XCTAssertFalse(r.acceptsRanges); XCTAssertEqual(r.totalBytes, 77)
    }
    func testHeadOnlyAcceptRanges() throws {
        let yes = try ProbeInterpreter.interpret(head: resp(200, ["Content-Length": "9", "Accept-Ranges": "bytes"]), rangeProbe: nil, requestedURL: url)
        XCTAssertTrue(yes.acceptsRanges)
        let no = try ProbeInterpreter.interpret(head: resp(200, ["Content-Length": "9"]), rangeProbe: nil, requestedURL: url)
        XCTAssertFalse(no.acceptsRanges)
    }
    func testContentCodedMeansUnknownSizeAndNoRanges() throws {
        let probe = resp(206, ["Content-Range": "bytes 0-0/500", "Content-Encoding": "gzip"])
        let r = try ProbeInterpreter.interpret(head: nil, rangeProbe: probe, requestedURL: url)
        XCTAssertFalse(r.acceptsRanges); XCTAssertNil(r.totalBytes)
    }
    func testUnknownTotalInContentRange() throws {
        let r = try ProbeInterpreter.interpret(head: nil, rangeProbe: resp(206, ["Content-Range": "bytes 0-0/*"]), requestedURL: url)
        XCTAssertTrue(r.acceptsRanges); XCTAssertNil(r.totalBytes)
    }
    func testFinalURLAndDispositionFilename() throws {
        let final = URL(string: "https://cdn.example/x/y?sig=1")!
        let probe = resp(206, ["Content-Range": "bytes 0-0/10", "Content-Disposition": "attachment; filename=\"real name.7z\""], url: final)
        let r = try ProbeInterpreter.interpret(head: nil, rangeProbe: probe, requestedURL: url)
        XCTAssertEqual(r.finalURL, final); XCTAssertEqual(r.suggestedFilename, "real name.7z")
    }
    func testFailuresMapToTypedErrors() {
        func f(_ code: Int) -> ProbeFailure? {
            do { _ = try ProbeInterpreter.interpret(head: resp(code), rangeProbe: resp(code), requestedURL: url); return nil }
            catch { return error as? ProbeFailure }
        }
        XCTAssertEqual(f(403), .accessDenied(403)); XCTAssertEqual(f(401), .accessDenied(401))
        XCTAssertEqual(f(404), .notFound(404)); XCTAssertEqual(f(410), .notFound(410))
        XCTAssertEqual(f(503), .serverError(503)); XCTAssertEqual(f(429), .serverError(429))
        XCTAssertEqual(f(302), .unexpectedStatus(302))
        XCTAssertThrowsError(try ProbeInterpreter.interpret(head: nil, rangeProbe: nil, requestedURL: url))
    }
}

final class ChunkPlannerTests: XCTestCase {
    let MiB: Int64 = 1 << 20

    func assertValidPlan(_ chunks: [ChunkState], total: Int64, file: StaticString = #filePath, line: UInt = #line) {
        var expectedStart: Int64 = 0
        for (i, c) in chunks.enumerated() {
            XCTAssertEqual(c.index, i, file: file, line: line)
            XCTAssertEqual(c.start, expectedStart, "gap or overlap at chunk \(i)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(c.end, c.start, file: file, line: line)
            expectedStart = c.end + 1
        }
        XCTAssertEqual(expectedStart, total, "plan must cover exactly the file", file: file, line: line)
    }

    func testUnknownSizeIsOneOpenEndedChunk() {
        let p = ChunkPlanner.plan(totalBytes: nil, acceptsRanges: true, connections: 8)
        XCTAssertEqual(p, [ChunkState(index: 0, start: 0, end: -1)])
        XCTAssertTrue(p[0].isOpenEnded); XCTAssertNil(p[0].length)
    }
    func testNoRangeSupportIsSingleWholeFile() {
        let p = ChunkPlanner.plan(totalBytes: 100 * MiB, acceptsRanges: false, connections: 16)
        XCTAssertEqual(p.count, 1); XCTAssertEqual(p[0].length, 100 * MiB)
    }
    func testSmallFileIsSingleChunk() {
        XCTAssertEqual(ChunkPlanner.plan(totalBytes: 1 * MiB, acceptsRanges: true, connections: 4).count, 1)
    }
    func testEmptyFileHasNoChunks() { XCTAssertTrue(ChunkPlanner.plan(totalBytes: 0, acceptsRanges: true, connections: 4).isEmpty) }
    func testLargeFileUsesPreferredChunks() {
        let p = ChunkPlanner.plan(totalBytes: 1000 * MiB, acceptsRanges: true, connections: 4)
        assertValidPlan(p, total: 1000 * MiB)
        XCTAssertEqual(p.count, 125)                       // 8 MiB chunks
        XCTAssertEqual(p[0].length, 8 * MiB)
    }
    func testEveryConnectionGetsWorkOnMediumFiles() {
        let p = ChunkPlanner.plan(totalBytes: 10 * MiB, acceptsRanges: true, connections: 16)
        assertValidPlan(p, total: 10 * MiB)
        XCTAssertGreaterThanOrEqual(p.count, 16)           // 10 MiB / 16 ≈ 640 KiB chunks
        XCTAssertTrue(p.allSatisfy { ($0.length ?? 0) >= 512 * 1024 || $0.index == p.count - 1 })
    }
    func testNoConnectionGetsASingleBigShare() {
        // D5: a 24 MiB file on 4 connections must not become 4 chunks of 6 MiB.
        let p = ChunkPlanner.plan(totalBytes: 24 * MiB, acceptsRanges: true, connections: 4)
        assertValidPlan(p, total: 24 * MiB)
        XCTAssertGreaterThanOrEqual(p.count, 8)
        XCTAssertTrue(p.allSatisfy { ($0.length ?? 0) <= 4 * MiB })
        let single = ChunkPlanner.plan(totalBytes: 24 * MiB, acceptsRanges: true, connections: 1)
        XCTAssertGreaterThanOrEqual(single.count, 3)                    // a single connection still gets resumable pieces
    }
    func testChunkCountIsCapped() {
        let tb: Int64 = 1 << 40
        let p = ChunkPlanner.plan(totalBytes: tb, acceptsRanges: true, connections: 4)
        XCTAssertLessThanOrEqual(p.count, ChunkingConfig.default.maxChunks)
        assertValidPlan(p, total: tb)
    }
    func testInvariantsAcrossManySizesAndConnectionCounts() {
        var sizes: [Int64] = [1, 2, 511, 512 * 1024, 2 * MiB - 1, 2 * MiB, 2 * MiB + 1, 3 * MiB + 17, 8 * MiB, 8 * MiB + 1,
                              100 * MiB + 3, 1 << 30, (1 << 30) + 12345, 50 << 30]
        for k in 0..<40 { sizes.append(Int64(1 + (k * 7_919_113) % 3_000_000_000)) }
        for total in sizes {
            for conns in [0, 1, 2, 3, 4, 7, 8, 16, 64] {
                for ranges in [true, false] {
                    let p = ChunkPlanner.plan(totalBytes: total, acceptsRanges: ranges, connections: conns)
                    assertValidPlan(p, total: total)
                    XCTAssertLessThanOrEqual(p.count, ChunkingConfig.default.maxChunks)
                    if !ranges { XCTAssertEqual(p.count, 1) }
                }
            }
        }
    }
}
