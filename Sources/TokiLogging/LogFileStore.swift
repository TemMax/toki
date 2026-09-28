/// Rotation and retention, expressed as pure functions over a file *listing*.
///
/// Naming, parsing and "what should go" never touch `FileManager`, so every retention rule
/// in this file is assertable in `swift test` against synthesised `LogFileInfo` values —
/// no temporary directory, no clock, no flakiness. `FileLogSink` is the thin shell that
/// turns a real directory into that listing and deletes what comes back.
import Foundation

public struct LogFileInfo: Sendable, Equatable {
    public let name: String
    /// The day the file belongs to (start of that day in the naming calendar).
    public let date: Date
    /// 0 = the day's first file, 1… = size rotations within the same day.
    public let index: Int
    public let byteSize: Int

    public init(name: String, date: Date, index: Int, byteSize: Int) {
        self.name = name
        self.date = date
        self.index = index
        self.byteSize = byteSize
    }
}

public enum LogFileStore {

    public struct Policy: Sendable {
        /// How many days are kept, counting today: 3 → today, -1, -2.
        public var retentionDays: Int = 3
        public var maxFileBytes: Int = 10 * 1024 * 1024
        public var maxDirectoryBytes: Int = 30 * 1024 * 1024
        public init() {}
    }

    /// `toki-2026-08-24.log`, `toki-2026-08-24.1.log`, …
    public static func fileName(date: Date, index: Int, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let stamp = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return index == 0 ? "toki-\(stamp).log" : "toki-\(stamp).\(index).log"
    }

    private nonisolated(unsafe) static let namePattern =
        try! NSRegularExpression(pattern: #"^toki-(\d{4})-(\d{2})-(\d{2})(?:\.(\d+))?\.log$"#)

    /// Inverse of `fileName`. Returns `nil` for anything this module did not write, so a
    /// stray file in the log directory is never a deletion candidate.
    public static func parse(fileName: String, calendar: Calendar) -> (date: Date, index: Int)? {
        let range = NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
        guard let m = namePattern.firstMatch(in: fileName, range: range) else { return nil }

        func group(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: fileName) else { return nil }
            return Int(fileName[r])
        }
        guard let year = group(1), let month = group(2), let day = group(3) else { return nil }
        let index = group(4) ?? 0

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        return (calendar.startOfDay(for: date), index)
    }

    /// Pure. Two rules, in order:
    ///
    /// 1. **Age.** Anything older than `retentionDays` days (counting today) goes. A log this
    ///    old cannot help with a bug report filed today, and keeping it is pure exposure.
    /// 2. **Size.** While what remains still exceeds `maxDirectoryBytes`, drop the oldest
    ///    remaining file — never today's active file, because that is the one being written
    ///    to right now and deleting it would lose the very session being diagnosed.
    public static func filesToPrune(_ files: [LogFileInfo], today: Date,
                                    policy: Policy, calendar: Calendar) -> [LogFileInfo] {
        let todayStart = calendar.startOfDay(for: today)
        let oldestKeptDay = calendar.date(byAdding: .day,
                                          value: -(max(policy.retentionDays, 1) - 1),
                                          to: todayStart) ?? todayStart

        // Oldest first, and within a day the lowest rotation index first.
        let ordered = files.sorted {
            $0.date == $1.date ? $0.index < $1.index : $0.date < $1.date
        }

        var doomed: [LogFileInfo] = []
        var kept: [LogFileInfo] = []
        for file in ordered {
            if file.date < oldestKeptDay { doomed.append(file) } else { kept.append(file) }
        }

        // The file currently being appended to: today's highest rotation index.
        let active = kept.filter { $0.date == todayStart }.max { $0.index < $1.index }

        var total = kept.reduce(0) { $0 + $1.byteSize }
        var i = 0
        while total > policy.maxDirectoryBytes, i < kept.count {
            let candidate = kept[i]
            i += 1
            if let active, candidate.name == active.name { continue }
            doomed.append(candidate)
            total -= candidate.byteSize
        }

        return doomed
    }
}
