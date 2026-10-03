import Foundation
import Observation

/// The dashboard's top-level section (the tabs in the main window's floating toolbar).
///
/// Settings is a tab here — the app no longer has a standalone Settings window — so every
/// entry point (popover footer, ⌘,, the app-menu Settings item, a tapped new-account
/// notification) routes into the main window by setting `DashboardNavigation.section`.
enum DashboardSection: Hashable {
    case usage
    case speed
    case machine
    case accounts
    case settings

    /// Maps the string carried in `.tokiOpenDashboard`'s `userInfo["section"]` to a
    /// section, so a cross-process bridge (e.g. a tapped notification handled in
    /// `AppDelegate`, which has no container) can name the tab to open.
    ///
    /// `"instances"` and `"environment"` are kept as aliases for `.machine` — those two
    /// tabs merged into one, but the identifiers are still used to name the underlying
    /// surfaces in the debug control channel and the snapshot harness, and any caller
    /// still holding one of the old strings (e.g. a queued notification) must keep landing
    /// on the tab that now shows that content instead of failing to navigate at all.
    ///
    /// `"statistics"` is kept as an alias for `.usage` the same way: the Statistics tab
    /// retired into the Usage tab (its content — the activity heatmap, streak tiles,
    /// punchcard — now lives there on every range, see `DashboardContent`), so any caller
    /// still holding that identifier lands on the tab that now shows that content.
    init?(identifier: String) {
        switch identifier {
        case "usage", "statistics":       self = .usage
        case "speed":                     self = .speed
        case "machine", "instances", "environment": self = .machine
        case "accounts":                  self = .accounts
        case "settings":                  self = .settings
        default:                          return nil
        }
    }
}

/// The single source of truth for which dashboard tab is shown. Created once by
/// `ServiceContainer`; every entry point sets `section`, and `DashboardView` observes it.
@MainActor
@Observable
final class DashboardNavigation {
    var section: DashboardSection = .usage
}
