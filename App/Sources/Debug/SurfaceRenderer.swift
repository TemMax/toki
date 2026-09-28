import AppKit
import SwiftUI

/// SurfaceRenderer — offscreen, full-height PNG capture of a SwiftUI view.
///
/// ## Why this exists instead of `ImageRenderer`
/// `ImageRenderer` never draws content inside a `ScrollView`: it captures the scroll
/// view's *visible frame*, so a surface whose body is a `ScrollView` comes out as an empty
/// background. This renderer goes through real AppKit layout instead — an
/// `NSHostingController` in an offscreen `NSWindow`, captured with
/// `cacheDisplay(in:to:)` — which does draw scrolled content, and can resolve the view's
/// full intrinsic height rather than the window-sized one.
///
/// The offscreen window is not decoration: a hosting view with no window lays out
/// unreliably (SwiftUI needs a window to resolve appearance, safe areas and scroll
/// geometry), and it is never ordered front, so nothing appears on screen.
///
/// ## Glass caveat — READ THIS BEFORE SNAPSHOTTING A GLASS SURFACE
/// `cacheDisplay` cannot capture backdrop blur. `NSVisualEffectView` (which backs
/// `.regularMaterial`, `.ultraThinMaterial` and Liquid Glass) samples what is *behind the
/// window* — desktop pixels that are not part of the view hierarchy and therefore not part
/// of what `cacheDisplay` draws. Materials come out as their flat fallback tint, and
/// `.blendMode(.plusLighter)` rims do not composite either. That is not a bug this renderer
/// can fix; it is what offscreen capture means.
///
/// `SnapshotConfig.flatSurfaces` in `GlassSurface.swift` exists for exactly this: setting
/// it to `true` makes `glassPanel()` / `panelCard()` draw opaque `Palette.bg` / `Palette.card`
/// fills and a plain hairline rim instead of materials and additive blends. **Callers should
/// set `SnapshotConfig.flatSurfaces = true` before rendering any app surface** — otherwise
/// the PNG shows an undefined, half-tinted approximation of the real glass rather than the
/// deliberate flat stand-in. Set it once, before building the views (it is read during body
/// evaluation, not at capture time).
///
/// ## Known limitation of the unclip fallback
/// When a `ScrollView` is height-pinned from inside the view tree (a `.frame(height:)` on or
/// around it), SwiftUI will not grow it no matter how tall the host gets, so the renderer
/// unclips it directly at the AppKit level (see `expandPinnedScrollViews`). Content that the
/// view itself *vertically centers* alongside such a pinned scroll view is drawn by SwiftUI,
/// not by a repositionable `NSView`, and can stay at its pre-expansion position. Surfaces in
/// this app do not have that shape — their scroll views are the flexible content of a
/// `maxHeight: .infinity` container, which resolves to full height with no unclipping at all.
enum SurfaceRenderError: Error, CustomStringConvertible {

    /// The view has no resolvable natural height at `width` — it measured as zero, or as
    /// infinite because it is unboundedly flexible in the vertical axis (a bare `Color`, say).
    /// Pass an explicit `height` for such views.
    case zeroContentHeight(width: CGFloat, measured: CGFloat)

    /// `NSBitmapImageRep` refused the requested pixel dimensions.
    case couldNotBuildBitmap(pixelSize: CGSize)

    /// The bitmap could not be encoded as PNG.
    case couldNotEncodePNG(URL)

    var description: String {
        switch self {
        case let .zeroContentHeight(width, measured):
            return "content height did not resolve at width \(width) (measured \(measured)); pass an explicit height"
        case let .couldNotBuildBitmap(size):
            return "could not build a \(Int(size.width))x\(Int(size.height))px bitmap"
        case let .couldNotEncodePNG(url):
            return "could not encode PNG for \(url.lastPathComponent)"
        }
    }
}

@MainActor
enum SurfaceRenderer {

    /// Anything above this is a runaway measurement, not a real surface — we refuse rather
    /// than allocate a multi-gigabyte bitmap.
    private static let heightCeiling: CGFloat = 30_000

    /// Height the host is given for the measuring pass. Arbitrary: the measurement asks for
    /// an unbounded proposal, this is only what the view is attached at first.
    private static let measurementHeight: CGFloat = 600

