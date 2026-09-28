import Foundation

/// The words. Deliberately not user-configurable: a notification the user wrote themselves
/// tends to lose the one thing that makes it actionable — which window, and how full.
public enum ThresholdAlertCopy {
    public static func title(for alert: ThresholdAlert) -> String {
        guard alert.entries.count == 1, let only = alert.entries.first else {
            return "\(alert.entries.count) limits are running low"
        }
        return only.utilization >= 1
            ? "\(only.title) limit reached"
            : "\(only.title) limit at \(percent(only.utilization))"
    }

    public static func body(for alert: ThresholdAlert) -> String {
        guard alert.entries.count > 1 else {
            return "Toki will keep watching this window until it resets."
        }
        return alert.entries.map { "\($0.title) \(percent($0.utilization))" }.joined(separator: " · ")
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
