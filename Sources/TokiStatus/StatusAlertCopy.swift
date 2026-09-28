import Foundation

/// The words. Mirrors `ThresholdAlertCopy`: fixed, not user-configurable, and written so the
/// title alone answers "do I need to stop what I am doing".
///
/// The body is Anthropic's own incident title whenever there is one — their sentence is more
/// specific than anything Toki could synthesise, and it is what the user will see again on
/// the status page.
public enum StatusAlertCopy {
    public static func title(
        for event: StatusAlertPolicy.Event,
        providerName: String = "Claude"
    ) -> String {
        switch event {
        case let .incidentBegan(severity, _):
            // `.operational` cannot reach here (a healthy status is never a "began"), and if
            // it ever did, the softer wording is the honest one.
            return severity == .outage
                ? "\(providerName): service outage"
                : "\(providerName): degraded performance"
        case .incidentResolved:
            return "\(providerName) is back to normal"
        }
    }

    public static func body(
        for event: StatusAlertPolicy.Event,
        providerName: String = "Claude",
        organizationName: String = "Anthropic"
    ) -> String {
        switch event {
        case let .incidentBegan(_, title):
            return title ?? "\(organizationName) reports a problem affecting \(providerName)."
        case .incidentResolved:
            return "The incident affecting \(providerName) is resolved."
        }
    }
}
