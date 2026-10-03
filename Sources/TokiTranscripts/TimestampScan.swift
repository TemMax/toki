/// TimestampScan — reads a line's first `"timestamp":"…"` value straight from its bytes.
import Foundation

extension TranscriptParser {
    /// The first `"timestamp":"…"` value in a line, as epoch ms, with no decode and no
    /// copy. In a Codex rollout line the timestamp is the first key; in a Claude Code
    /// line every earlier key holds only strings (their quotes are escaped), so the first
    /// hit is the top-level one.
    static func leadingTimestampMs(bytes: UnsafeRawBufferPointer) -> Int64? {
        guard let base = bytes.baseAddress else { return nil }
        let key: StaticString = "\"timestamp\":\""
        guard let hit = memmem(base, bytes.count, key.utf8Start, key.utf8CodeUnitCount) else { return nil }
        return timestampMs(bytes: bytes, valueAt: (UnsafeRawPointer(hit) - base) + key.utf8CodeUnitCount)
    }

    /// The timestamp whose value starts at `start` — just past a `"timestamp":"` key — as
    /// epoch ms; nil when the value is unterminated or not a date.
    static func timestampMs(bytes: UnsafeRawBufferPointer, valueAt start: Int) -> Int64? {
        guard let base = bytes.baseAddress, start < bytes.count,
              let close = memchr(base + start, Int32(UInt8(ascii: "\"")), bytes.count - start)
        else { return nil }
        let value = UnsafeRawBufferPointer(start: base + start, count: UnsafeRawPointer(close) - (base + start))
        guard let date = ISO8601Timestamp.parse(value) else { return nil }
        return TranscriptStore.milliseconds(date)
    }
}

extension UnsafeRawBufferPointer {
    /// Calls `body` with the offset of every `"` in these bytes, in order, until it returns
    /// `false`.
    ///
    /// Every token a line prefilter looks for contains a quote, so one walk over the quotes
    /// (`memchr`, vectorised) can test them all where a `memmem` per token would read the
    /// whole line once per token — and `memmem` reads it a byte at a time.
    @inline(__always)
    func forEachQuote(_ body: (Int) -> Bool) {
        guard let base = baseAddress else { return }
        var cursor = 0
        while cursor < count, let hit = memchr(base + cursor, Int32(UInt8(ascii: "\"")), count - cursor) {
            let at = UnsafeRawPointer(hit) - base
            guard body(at) else { return }
            cursor = at + 1
        }
    }

    /// Whether `needle` occurs at `offset`.
    @inline(__always)
    func hasBytes(_ needle: StaticString, at offset: Int) -> Bool {
        let length = needle.utf8CodeUnitCount
        guard let base = baseAddress, offset >= 0, offset <= count - length else { return false }
        return memcmp(base + offset, needle.utf8Start, length) == 0
    }
}
