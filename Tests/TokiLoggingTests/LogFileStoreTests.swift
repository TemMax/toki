import Foundation
import Testing
@testable import TokiLogging

@Suite("LogFileStore")
struct LogFileStoreTests {

    /// A fixed calendar so the tests do not depend on the machine's time zone.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 24))!
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today)!
    }

    private func file(_ offset: Int, index: Int = 0, bytes: Int = 1_000) -> LogFileInfo {
        let date = day(offset)
        return LogFileInfo(name: LogFileStore.fileName(date: date, index: index, calendar: calendar),
                           date: date, index: index, byteSize: bytes)
    }

    // MARK: - Naming

    @Test("the day's first file has no index, later rotations carry one")
    func naming() {
        #expect(LogFileStore.fileName(date: today, index: 0, calendar: calendar)
                == "toki-2026-08-24.log")
        #expect(LogFileStore.fileName(date: today, index: 1, calendar: calendar)
                == "toki-2026-08-24.1.log")
        #expect(LogFileStore.fileName(date: today, index: 12, calendar: calendar)
                == "toki-2026-08-24.12.log")
    }

    @Test("both spellings round-trip to the same date, with index 0 and 1")
    func parseRoundTrip() throws {
        let plain = try #require(LogFileStore.parse(fileName: "toki-2026-08-24.log", calendar: calendar))
        let rotated = try #require(LogFileStore.parse(fileName: "toki-2026-08-24.1.log", calendar: calendar))

        #expect(plain.date == today)
        #expect(plain.index == 0)
        #expect(rotated.date == today)
        #expect(rotated.index == 1)
        #expect(plain.date == rotated.date)
    }

    @Test("anything this module did not write parses as nil, so it is never a deletion candidate")
    func parseRejectsForeignNames() {
        for name in ["toki.log", "toki-2026-8-4.log", "other-2026-08-24.log",
                     "toki-2026-08-24.log.gz", "toki-2026-08-24..log", "logging-salt", ""] {
            #expect(LogFileStore.parse(fileName: name, calendar: calendar) == nil,
                    "\(name) should not parse")
        }
    }

    // MARK: - Retention by age

    @Test("with a three-day retention, exactly the -3 and -4 files are pruned")
    func ageRetention() {
        let files = [file(0), file(-1), file(-2), file(-3), file(-4)]
        let doomed = LogFileStore.filesToPrune(files, today: today,
                                               policy: .init(), calendar: calendar)

        #expect(doomed.map(\.name).sorted() == [file(-4), file(-3)].map(\.name).sorted())
        #expect(doomed.count == 2)
        // today, -1 and -2 are the three days a bug report filed today can be about.
        for kept in [file(0), file(-1), file(-2)] {
            #expect(!doomed.contains { $0.name == kept.name })
        }
    }

    @Test("nothing is pruned when the directory is inside both budgets")
    func nothingToDo() {
        let files = [file(0), file(-1), file(-2)]
        #expect(LogFileStore.filesToPrune(files, today: today,
                                          policy: .init(), calendar: calendar).isEmpty)
    }

    // MARK: - Retention by size

    @Test("an oversized directory sheds its oldest files first and never today's active one")
    func sizeRetention() {
        var policy = LogFileStore.Policy()
        policy.maxDirectoryBytes = 2_500

        // All within the age window, so only the size rule can act.
        let files = [file(-2, bytes: 1_000), file(-1, bytes: 1_000), file(0, bytes: 1_000)]
        let doomed = LogFileStore.filesToPrune(files, today: today,
                                               policy: policy, calendar: calendar)

        #expect(doomed.map(\.name) == [file(-2).name],
                "one file is enough to get under budget, and it must be the oldest")
        #expect(!doomed.contains { $0.name == file(0).name })
    }

    @Test("today's active file survives even when it alone blows the budget")
    func activeFileIsNeverPruned() {
        var policy = LogFileStore.Policy()
        policy.maxDirectoryBytes = 100

        let files = [file(-1, bytes: 5_000), file(0, index: 0, bytes: 5_000),
                     file(0, index: 1, bytes: 9_000)]
        let doomed = LogFileStore.filesToPrune(files, today: today,
                                               policy: policy, calendar: calendar)

        // Everything but today's highest-index file — the one being appended to right now.
        #expect(doomed.map(\.name).sorted()
                == [file(-1).name, file(0, index: 0).name].sorted())
        #expect(!doomed.contains { $0.name == file(0, index: 1).name })
    }

    @Test("the size pass only counts what the age pass left behind")
    func agePassRunsFirst() {
        var policy = LogFileStore.Policy()
        policy.maxDirectoryBytes = 4_000

        // The two old files are 10 KB together, but they are already doomed by age; what
        // remains is 3 KB, which is inside the budget, so nothing else should go.
        let files = [file(-4, bytes: 5_000), file(-3, bytes: 5_000),
                     file(-2, bytes: 1_000), file(-1, bytes: 1_000), file(0, bytes: 1_000)]
        let doomed = LogFileStore.filesToPrune(files, today: today,
                                               policy: policy, calendar: calendar)

        #expect(doomed.map(\.name).sorted() == [file(-4).name, file(-3).name].sorted())
    }
}
