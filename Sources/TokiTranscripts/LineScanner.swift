/// LineScanner — zero-copy line scanning over a JSONL file region.
import Foundation

/// Scans newline-delimited lines of a file with `pread` + `memchr`, handing each line to the
/// caller as raw bytes that are only valid for the duration of the callback.
///
/// This is the indexer's hot loop, and the reason it exists instead of `streamLines`: that
/// reader copies every chunk into a fresh `Data`, then every line into a `String`, then the
/// parser turns the `String` back into `Data` — three copies of gigabytes of transcript text,
/// ~80% of which (user prompts, tool output) is thrown away unparsed. Here a line costs
/// nothing until a parser decides it wants it, and a parser's cheap byte prefilter
/// (`containsBytes`) rejects most lines without allocating at all.
///
/// Not memory-mapped on purpose: a transcript truncated while mapped would fault the process
/// (`SIGBUS`); `pread` just returns fewer bytes.
enum LineScanner {
    /// Where a scan stopped.
    struct Result: Equatable {
        /// Offset just past the last newline consumed — where the next incremental scan
        /// resumes. A trailing line without a newline is never counted as consumed, so a
        /// line still being written is re-read once it is complete.
        var consumedOffset: UInt64
        /// Number of newline-terminated lines seen (including skipped oversized ones).
        var completeLines: Int
    }

    /// A line longer than this is skipped (resynchronising at the next newline) instead of
    /// growing the buffer without bound — a corrupt newline-less blob must not OOM the app.
    static let defaultMaxLineBytes = 64 * 1024 * 1024

    /// Scans `path` from `offset` to its current end.
    ///
    /// - Parameters:
    ///   - onLine: called for every line with its bytes (a trailing `\r` trimmed) and whether
    ///     it was newline-terminated. The final unterminated line, if any, is delivered with
    ///     `false` so a caller can still read a complete record the writer did not finish
    ///     with a newline; it does not advance `consumedOffset`.
    static func scan(
        path: String,
        from offset: UInt64,
        maxLineBytes: Int = defaultMaxLineBytes,
        onLine: (UnsafeRawBufferPointer, _ isComplete: Bool) -> Void
    ) throws -> Result {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw JSONLReaderError.statFailed(errno) }
        defer { close(fd) }

        var capacity = min(1 << 20, max(maxLineBytes, 1))
        var buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }

        /// File offset of `buffer[0]`.
        var bufferOffset = offset
        var filled = 0
        /// Bytes at the front of the buffer already searched for a newline without a hit.
        var searched = 0
        /// Discarding an oversized line until its terminating newline.
        var skipping = false
        var result = Result(consumedOffset: offset, completeLines: 0)

        func deliver(_ start: Int, _ end: Int, complete: Bool) {
            var end = end
            if end > start, buffer.load(fromByteOffset: end - 1, as: UInt8.self) == 0x0D { end -= 1 }
            onLine(UnsafeRawBufferPointer(start: buffer + start, count: end - start), complete)
        }

        while true {
            if filled == capacity {
                if capacity < maxLineBytes {
                    // One line outgrew the buffer: grow it (the common case is a long assistant
                    // message a few MB in size), keeping what was already read.
                    let grown = min(capacity * 2, maxLineBytes)
                    let bigger = UnsafeMutableRawPointer.allocate(byteCount: grown, alignment: 16)
                    bigger.copyMemory(from: buffer, byteCount: filled)
                    buffer.deallocate()
                    buffer = bigger
                    capacity = grown
                } else {
                    // Past the cap: drop what we have and skip to the next newline.
                    skipping = true
                    bufferOffset += UInt64(filled)
                    filled = 0
                    searched = 0
                }
            }

            let read = pread(fd, buffer + filled, capacity - filled, off_t(bufferOffset + UInt64(filled)))
            if read < 0 {
                if errno == EINTR { continue }
                throw JSONLReaderError.statFailed(errno)
            }
            if read == 0 { break }
            filled += read

            var lineStart = 0
            var cursor = searched
            while cursor < filled, let hit = memchr(buffer + cursor, 0x0A, filled - cursor) {
                let newline = buffer.distance(to: hit)
                if skipping {
                    skipping = false
                } else {
                    deliver(lineStart, newline, complete: true)
                }
                result.completeLines += 1
                lineStart = newline + 1
                cursor = lineStart
                result.consumedOffset = bufferOffset + UInt64(lineStart)
            }

            // Slide the unterminated remainder to the front for the next read.
            if lineStart > 0 {
                let remainder = filled - lineStart
                if remainder > 0 { memmove(buffer, buffer + lineStart, remainder) }
                bufferOffset += UInt64(lineStart)
                filled = remainder
            }
            searched = filled
        }

        if filled > 0, !skipping {
            deliver(0, filled, complete: false)
        }
        return result
    }
}

extension UnsafeRawBufferPointer {
    /// Whether `needle` occurs anywhere in these bytes (`memmem`, vectorised by libc).
    func containsBytes(_ needle: StaticString) -> Bool {
        guard let base = baseAddress, count >= needle.utf8CodeUnitCount else { return false }
        return memmem(base, count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }
}
