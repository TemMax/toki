import AppKit
import SwiftUI
import TokiMenuBar

/// Rasterizes `MenuBarStripView` into the `NSImage` `MenuBarLabel` hands to `MenuBarExtra`.
///
/// ## Why an image, not the view directly
/// `MenuBarExtra`'s label `ViewBuilder` type-checks arbitrary SwiftUI, but only `Text` and
/// `Image` (and combinations of the two) actually draw onto the real `NSStatusBarButton`.
/// Verified empirically before writing this file, by temporarily swapping the label for each
/// candidate and dumping the running app's own `NSStatusBarWindow` view tree (in-process, no
/// Screen Recording permission needed — `screencapture` itself has no TCC grant in this
/// sandbox):
///   - A label built from a bare `Rectangle`-only `HStack` left the button pinned at the tiny
///     system-default width (16pt) no matter how large the shapes were asked to be (tried
///     3pt and 50pt bars) — i.e. it did not draw.
///   - The app's existing `Image(systemName:) + Text` label sizes the button to its real
///     content (67pt for "cpu" + "0%").
///   - A hand-built `NSImage` (60×11pt, `isTemplate = true`) handed through `Image(nsImage:)`
///     also sized the button to its real content (76pt = 60pt image + the same ~16pt padding
///     the other two cases show), and looked correct.
/// So `Image(nsImage:)` is the one path that reliably draws non-text/glyph content — the
/// strip is laid out as an ordinary SwiftUI view (`MenuBarStripView`) and rasterized here
/// first, then handed to the label as an `Image`.
///
/// ## Template rendering
/// The returned image ships as a template unconditionally (`isTemplate = true`), so macOS
/// retints it for light/dark menu bars and the highlighted state — the same convention every
/// other monochrome status-bar icon in the app follows. Colour is not customisable (see
/// `MenuBarConfiguration`'s doc comment for why the flag that used to gate this was removed
/// rather than kept as a second, non-template code path), so there is no case where a
/// non-template image is ever wanted here.
enum MenuBarStripRenderer {
    @MainActor
    static func image(
        for indicators: [ResolvedIndicator],
        style: MenuBarStyle,
        colorScheme: ColorScheme,
        scale: CGFloat
    ) -> NSImage {
        let view = MenuBarStripView(indicators: indicators, style: style)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = max(scale, 1)
        let image = renderer.nsImage ?? emptyImage()
        image.isTemplate = true
        return image
    }

    /// `ImageRenderer.nsImage` is only `nil` if the content measures to zero size, which
    /// `MenuBarStripView` never does (`MenuBarConfiguration` never yields an empty indicator
    /// list — see its own doc comment). Kept as a defined fallback rather than force-unwrapping
    /// so a future caller that CAN pass an empty list fails soft (an empty status item, not a
    /// crash) instead of trapping.
    private static func emptyImage() -> NSImage {
        NSImage(size: NSSize(width: 1, height: 1))
    }
}
