/// WindowEffects — make a host NSWindow transparent so Liquid Glass refracts the desktop.
///
/// Liquid Glass (`.glassEffect`) refracts whatever is composited *behind* it. For a
/// floating panel (the menu-bar popover) or a window to refract the **desktop**, the
/// underlying NSWindow must be non-opaque with a clear background — otherwise the glass
/// just samples the window's own opaque backing. SwiftUI doesn't expose this, so we reach
/// the NSWindow through a tiny representable and set it once the view joins the hierarchy.
import SwiftUI
import AppKit

/// NSView that makes its host window transparent. Mutating the window in
/// `viewDidMoveToWindow` (and `updateNSView`) keeps everything on the main actor
/// with no escaping closures — Swift 6 strict-concurrency safe.
final class TransparentWindowNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTransparency()
    }

    func applyTransparency() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}

/// Drop into any view via `.background(TransparentWindow())` to make the enclosing
/// window non-opaque, so a Liquid Glass surface drawn on top refracts the desktop.
struct TransparentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> TransparentWindowNSView {
        TransparentWindowNSView()
    }

    func updateNSView(_ nsView: TransparentWindowNSView, context: Context) {
        // SwiftUI can re-establish the window backing; re-assert each update.
        nsView.applyTransparency()
    }
}

/// Configures the menu-bar popover window for a single, clean Liquid Glass corner.
///
/// The popover panel is transparent (so the glass refracts the desktop) AND its
/// contentView is clipped to one continuous `Radius.panel` squircle. Without the
/// clip, the system's own popover-corner radius and our larger glass radius show
/// as *two* concentric corners ("doubled" corners); clipping the content to the
/// same radius collapses them into one.
final class GlassPanelWindowNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configure()
    }

    func configure() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = Radius.panel
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
        }
    }
}

/// Drop into the popover root via `.background(GlassPanelWindow())`.
struct GlassPanelWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> GlassPanelWindowNSView {
        GlassPanelWindowNSView()
    }

    func updateNSView(_ nsView: GlassPanelWindowNSView, context: Context) {
        nsView.configure()
    }
}
