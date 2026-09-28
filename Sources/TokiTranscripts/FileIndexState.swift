/// FileIndexState — the per-file read position the index resumes from.
import Foundation
import TokiModels

/// Persistent per-file index state used to resume incremental reads.
public struct FileIndexState: Sendable, Equatable {
    /// Absolute path to the JSONL file.
    public var path: String
    /// Byte offset just past the last complete line we have consumed.
    public var lastByteOffset: UInt64
    /// File size observed at the last read (for truncation detection).
    public var lastKnownSize: UInt64
    /// Inode number (rotation detection).
    public var inode: UInt64
    /// Device id (rotation detection).
    public var device: UInt64
    /// Last FSEvent id associated with this file (best-effort).
    public var lastEventId: UInt64

    public init(
        path: String,
        lastByteOffset: UInt64 = 0,
        lastKnownSize: UInt64 = 0,
        inode: UInt64 = 0,
        device: UInt64 = 0,
        lastEventId: UInt64 = 0
    ) {
        self.path = path
        self.lastByteOffset = lastByteOffset
        self.lastKnownSize = lastKnownSize
        self.inode = inode
        self.device = device
        self.lastEventId = lastEventId
    }
}

/// One transcript file's contribution to an index batch: the records read since its last
/// position, the position to resume from next time, and — for a Codex rollout — the parse
/// context in effect at that position.
public struct IndexedFile: Sendable {
    public var records: [TranscriptRecord]
    public var state: FileIndexState
    public var codexContext: CodexParseContext?

    public init(records: [TranscriptRecord], state: FileIndexState, codexContext: CodexParseContext? = nil) {
        self.records = records
        self.state = state
        self.codexContext = codexContext
    }
}

enum JSONLReaderError: Error {
    case statFailed(Int32)
}
