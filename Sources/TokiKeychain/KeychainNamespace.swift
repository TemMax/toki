/// The one place that names Toki's own Keychain items.
///
/// The prefix tracks the bundle identifier, `dev.komar.toki`. Renaming it was deferred for
/// a long time because the bundle id is part of the app's designated requirement, which is
/// what a Keychain item's ACL is written against: under a new id macOS no longer recognises
/// the app as the owner of the items it created, and every one of them would prompt for the
/// login password. (Sparkle was never the obstacle — `SUUpdateValidator` accepts an update
/// on a valid EdDSA signature alone.) With the old releases withdrawn there is nothing left
/// under the previous name, so no items have to be carried across.
import Foundation

public enum KeychainNamespace {
    public static let prefix = "dev.komar.toki."
}
