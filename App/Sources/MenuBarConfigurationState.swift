import Foundation
import Observation
import TokiCore
import TokiMenuBar

/// The single owner of the menu-bar's current configuration.
///
/// Loads it once from `MenuBarConfigurationStore` at construction and persists every change
/// straight back to it, so it is the one `@Observable` source every consumer reads (and, once
/// a Settings screen exists, writes) through. `MenuBarViewModel` forwards to this
/// single owner the same way it already forwards to
/// `LiveLimits` rather than caching its own copy.
@Observable
@MainActor
final class MenuBarConfigurationState {
    private let store: MenuBarConfigurationStore

    var configuration: MenuBarConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            store.save(configuration)
        }
    }

    init(store: MenuBarConfigurationStore) {
        self.store = store
        self.configuration = store.load()
    }
}

/// The one reactive owner of the usage-window visibility preference. Settings mutates it;
/// the dashboard and menu-bar popover observe the same value through `MenuBarViewModel`.
@Observable
@MainActor
final class UsageDisplayConfigurationState {
    private let store: UsageDisplayConfigurationStore

    var configuration: UsageDisplayConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            store.save(configuration)
        }
    }

    init(store: UsageDisplayConfigurationStore) {
        self.store = store
        self.configuration = store.load()
    }
}
