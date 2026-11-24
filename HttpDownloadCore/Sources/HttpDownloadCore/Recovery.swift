import Foundation
import DownloadSupport

public struct LiveChunkKey: Hashable, Sendable {
    public var id: UUID
    public var index: Int
    public init(id: UUID, index: Int) { self.id = id; self.index = index }
}

public enum RecoveryAction: Equatable, Sendable {
    case none
    /// Chunks remain: schedule the item again.
    case resume
    /// Every chunk is on disk: assemble the file.
    case assemble
}

public struct RecoveryReport: Sendable, Equatable {
    public var records: [HttpDownloadRecord]
    public var actions: [UUID: RecoveryAction]
}

/// Pure reconciliation of what was persisted with what actually exists after a relaunch:
/// live OS transfer tasks and chunk files on disk. No I/O happens here, so it can be tested exhaustively.
public enum RecoveryPlanner {
    /// - Parameters:
    ///   - liveChunks: chunks that still have a running OS task (reattached background session).
    ///   - partLength: length of `chunk-N.part` on disk, or nil if the file does not exist.
    ///   - autoResume: items that were active when the app stopped are queued again instead of paused.
    public static func reconcile(records: [HttpDownloadRecord], liveChunks: Set<LiveChunkKey>,
                                 partLength: (UUID, Int) -> Int64?, autoResume: Bool) -> RecoveryReport {
        var out: [HttpDownloadRecord] = []
        var actions: [UUID: RecoveryAction] = [:]

        for var r in records {
            switch r.status {
            case .completed, .failed, .needsAttention, .paused:
                // Not running: only repair chunk bookkeeping so a later resume starts from the truth.
                r.chunks = normalise(r, live: [], partLength: partLength)
                out.append(r); actions[r.id] = RecoveryAction.none
                continue
            case .queued:
                r.chunks = normalise(r, live: [], partLength: partLength)
                out.append(r); actions[r.id] = r.chunks.isEmpty ? RecoveryAction.none : RecoveryAction.resume
                continue
            case .probing, .downloading, .retrying, .assembling:
                break
            }

            let live = Set(liveChunks.filter { $0.id == r.id }.map(\.index))
            r.chunks = normalise(r, live: live, partLength: partLength)

            if r.allChunksDone {
                r.status = .assembling
                actions[r.id] = .assemble
            } else if r.chunks.isEmpty {
                r.status = autoResume ? .queued : .paused      // never probed: start again from the beginning
                actions[r.id] = autoResume ? .resume : RecoveryAction.none
            } else if !live.isEmpty {
                r.status = .downloading                        // the OS kept going while we were away
                actions[r.id] = .resume
            } else if autoResume {
                r.status = .queued
                actions[r.id] = .resume
            } else {
                r.status = .paused
                actions[r.id] = RecoveryAction.none
            }
            out.append(r)
        }
        return RecoveryReport(records: out, actions: actions)
    }

    /// Chunk rules:
    /// - `done` but the file is missing or the wrong size  -> `pending`
    /// - `inFlight` with a live task                        -> stays `inFlight`
    /// - `inFlight`, no live task, file complete            -> `done` (it finished while the app was away)
    /// - `inFlight`, no live task, otherwise                -> `pending`
    private static func normalise(_ r: HttpDownloadRecord, live: Set<Int>, partLength: (UUID, Int) -> Int64?) -> [ChunkState] {
        r.chunks.map { chunk in
            var c = chunk
            let onDisk = partLength(r.id, c.index)
            let complete: Bool = {
                guard let len = onDisk else { return false }
                if let expected = c.length { return len == expected }
                return len > 0 && c.phase == .done
            }()
            switch c.phase {
            case .done:
                if !complete { c.phase = .pending; c.bytesReceived = 0 }
            case .inFlight:
                if live.contains(c.index) { break }
                if complete, c.length != nil { c.phase = .done; c.bytesReceived = c.length ?? 0 }
                else { c.phase = .pending; c.bytesReceived = 0 }
            case .pending:
                c.bytesReceived = 0
            }
            return c
        }
    }
}
