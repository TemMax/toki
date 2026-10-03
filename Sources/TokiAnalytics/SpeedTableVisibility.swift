/// SpeedTableVisibility — which models the speed table leaves out, kept across launches.
import Foundation

/// Reads and writes the hidden model ids. It holds no copy of its own: `SpeedViewModel` owns the
/// set and calls this only to load it once and to save a change.
///
/// Ids are kept as they were saved, whether or not the current report still has that model: a
/// model that is absent today stays hidden when it comes back.
public struct SpeedTableVisibilityStore {
    public static let key = "speed.hiddenModels"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The hidden model ids; empty when nothing was ever saved.
    public func load() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    /// Stored sorted, so the same set always writes the same value.
    public func save(_ hidden: Set<String>) {
        defaults.set(hidden.sorted(), forKey: Self.key)
    }
}
