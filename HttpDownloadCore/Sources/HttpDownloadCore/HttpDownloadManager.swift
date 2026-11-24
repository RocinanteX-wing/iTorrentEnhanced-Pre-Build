import Foundation
import DownloadSupport

/// Queue, scheduling, retries, pause/resume, recovery and assembly for HTTP downloads.
/// All state lives inside this actor; the network is reached only through `HttpTransport`.
public actor HttpDownloadManager {
    // MARK: dependencies
    private let persistence: DownloadPersistenceManager
    private let transport: HttpTransport
    private let downloadsDirectory: URL
    private var settings: HttpDownloadSettings
    private let statistics: DownloadStatisticsManager
    private let spaceGuard: DiskSpaceGuard
    private let clock: ManagerClock
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let persistInterval: TimeInterval

    // MARK: state
    private var records: [UUID: HttpDownloadRecord] = [:]
    private var order: [UUID] = []
    private var inFlight: [UUID: Set<Int>] = [:]
    private var tokens: [LiveChunkKey: UUID] = [:]
    private var retryWait: [LiveChunkKey: Task<Void, Never>] = [:]
    private var probeToken: [UUID: Int] = [:]
    private var probeAttempts: [UUID: Int] = [:]
    private var restartIfChanged: Set<UUID> = []
    private var assembling: Set<UUID> = []
    private var assemblyAttempts: [UUID: Int] = [:]
    private var eventTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var lastPublish: TimeInterval = -100
    private let continuation: AsyncStream<[HttpDownloadRecord]>.Continuation
    public nonisolated let updates: AsyncStream<[HttpDownloadRecord]>

    public init(persistence: DownloadPersistenceManager, transport: HttpTransport, downloadsDirectory: URL,
                settings: HttpDownloadSettings = .default, statistics: DownloadStatisticsManager = DownloadStatisticsManager(),
                spaceGuard: DiskSpaceGuard = DiskSpaceGuard(), clock: ManagerClock = SystemManagerClock(),
                persistInterval: TimeInterval = 1.0,
                sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                }) {
        self.persistence = persistence; self.transport = transport; self.downloadsDirectory = downloadsDirectory
        self.settings = settings; self.statistics = statistics; self.spaceGuard = spaceGuard
        self.clock = clock; self.sleeper = sleeper; self.persistInterval = persistInterval
        var cont: AsyncStream<[HttpDownloadRecord]>.Continuation!
        self.updates = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    // MARK: lifecycle

    /// Loads the queue, reconciles it with what the OS and the disk still have, and starts processing.
    public func start() async {
        guard eventTask == nil else { return }
        let events = transport.events
        eventTask = Task { [weak self] in
            for await event in events { await self?.handle(event) }
        }
        let loaded = (try? persistence.load()) ?? []
        let live = await transport.liveChunks()
        let persistence = self.persistence
        let report = RecoveryPlanner.reconcile(records: loaded, liveChunks: Set(live.map(\.key)),
                                               partLength: { persistence.partLength(for: $0, chunk: $1) }, autoResume: true)
        for r in report.records {
            records[r.id] = r; order.append(r.id)
            inFlight[r.id] = Set(live.filter { $0.key.id == r.id }.map(\.key.index))
        }
        for l in live where records[l.key.id] != nil { tokens[l.key] = l.token }
        persistence.removeOrphanedParts(keeping: Set(order))
        for (id, action) in report.actions where action == .assemble { beginAssembly(id) }
        persistNow(); publish(force: true); schedule()
    }

    public func updateSettings(_ new: HttpDownloadSettings) { settings = new; schedule() }

    // MARK: public API

    @discardableResult
    public func add(url: URL, filename: String? = nil, connections: Int? = nil, headers: [String: String] = [:]) throws -> UUID {
        guard let key = URLKey.key(for: url) else { throw HttpDownloadError.unsupportedURL }
        if url.scheme?.lowercased() == "http" && !settings.allowInsecureHTTP { throw HttpDownloadError.insecureNotAllowed }
        if let existing = records.values.first(where: { $0.urlKey == key }) { throw HttpDownloadError.duplicate(existing: existing.id) }
        let custom = filename.map { FilenameSanitizer.sanitize($0, fallback: "") }.flatMap { $0.isEmpty ? nil : $0 }
        let guessed = FilenameResolver.resolve(contentDisposition: nil, url: url)
        var r = HttpDownloadRecord(originalURL: url, filename: custom ?? guessed,
                                   connectionCount: connections ?? settings.defaultConnections, requestHeaders: headers,
                                   createdAt: clock.date())
        r.hasCustomFilename = custom != nil
        records[r.id] = r; order.append(r.id)
        persistNow(); publish(force: true); schedule()
        return r.id
    }

    public func pause(_ id: UUID) throws {
        var r = try require(id)
        guard r.status == .queued || r.status == .probing || r.status == .downloading || r.status == .retrying else {
            throw HttpDownloadError.invalidState("cannot pause a download that is \(r.status.rawValue)")
        }
        stopWork(id)
        discardInFlightProgress(&r)
        r.status = .paused
        statistics.pause(id: id)
        records[id] = r
        persistNow(); publish(force: true); schedule()
    }

    public func resume(_ id: UUID) throws {
        var r = try require(id)
        guard r.status == .paused else { throw HttpDownloadError.invalidState("only paused downloads can be resumed") }
        r.status = .queued
        records[id] = r
        persistNow(); publish(force: true); schedule()
    }

    /// For failed / needs-attention downloads: probes again. If the file changed on the server since the
    /// download started, the partial data is discarded and the download starts over.
    public func retry(_ id: UUID) throws {
        var r = try require(id)
        guard r.status == .failed || r.status == .needsAttention else {
            throw HttpDownloadError.invalidState("only failed or attention-needed downloads can be retried")
        }
        r.status = .queued; r.attention = nil; r.lastError = nil
        for i in r.chunks.indices { r.chunks[i].attempts = 0 }            // a manual retry gets a fresh budget
        r.acceptsRanges = r.chunks.isEmpty ? nil : r.acceptsRanges
        records[id] = r
        probeAttempts[id] = 0
        restartIfChanged.insert(id)
        forceReprobe.insert(id)
        persistNow(); publish(force: true); schedule()
    }
    private var forceReprobe: Set<UUID> = []

    public func setConnections(_ id: UUID, to count: Int) throws {
        var r = try require(id)
        r.connectionCount = ConnectionLimits.clamp(count)
        records[id] = r
        persistNow(); publish(force: true); schedule()
    }

    public func remove(_ id: UUID, deleteFiles: Bool) throws {
        let r = try require(id)
        stopWork(id)
        persistence.removeParts(for: id)
        if deleteFiles, let name = r.finalFilename { try? FileManager.default.removeItem(at: downloadsDirectory.appendingPathComponent(name)) }
        records[id] = nil; order.removeAll { $0 == id }
        inFlight[id] = nil; probeAttempts[id] = nil; assemblyAttempts[id] = nil; assembling.remove(id)
        statistics.remove(id: id)
        persistNow(); publish(force: true); schedule()
    }

    public func snapshot() -> [HttpDownloadRecord] { order.compactMap { records[$0] } }
    public func record(_ id: UUID) -> HttpDownloadRecord? { records[id] }
    public func statistics(for id: UUID) -> DownloadStatistics? {
        records[id].map { statistics.snapshot(for: $0, activeConnections: inFlight[id]?.count ?? 0, now: clock.now()) }
    }

    /// Writes the queue to disk now (also used by tests and when the app is about to be suspended).
    public func flush() { persistNow() }

    // MARK: scheduling

    private func schedule() {
        var active = order.filter { id in records[id].map { [.probing, .downloading, .retrying].contains($0.status) } ?? false }.count
        for id in order where records[id]?.status == .queued && active < settings.maxSimultaneousDownloads {
            begin(id); active += 1
        }
        for id in order { fillChunks(id) }
    }

    private func begin(_ id: UUID) {
        guard var r = records[id] else { return }
        if r.startedAt == nil { r.startedAt = clock.date() }
        let canSkipProbe = r.acceptsRanges != nil && !r.chunks.isEmpty && !forceReprobe.contains(id)
        if canSkipProbe {
            r.status = .downloading
            records[id] = r
            statistics.resume(id: id, at: clock.now(), downloadedBytes: r.downloadedBytes)
        } else {
            r.status = .probing
            records[id] = r
            startProbe(id)
        }
        persistNow(); publish(force: true)
    }

    private func fillChunks(_ id: UUID) {
        guard var r = records[id], r.status == .downloading || r.status == .retrying else { return }
        var running = inFlight[id] ?? []
        var changed = false
        for i in r.chunks.indices where r.chunks[i].phase == .pending && running.count < r.connectionCount {
            let key = LiveChunkKey(id: id, index: r.chunks[i].index)
            if retryWait[key] != nil { continue }
            let spec = makeSpec(r, chunk: r.chunks[i])
            try? FileManager.default.createDirectory(at: persistence.partsDirectory(for: id), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: spec.destination)
            r.chunks[i].phase = .inFlight; r.chunks[i].bytesReceived = 0
            running.insert(r.chunks[i].index)
            tokens[key] = spec.token
            transport.start(spec)
            changed = true
        }
        inFlight[id] = running
        if changed { records[id] = r }
        refreshStatus(id)
    }

    private func makeSpec(_ r: HttpDownloadRecord, chunk: ChunkState) -> ChunkRequestSpec {
        var range: ClosedRange<Int64>?
        var ifRange: String?
        if r.acceptsRanges == true, let cr = chunk.range {
            let wholeFile = r.chunks.count == 1 && cr.lowerBound == 0 && r.totalBytes == cr.upperBound + 1
            if !wholeFile { range = cr; ifRange = r.validators.ifRangeValue }
        }
        return ChunkRequestSpec(downloadID: r.id, chunkIndex: chunk.index, url: r.currentURL, range: range, ifRange: ifRange,
                                headers: r.requestHeaders, allowsCellular: settings.allowsCellular,
                                destination: persistence.partURL(for: r.id, chunk: chunk.index))
    }

    private func refreshStatus(_ id: UUID) {
        guard var r = records[id], r.status == .downloading || r.status == .retrying else { return }
        let waiting = retryWait.keys.contains { $0.id == id }
        let desired: UnifiedStatus = ((inFlight[id]?.isEmpty ?? true) && waiting) ? .retrying : .downloading
        if desired != r.status { r.status = desired; records[id] = r; publish(force: true) }
    }

    // MARK: probing

    private func startProbe(_ id: UUID) {
        guard let r = records[id] else { return }
        let token = (probeToken[id] ?? 0) + 1
        probeToken[id] = token
        let url = r.currentURL, headers = r.requestHeaders, cellular = settings.allowsCellular
        let transport = self.transport
        Task { [weak self] in
            let answers = await transport.probe(url: url, headers: headers, allowsCellular: cellular)
            await self?.probeFinished(id, token: token, answers: answers)
        }
    }

    private func probeFinished(_ id: UUID, token: Int, answers: ProbeResponses) async {
        guard probeToken[id] == token, var r = records[id], r.status == .probing else { return }   // paused / removed meanwhile
        let result: ProbeResult
        do {
            result = try ProbeInterpreter.interpret(head: answers.head, rangeProbe: answers.rangeProbe, requestedURL: r.currentURL)
        } catch let failure as ProbeFailure {
            switch failure {
            case .accessDenied(let code):
                fail(id, attention: code == 401 ? .authenticationRequired : .accessDenied, "The server refused access (\(code)).")
            case .notFound(let code):
                fail(id, attention: .accessDenied, "The link is no longer available (\(code)).")
            case .serverError, .noResponse:
                let n = (probeAttempts[id] ?? 0) + 1
                probeAttempts[id] = n
                if settings.retry.shouldRetry(afterFailures: n) {
                    r.retryCount += 1; records[id] = r
                    let delay = settings.retry.delay(afterFailures: n)
                    publish(force: true)
                    Task { [weak self] in
                        await self?.sleeper(delay)
                        await self?.restartProbe(id, token: token)
                    }
                } else {
                    failTerminal(id, "The server could not be reached.")
                }
            case .unexpectedStatus(let code):
                failTerminal(id, "Unexpected server answer (\(code)).")
            }
            return
        } catch { failTerminal(id, "Probe failed."); return }
        applyProbe(id, result)
    }

    private func restartProbe(_ id: UUID, token: Int) {
        guard probeToken[id] == token, records[id]?.status == .probing else { return }
        startProbe(id)
    }

    private func applyProbe(_ id: UUID, _ result: ProbeResult) {
        guard var r = records[id] else { return }
        r.currentURL = result.finalURL
        r.isInsecure = r.originalURL.scheme?.lowercased() == "http" || result.finalURL.scheme?.lowercased() == "http"
        if r.isInsecure && !settings.allowInsecureHTTP { failTerminal(id, "Connections that are not encrypted are disabled."); return }

        let hadData = r.chunks.contains { $0.phase != .pending }
        let changed = hadData && (
            (r.totalBytes != nil && result.totalBytes != r.totalBytes) ||
            r.validators.compare(to: result.validators) == .different ||
            (r.acceptsRanges == true && !result.acceptsRanges))
        var keepChunks = !r.chunks.isEmpty
        if changed {
            if restartIfChanged.contains(id) { persistence.removeParts(for: id); keepChunks = false }
            else { fail(id, attention: .fileChanged, "The file changed on the server."); return }
        }
        restartIfChanged.remove(id); forceReprobe.remove(id); probeAttempts[id] = 0

        r.totalBytes = result.totalBytes
        r.acceptsRanges = result.acceptsRanges
        r.validators = result.validators
        if !r.hasCustomFilename { r.filename = result.suggestedFilename }
        if !keepChunks || r.chunks.isEmpty {
            r.chunks = ChunkPlanner.plan(totalBytes: r.totalBytes, acceptsRanges: result.acceptsRanges,
                                         connections: r.connectionCount, config: settings.chunking)
        }
        if let total = r.totalBytes {
            let needed = total + settings.chunking.maxChunkSize
            if (try? spaceGuard.ensure(requiredBytes: needed, at: downloadsDirectory)) == nil {
                records[id] = r
                fail(id, attention: .insufficientSpace, "Not enough free space for this download.")
                return
            }
        }
        r.status = .downloading
        records[id] = r
        statistics.resume(id: id, at: clock.now(), downloadedBytes: r.downloadedBytes)
        persistNow(); publish(force: true)
        if r.chunks.isEmpty { beginAssembly(id) } else { schedule() }
    }

    // MARK: transport events

    private func handle(_ event: TransportEvent) {
        switch event {
        case .progress(let id, let chunk, let token, let bytes):
            if tokens[LiveChunkKey(id: id, index: chunk)] == token { chunkProgress(id, chunk, bytes) }
        case .finished(let id, let chunk, let token, let response, let size):
            let key = LiveChunkKey(id: id, index: chunk)
            guard tokens[key] == token else { return }                 // late event of a cancelled request
            tokens[key] = nil
            chunkFinished(id, chunk, response, size)
        case .failed(let id, let chunk, let token, let failure):
            let key = LiveChunkKey(id: id, index: chunk)
            guard tokens[key] == token else { return }
            tokens[key] = nil
            chunkFailed(id, chunk, failure)
        }
    }

    private func chunkProgress(_ id: UUID, _ index: Int, _ bytes: Int64) {
        guard var r = records[id], let i = r.chunks.firstIndex(where: { $0.index == index }), r.chunks[i].phase == .inFlight else { return }
        r.chunks[i].bytesReceived = max(r.chunks[i].bytesReceived, bytes)
        records[id] = r
        statistics.update(id: id, downloadedBytes: r.downloadedBytes, at: clock.now())
        publish(force: false)
    }

    private func chunkFinished(_ id: UUID, _ index: Int, _ response: HTTPResponseInfo, _ size: Int64) {
        guard var r = records[id], let i = r.chunks.firstIndex(where: { $0.index == index }), r.chunks[i].phase == .inFlight else { return }
        inFlight[id]?.remove(index)
        let chunk = r.chunks[i]
        var verdict: RangeVerdict
        if r.acceptsRanges == true, let range = chunk.range, !(r.chunks.count == 1 && r.totalBytes == range.upperBound + 1 && range.lowerBound == 0) {
            verdict = RangeResponseValidator.verdict(for: response, expecting:
                RangeExpectation(range: range, knownTotal: r.totalBytes, validators: r.validators))
        } else {
            verdict = RangeResponseValidator.verdictForFullResponse(response, expectedTotal: r.totalBytes, validators: r.validators)
        }
        if verdict == .accepted, let expected = chunk.length, expected != size {
            verdict = .rangeMismatch("received \(size) bytes, expected \(expected)")
        }
        if verdict == .accepted, chunk.isOpenEnded, size == 0 { verdict = .rangeMismatch("empty body") }

        switch verdict {
        case .accepted:
            r.chunks[i].phase = .done; r.chunks[i].bytesReceived = size
            if chunk.isOpenEnded { r.chunks[i].end = size - 1; r.totalBytes = size }
            records[id] = r
            statistics.update(id: id, downloadedBytes: r.downloadedBytes, at: clock.now())
            if r.allChunksDone { persistNow(); publish(force: true); beginAssembly(id) }
            else { schedulePersist(); publish(force: false); schedule() }
        case .rangeIgnored:
            discardPart(id, index)
            fallBackToSingleStream(id)
        case .fileChanged, .unsatisfiable:
            discardPart(id, index)
            fail(id, attention: .fileChanged, "The file changed on the server.")
        case .accessDenied(let code):
            discardPart(id, index)
            fail(id, attention: code == 401 ? .authenticationRequired : .accessDenied, "The server refused access (\(code)).")
        case .rangeMismatch(let why):
            discardPart(id, index)
            retryChunk(id, index, reason: why, exhausted: .rangeUnreliable)
        case .retryable(let code):
            discardPart(id, index)
            retryChunk(id, index, reason: "server answered \(code)", exhausted: nil)
        case .failed(let code):
            discardPart(id, index)
            failTerminal(id, "Unexpected server answer (\(code)).")
        }
    }

    private func chunkFailed(_ id: UUID, _ index: Int, _ failure: TransportFailure) {
        guard let r = records[id], let i = r.chunks.firstIndex(where: { $0.index == index }), r.chunks[i].phase == .inFlight else { return }
        inFlight[id]?.remove(index)
        discardPart(id, index)
        switch failure.kind {
        case .cancelled:
            var r2 = r; r2.chunks[i].phase = .pending; r2.chunks[i].bytesReceived = 0; records[id] = r2
        case .insecureRedirect:
            failTerminal(id, "Redirect to an unencrypted address was blocked.")
        case .connectivity, .other:
            retryChunk(id, index, reason: URLRedaction.redactingURLs(in: failure.message), exhausted: nil)
        }
    }

    /// Back off, then try the chunk again; when the budget is spent the item stops (needs attention or failed).
    private func retryChunk(_ id: UUID, _ index: Int, reason: String, exhausted: AttentionReason?) {
        guard var r = records[id], let i = r.chunks.firstIndex(where: { $0.index == index }) else { return }
        r.chunks[i].attempts += 1
        r.chunks[i].phase = .pending; r.chunks[i].bytesReceived = 0
        let attempts = r.chunks[i].attempts
        guard settings.retry.shouldRetry(afterFailures: attempts) else {
            records[id] = r
            if let reason = exhausted { fail(id, attention: reason, "Giving up after \(attempts) attempts: \(reason)") }
            else { failTerminal(id, "Giving up after \(attempts) attempts: \(URLRedaction.redactingURLs(in: reason))") }
            return
        }
        r.retryCount += 1
        r.lastError = URLRedaction.redactingURLs(in: reason)
        records[id] = r
        let key = LiveChunkKey(id: id, index: index)
        let delay = settings.retry.delay(afterFailures: attempts)
        retryWait[key]?.cancel()
        retryWait[key] = Task { [weak self] in
            await self?.sleeper(delay)
            if Task.isCancelled { return }
            await self?.retryDelayElapsed(key)
        }
        refreshStatus(id); persistNow(); publish(force: true)
    }

    private func retryDelayElapsed(_ key: LiveChunkKey) {
        retryWait[key] = nil
        schedule()
    }

    /// The server turned out to ignore `Range`: restart this download as one plain request.
    private func fallBackToSingleStream(_ id: UUID) {
        guard var r = records[id] else { return }
        stopWork(id, keepStatus: true)
        persistence.removeParts(for: id)
        r.acceptsRanges = false
        r.chunks = ChunkPlanner.plan(totalBytes: r.totalBytes, acceptsRanges: false, connections: 1, config: settings.chunking)
        r.retryCount += 1
        r.lastError = "Server ignores range requests; continuing with a single connection."
        r.status = .downloading
        records[id] = r
        inFlight[id] = []
        persistNow(); publish(force: true); schedule()
    }

    // MARK: assembly

    private func beginAssembly(_ id: UUID) {
        guard var r = records[id], !assembling.contains(id) else { return }
        assembling.insert(id)
        r.status = .assembling
        records[id] = r
        let parts = r.chunks.sorted { $0.index < $1.index }.map {
            AssemblyPart(url: persistence.partURL(for: id, chunk: $0.index), expectedLength: $0.length)
        }
        let total = r.totalBytes
        let name = r.filename
        let finalDir = downloadsDirectory
        let work = downloadsDirectory.appendingPathComponent(".incoming", isDirectory: true)
        let needed = spaceGuard.requiredWithHeadroom(total ?? 0)
        let available = (try? spaceGuard.provider.availableBytes(at: downloadsDirectory)) ?? 0
        let policy: PartPolicy = available >= needed ? .keepUntilFinished : .consumeAsWritten
        persistNow(); publish(force: true)
        Task.detached { [weak self] in
            let outcome: Result<URL, Error>
            do {
                let url = try FileAssembler().assemble(parts: parts, expectedTotal: total, finalDirectory: finalDir,
                                                       desiredFilename: name, workDirectory: work, policy: policy)
                outcome = .success(url)
            } catch { outcome = .failure(error) }
            await self?.assemblyFinished(id, outcome)
        }
    }

    private func assemblyFinished(_ id: UUID, _ outcome: Result<URL, Error>) {
        assembling.remove(id)
        guard var r = records[id] else { return }
        switch outcome {
        case .success(let url):
            r.status = .completed; r.finalFilename = url.lastPathComponent; r.completedAt = clock.date()
            r.lastError = nil; r.attention = nil
            if let t = r.totalBytes { for i in r.chunks.indices { r.chunks[i].bytesReceived = r.chunks[i].length ?? t } }
            records[id] = r
            persistence.removeParts(for: id)
            statistics.pause(id: id)
        case .failure(let error):
            let attempts = (assemblyAttempts[id] ?? 0) + 1
            assemblyAttempts[id] = attempts
            switch error as? AssemblyError {
            case .partMissing(let i)?, .partSizeMismatch(let i, _, _)?:
                if let k = r.chunks.firstIndex(where: { $0.index == i }), attempts <= 2 {
                    r.chunks[k].phase = .pending; r.status = .downloading; records[id] = r
                    persistNow(); publish(force: true); schedule(); return
                }
                records[id] = r; failTerminal(id, "A downloaded part is damaged."); return
            case .totalMismatch?, .failedAfterConsuming?:
                if attempts <= 1 {
                    persistence.removeParts(for: id)
                    for k in r.chunks.indices { r.chunks[k].phase = .pending; r.chunks[k].bytesReceived = 0 }
                    r.status = .downloading; records[id] = r
                    persistNow(); publish(force: true); schedule(); return
                }
                records[id] = r; failTerminal(id, "The file could not be assembled."); return
            default:
                records[id] = r
                let enoughSpace = (try? spaceGuard.ensure(requiredBytes: 0, at: downloadsDirectory)) != nil
                if enoughSpace { failTerminal(id, "The file could not be saved: \(URLRedaction.redactingURLs(in: error.localizedDescription))") }
                else { fail(id, attention: .insufficientSpace, "Not enough free space to save the file.") }
                return
            }
        }
        persistNow(); publish(force: true); schedule()
    }

    // MARK: helpers

    private func require(_ id: UUID) throws -> HttpDownloadRecord {
        guard let r = records[id] else { throw HttpDownloadError.unknownDownload(id) }
        return r
    }

    /// Cancels every transport request and retry timer of a download.
    private func stopWork(_ id: UUID, keepStatus: Bool = false) {
        transport.cancel(downloadID: id, chunk: nil)
        for key in retryWait.keys where key.id == id { retryWait[key]?.cancel(); retryWait[key] = nil }
        inFlight[id] = []
        for key in tokens.keys where key.id == id { tokens[key] = nil }
        probeToken[id] = (probeToken[id] ?? 0) + 1
    }

    private func discardInFlightProgress(_ r: inout HttpDownloadRecord) {
        for i in r.chunks.indices where r.chunks[i].phase == .inFlight {
            r.chunks[i].phase = .pending; r.chunks[i].bytesReceived = 0
            try? FileManager.default.removeItem(at: persistence.partURL(for: r.id, chunk: r.chunks[i].index))
        }
    }

    private func discardPart(_ id: UUID, _ index: Int) {
        try? FileManager.default.removeItem(at: persistence.partURL(for: id, chunk: index))
    }

    private func fail(_ id: UUID, attention: AttentionReason, _ message: String) {
        guard var r = records[id] else { return }
        stopWork(id)
        discardInFlightProgress(&r)
        r.status = .needsAttention; r.attention = attention; r.lastError = message
        records[id] = r
        statistics.pause(id: id)
        persistNow(); publish(force: true); schedule()
    }

    private func failTerminal(_ id: UUID, _ message: String) {
        guard var r = records[id] else { return }
        stopWork(id)
        discardInFlightProgress(&r)
        r.status = .failed; r.attention = nil; r.lastError = message
        records[id] = r
        statistics.pause(id: id)
        persistNow(); publish(force: true); schedule()
    }

    private func persistNow() {
        persistTask?.cancel(); persistTask = nil
        try? persistence.save(order.compactMap { records[$0] })
    }

    private func schedulePersist() {
        guard persistTask == nil else { return }
        let interval = persistInterval
        persistTask = Task { [weak self] in
            await self?.sleeper(interval)
            if Task.isCancelled { return }
            await self?.persistTaskFired()
        }
    }
    private func persistTaskFired() { persistTask = nil; persistNow() }

    private func publish(force: Bool) {
        let t = clock.now()
        if !force && t - lastPublish < 0.25 { return }
        lastPublish = t
        continuation.yield(order.compactMap { records[$0] })
    }
}
