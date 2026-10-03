import Foundation
import Testing
@testable import TokiTranscripts

@Suite("TimestampScan")
struct TimestampScanTests {
    private func ms(_ s: String) -> Int64? {
        var s = s
        return s.withUTF8 { TranscriptParser.leadingTimestampMs(bytes: UnsafeRawBufferPointer($0)) }
    }

    @Test("Reads the first timestamp value, fractional or not")
    func reads() {
        #expect(ms(#"{"timestamp":"2026-10-02T10:00:00.000Z","type":"x"}"#) == 1_790_935_200_000)
        #expect(ms(#"{"type":"user","message":{"content":"a \"timestamp\":\"x\""},"timestamp":"2026-10-02T10:00:00.250Z"}"#) == 1_790_935_200_250)
        #expect(ms(#"{"timestamp":"2026-10-02T10:00:01Z"}"#) == 1_790_935_201_000)
    }

    @Test("No key, an unterminated value or a malformed date is nil")
    func rejects() {
        #expect(ms(#"{"type":"user"}"#) == nil)
        #expect(ms(#"{"timestamp":"2026-10-02T10:00"#) == nil)
        #expect(ms(#"{"timestamp":"yesterday"}"#) == nil)
        #expect(ms("") == nil)
    }
}