    /// Renders `view` to a PNG at `url`. `width` is fixed; height is the view's natural
    /// content height unless `height` is given. `scale` is the backing-store scale factor.
    /// Returns the pixel size actually written.
    @discardableResult
    static func writePNG<V: View>(
        _ view: V,
        to url: URL,
        width: CGFloat,
        height: CGFloat? = nil,
        scale: CGFloat = 2,
        colorScheme: ColorScheme
    ) throws -> CGSize {
        let scale = max(scale, 0.01)
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)

        // Sections raise their `isVisible` flag from `onAppear`, which an offscreen host never
        // fires — without this every staggered surface captures at opacity 0, i.e. blank.
        // Restored on the way out (including on a throw) so a render can't leave the live
        // windows with their entrance animations disabled.
        let previousStaticEntrance = SnapshotConfig.staticEntrance
        SnapshotConfig.staticEntrance = true
        defer { SnapshotConfig.staticEntrance = previousStaticEntrance }

        let controller = NSHostingController(rootView: AnyView(EmptyView()))
        // Borderless and never ordered front — it exists only so SwiftUI has a window to
        // lay out against. `isReleasedWhenClosed` off: we hand it to ARC, we never close it.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: measurementHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentViewController = controller
        let host = controller.view
        host.appearance = appearance

        func themed(_ body: some View) -> AnyView {
            AnyView(body.environment(\.colorScheme, colorScheme))
        }

        func layOut(at canvasHeight: CGFloat) {
            window.setContentSize(NSSize(width: width, height: canvasHeight))
            host.frame = NSRect(x: 0, y: 0, width: width, height: canvasHeight)
            host.layoutSubtreeIfNeeded()
        }

        // 1. Resolve the height.
        //
        // `.fixedSize(vertical:)` is what makes this work for scrolling surfaces: it proposes
        // `nil` height to the content, and a `ScrollView` answers a nil proposal with its
        // *content's* ideal height rather than the +infinity it reports for an unbounded
        // proposal. Measured empirically — `fittingSize` is not usable here, it returns the
        // view's minimum (one line for wrapping text), and a raw `sizeThatFits` returns
        // infinity for anything vertically greedy.
        var canvasHeight: CGFloat
        if let height {
            canvasHeight = height
        } else {
            controller.rootView = themed(view.fixedSize(horizontal: false, vertical: true))
            layOut(at: measurementHeight)
            let measured = controller.sizeThatFits(
                in: CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            guard measured.isFinite, measured > 0.5, measured <= heightCeiling else {
                throw SurfaceRenderError.zeroContentHeight(width: width, measured: measured)
            }
            canvasHeight = measured
        }

        // 2. Lay out for real at the resolved height.
        //
        // Top-anchored: step 3 may grow the host past what the view asked for, and without
        // this a fixed-height subtree would be re-centred in the taller host, sliding its
        // chrome down into the middle of the image.
        controller.rootView = themed(view.frame(maxHeight: .infinity, alignment: .top))
        layOut(at: canvasHeight)

        // 3. An explicit `height` is an instruction, so only a natural-height render unclips.
        if height == nil {
            canvasHeight = expandPinnedScrollViews(
                host: host, width: width, canvasHeight: canvasHeight, layOut: layOut
            )
        }

        // 4. Capture.
        host.displayIfNeeded()
        return try capture(host, size: CGSize(width: width, height: canvasHeight), scale: scale, to: url)
    }

    // MARK: - Unclipping height-pinned scroll views

