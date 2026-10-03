/// ClaudeScan — one pass over (part of) a Claude Code transcript.
import Foundation
import TokiModels

/// Collects a pass's records, last-wins per request id (D2), and measures each request from
/// the last user line (prompt or tool result) before its first block to its last block.
///
/// `lastInputMs` is the start anchor carried between passes (see
/// `FileIndexState.lastInputMs`). It only advances on complete lines: an unterminated last
/// line is re-read next pass, so its timestamp must not outlive this one.
///
/// `openRequestId` / `openRequestStartMs` carry the last request's start the same way: a
/// tool result written between two blocks of one request moves `lastInputMs`, so a block
/// read in the next pass must find its request's start already fixed, as it is in a
/// whole-file read.
struct ClaudeScan {
    private(set) var lastInputMs: Int64?
    /// The request of the last complete line that was a block, if any.
    private(set) var openRequestId: String?
    /// That request's start (nil when it had no input line before it).
    private(set) var openRequestStartMs: Int64?
    private var records: [TranscriptRecord] = []
    private var slot: [String: Int] = [:]
    /// Each request's start, fixed at its first block in this pass (or carried in).
    private var starts: [String: Int64?] = [:]

    init(lastInputMs: Int64?, openRequestId: String? = nil, openRequestStartMs: Int64? = nil) {
        self.lastInputMs = lastInputMs
        self.openRequestId = openRequestId
        self.openRequestStartMs = openRequestStartMs
        if let openRequestId { starts[openRequestId] = .some(openRequestStartMs) }
    }

    mutating func consume(_ line: UnsafeRawBufferPointer, isComplete: Bool) {
        let tokens = ClaudeLineTokens(line)
        if tokens.mayBeRecord, let record = TranscriptParser.decodeRecord(bytes: line) {
            let start: Int64?
            if let known = starts[record.requestId] {
                start = known
            } else {
                start = lastInputMs
                starts[record.requestId] = lastInputMs
            }
            if isComplete {
                openRequestId = record.requestId
                openRequestStartMs = start
            }
            let end = TranscriptStore.milliseconds(record.timestamp)
            let duration = start.flatMap { end >= $0 ? Int(end - $0) : nil }
            let measured = record.withGenerationMs(duration)
            if let index = slot[record.requestId] {
                records[index] = measured
            } else {
                slot[record.requestId] = records.count
                records.append(measured)
            }
        } else if isComplete, let ms = tokens.inputTimestampMs(bytes: line) {
            lastInputMs = ms
        }
    }

    func finish() -> [TranscriptRecord] { records }
}
