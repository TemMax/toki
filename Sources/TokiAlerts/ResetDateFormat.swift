import Foundation

/// Absolute dates from the API, formatted in the user's current zone at presentation time.
public enum ResetDateFormat {
    public static func string(
        date: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjmmz")
        return formatter.string(from: date)
    }
}
