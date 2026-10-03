/// IndexCatchUp — the pieces of an incremental index pass: which files need reading and from
/// where, how far a pass has got, and the read-only side of the index.
import Foundation
import TokiLogging
import TokiModels

private let log = TokiLog.logger("transcripts")

/// Which transcript format a file holds.
enum SourceKind: Sendable {
    case claude
    case codex
}

/// How far a catch-up pass has got, in files. Reported after every committed batch.
public struct IndexProgress: Sendable, Equatable {
    public let filesDone: Int
    public let filesTotal: Int

    public init(filesDone: Int, filesTotal: Int) {
        self.filesDone = filesDone
        self.filesTotal = filesTotal
    }

    public var isFinished: Bool { filesDone >= filesTotal }

    /// 0…1; a pass with nothing to read is complete.
    public var fractionCompleted: Double {
        filesTotal == 0 ? 1 : min(1, Double(filesDone) / Double(filesTotal))
    }
}

/// One file that needs reading, and the offset to start from.
struct ScanJob: Sendable {
    let path: String
    let kind: SourceKind
    let startOffset: UInt64
    /// The Codex parse context in effect at `startOffset` (fresh when starting at 0).
    let context: CodexParseContext
    let size: UInt64
    let inode: UInt64
    let device: UInt64
    let modified: TimeInterval
    let lastEventId: UInt64
    /// The Claude start anchor in effect at `startOffset` (nil when starting at 0).
    let lastInputMs: Int64?
    /// The Claude request open at `startOffset` and its start (nil when starting at 0).
    let openRequestId: String?
    let openRequestStartMs: Int64?

    /// Decides whether `path` needs reading at all, and from where, against its persisted
    /// state. `nil` means skip: unchanged since the last pass, or not a regular file.
    ///
    /// - A file seen for the first time, replaced (new inode/device) or truncated (shorter
    ///   than the last read position) is read from the start.
    /// - A file whose size is what the last pass recorded is unchanged — transcripts are
    ///   append-only, so this `stat` is the whole cost of an untouched file.
    /// - Otherwise it grew, and is read from the last position.
    /// - A Codex rollout resumes mid-file only with the parse context saved at that position;
    ///   without one it is read from the start.
    static func make(
        path: String,
        kind: SourceKind,
        prior: FileIndexState?,
        context: CodexParseContext? = nil
    ) -> ScanJob? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size: UInt64 = st.st_size >= 0 ? UInt64(st.st_size) : 0
        let inode = UInt64(st.st_ino)
        let device = UInt64(bitPattern: Int64(st.st_dev))

        var start: UInt64 = 0
        if let prior {
            let replaced = prior.inode != inode || prior.device != device
            if !replaced, size >= prior.lastByteOffset {
                if size == prior.lastKnownSize { return nil }
                start = prior.lastByteOffset
            }
        }
        var resumeContext = CodexParseContext()
        if kind == .codex, start > 0 {
            if let context { resumeContext = context } else { start = 0 }
        }
        let modified = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9
        return ScanJob(
            path: path,
            kind: kind,
            startOffset: start,
            context: resumeContext,
            size: size,
            inode: inode,
            device: device,
            modified: modified,
            lastEventId: prior?.lastEventId ?? 0,
            lastInputMs: start > 0 ? prior?.lastInputMs : nil,
            openRequestId: start > 0 ? prior?.openRequestId : nil,
            openRequestStartMs: start > 0 ? prior?.openRequestStartMs : nil
        )
    }

    /// The position to persist once the scan that started at `startOffset` ended at `result`.
    func state(
        after result: LineScanner.Result,
        lastInputMs: Int64? = nil,
        openRequestId: String? = nil,
        openRequestStartMs: Int64? = nil
    ) -> FileIndexState {
        FileIndexState(
            path: path,
            lastByteOffset: result.consumedOffset,
            // A file that grew while it was read has consumed past the size stat'ed first.
            lastKnownSize: max(size, result.consumedOffset),
            inode: inode,
            device: device,
            lastEventId: lastEventId,
            lastInputMs: lastInputMs,
            openRequestId: openRequestId,
            openRequestStartMs: openRequestStartMs
        )
    }
}

/// The index's read side: a SQLite connection of its own, opened lazily.
///
/// Separate from the indexer's write connection so a query never waits for a catch-up pass
/// (WAL lets a reader see every committed batch while writing continues). A lock serialises
/// the connection, which is not thread-safe to share.
///
/// A failed open is not remembered: the next read tries again, so one unlucky moment at
/// launch cannot leave the dashboard empty for the rest of the session.
final class IndexReader: @unchecked Sendable {
    private let databaseURL: URL
    private let lock = NSLock()
    private var store: TranscriptStore?

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func read<T>(_ body: (TranscriptStore) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if let store { return try body(store) }
        let opened: TranscriptStore
        do {
            opened = try TranscriptStore(databaseURL: databaseURL)
        } catch {
            log.error("failed to open transcript reader \(error: error)")
            throw TokiError.decoding("TranscriptIndexer: failed to open SQLite store: \(error)")
        }
        store = opened
        return try body(opened)
    }
}