    /// Grows the host until every `NSScrollView` fits its document view, forcing open any that
    /// SwiftUI refuses to grow because a `.frame(height:)` pins them.
    ///
    /// Growing the host alone is enough for the ordinary case (an unpinned `ScrollView` simply
    /// lays out taller and the deficit disappears). A pinned one keeps its 400pt frame in a
    /// 1200pt host, so we then resize the scroll view, its clip view and each ancestor up to
    /// the host by hand. Their heights and top edges are recorded *before* the grow and
    /// restored after, because SwiftUI's relayout re-centres them, and `autoresizesSubviews`
    /// is switched off first so resizing an ancestor does not also grow the scroll view a
    /// second time.
    private static func expandPinnedScrollViews(
        host: NSView,
        width: CGFloat,
        canvasHeight: CGFloat,
        layOut: (CGFloat) -> Void
    ) -> CGFloat {
        var canvasHeight = canvasHeight

        // Bounded: each pass either resolves one scroll view or stops. Nested scroll views
        // need one pass each, and there is no sane surface with more than a handful.
        for _ in 0..<4 {
            guard let chain = overflowingScrollViewChain(in: host),
                  let scrollView = chain.first as? NSScrollView,
                  let document = scrollView.documentView
            else { break }

            let deficit = document.frame.height - scrollView.frame.height
            let tops = chain.map { host.convert($0.frame, from: $0.superview).minY }
            let heights = chain.map(\.frame.height)

            canvasHeight += deficit
            layOut(canvasHeight)

            // SwiftUI may rebuild the hierarchy on relayout, so re-find rather than reuse.
            guard let grown = overflowingScrollViewChain(in: host),
                  grown.count == chain.count,
                  let pinned = grown.first as? NSScrollView,
                  let pinnedDocument = pinned.documentView
            else { continue }   // the grow resolved it; loop again to catch a nested one

            for node in grown { node.autoresizesSubviews = false }
            // Outermost first: each node's superview must already be at its final size for
            // the coordinate conversion below to land the node where we want it.
            for index in stride(from: grown.count - 1, through: 0, by: -1) {
                let node = grown[index]
                let wanted = NSRect(
                    x: host.convert(node.frame, from: node.superview).minX,
                    y: tops[index],
                    width: node.frame.width,
                    height: heights[index] + deficit
                )
                node.frame = host.convert(wanted, to: node.superview)
            }

            // The scroller is an artifact of the truncation we just undid.
            pinned.hasVerticalScroller = false
            pinned.contentView.setFrameSize(
                NSSize(width: pinned.contentView.frame.width, height: pinnedDocument.frame.height)
            )
            pinned.contentView.scroll(to: .zero)
            pinned.reflectScrolledClipView(pinned.contentView)
        }

        return canvasHeight
    }

    /// The first (outermost, depth-first) scroll view whose content is taller than its frame,
    /// returned as the chain of views from it up to — but excluding — `host`.
    private static func overflowingScrollViewChain(in host: NSView) -> [NSView]? {
        func firstOverflowing(_ view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView,
               let document = scrollView.documentView,
               document.frame.height - scrollView.frame.height > 0.5 {
                return scrollView
            }
            for subview in view.subviews {
                if let hit = firstOverflowing(subview) { return hit }
            }
            return nil
        }

        guard let scrollView = firstOverflowing(host) else { return nil }
        var chain: [NSView] = []
        var node: NSView = scrollView
        while node !== host {
            chain.append(node)
            guard let parent = node.superview else { return nil }
            node = parent
        }
        return chain
    }

    // MARK: - Bitmap capture

    /// The bitmap is built by hand rather than via `bitmapImageRepForCachingDisplay(in:)`
    /// because that one adopts the window's backing scale (whatever the machine's display
    /// happens to be); snapshots must be the same size on every machine, so `scale` decides.
    private static func capture(
        _ host: NSView,
        size: CGSize,
        scale: CGFloat,
        to url: URL
    ) throws -> CGSize {
        let pixelsWide = Int((size.width * scale).rounded())
        let pixelsHigh = Int((size.height * scale).rounded())
        let pixelSize = CGSize(width: pixelsWide, height: pixelsHigh)

        guard pixelsWide > 0, pixelsHigh > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              )
        else { throw SurfaceRenderError.couldNotBuildBitmap(pixelSize: pixelSize) }

        // `size` in points against `pixelsWide/High` is what makes cacheDisplay draw at `scale`.
        bitmap.size = NSSize(width: size.width, height: size.height)

        // The backing store starts undefined; clear it so any region the view leaves
        // untouched is honestly transparent rather than uninitialised memory.
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: bitmap.size).fill(using: .copy)
            NSGraphicsContext.restoreGraphicsState()
        }

        host.cacheDisplay(in: host.bounds, to: bitmap)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SurfaceRenderError.couldNotEncodePNG(url)
        }
        try png.write(to: url)
        return pixelSize
    }
}
