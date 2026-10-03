// Debug-only, like the rest of the control channel: see DebugControlChannel.swift.
#if DEBUG

import AppKit
import QuartzCore

/// Drives a scroll view programmatically, one display-link tick at a time, and measures how
/// late each frame was — the `scroll` control-channel command.
///
/// The content offset is set from the display link's own timestamp, so the scroll moves at a
/// constant speed (a triangle wave: top → bottom → top → …) no matter how late a frame is; a
/// late frame shows as a gap between two presented frames, exactly as a real scroll would hitch.
///
/// ## What is measured
/// A tick arrives for a vsync (`timestamp`) and prepares the frame for the next one
/// (`targetTimestamp`). On the tick the probe moves the scroll position; AppKit and SwiftUI
/// then lay out and commit in the same turn of the main run loop, and the loop goes back to
/// waiting. That moment is when the frame's **update** is finished:
///
///   - update time: vsync → the main run loop resting again (or the next tick starting, when
///     the loop never rested in between — an "unrested" frame). It is the app's whole
///     main-thread cost of a frame;
///   - a frame whose update finishes by its target vsync is presented there; one that is
///     still running `commitSlack` past that vsync slips to the first vsync after it
///     finishes. Two frames landing on the same vsync count once — the earlier one was
///     never seen;
///   - frame time: the spacing of the vsyncs at which consecutive frames are presented;
///   - hitch: a frame presented one refresh interval or more after it was expected (frame
///     time > 1.5 × the refresh interval — presentation times are whole vsyncs, the 0.5 only
///     absorbs timestamp jitter); its hitch time is `frame time − refresh interval`;
///   - hitch-time ratio: total hitch time (ms) per second of scrolling. Apple's bar: under
///     5 ms/s is good, over 10 ms/s is a problem.
///
/// ## What is not measured
/// Only the app's own half of a frame. After the commit, WindowServer still has to render and
/// the GPU to composite; a frame that is late *there* (blur, large layers, another app's load)
/// is invisible from inside the process. Instruments' Animation Hitches template sees both halves.
@MainActor
final class ScrollProbe: NSObject {
    private let scrollView: NSScrollView
    private let seconds: Double
    private let pointsPerSecond: Double
    private let top: CGFloat
    private let bottom: CGFloat
    private var link: CADisplayLink?
    private var restObserver: CFRunLoopObserver?
    private var continuation: CheckedContinuation<[String: Any], Never>?

    private struct Frame {
        let vsync: CFTimeInterval
        let target: CFTimeInterval
        let finished: CFTimeInterval
    }

    /// How far past its target vsync an update may run and still make that frame. WindowServer
    /// does not latch a frame's transaction at the vsync itself: with Instruments' Animation
    /// Hitches recording the same scroll, frames whose app update lasted up to 9.18 ms of an
    /// 8.33 ms interval were still presented on time. The slack also keeps a tick that merely
    /// started a few hundred microseconds late (the loop never rested, so the previous frame
    /// is closed by that tick) from reading as a missed frame.
    private static let commitSlack: CFTimeInterval = 0.001

    private var firstTimestamp: CFTimeInterval?
    /// The frame whose update is still running: its vsync and its target.
    private var inFlight: (vsync: CFTimeInterval, target: CFTimeInterval)?
    private var frames: [Frame] = []
    /// Frames closed by the next tick because the main run loop never rested after them.
    private var unrestedFrames = 0

    private init(scrollView: NSScrollView, seconds: Double, pointsPerSecond: Double) {
        self.scrollView = scrollView
        self.seconds = seconds
        self.pointsPerSecond = pointsPerSecond
        // Ask the clip view for its own limits rather than doing inset arithmetic: it knows
        // the content insets the dashboard's floating toolbar adds.
        let clip = scrollView.contentView
        let far: CGFloat = 1_000_000
        let low = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: -far), size: clip.bounds.size)).minY
        let high = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: far), size: clip.bounds.size)).minY
        let flipped = scrollView.documentView?.isFlipped ?? true
        self.top = flipped ? low : high
        self.bottom = flipped ? high : low
    }

    /// Scrolls `scrollView` for `seconds` and returns the measurement as JSON-ready fields.
    static func run(_ scrollView: NSScrollView, seconds: Double, pointsPerSecond: Double) async -> [String: Any] {
        let probe = ScrollProbe(scrollView: scrollView, seconds: seconds, pointsPerSecond: pointsPerSecond)
        return await probe.measure()
    }

    private func measure() async -> [String: Any] {
        let window = scrollView.window
        let visibleAtStart = window?.occlusionState.contains(.visible) ?? false
        let maxFPS = window?.screen?.maximumFramesPerSecond ?? 60
        set(top)

        let fields: [String: Any] = await withCheckedContinuation { continuation in
            self.continuation = continuation
            // Last in line among the run loop's observers, so on systems that commit from a
            // `beforeWaiting` observer the commit is over by the time this one runs.
            let observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
            ) { [weak self] _, _ in
                let now = CACurrentMediaTime()
                MainActor.assumeIsolated { self?.finishFrame(at: now) }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            restObserver = observer

            let link = scrollView.displayLink(target: self, selector: #selector(tick(_:)))
            // A real trackpad scroll runs ProMotion at its top rate; ask for the same.
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(maxFPS) / 2, maximum: Float(maxFPS), preferred: Float(maxFPS))
            link.add(to: .main, forMode: .common)
            self.link = link
            // An occluded window can have its display link paused outright; never hang the
            // channel waiting for ticks that are not coming.
            let limit = seconds + 5
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(limit))
                self?.finish(timedOut: true)
            }
        }

        set(top)
        var result = fields
        let visibleAtEnd = window?.occlusionState.contains(.visible) ?? false
        result["refreshRateHz"] = maxFPS
        result["windowVisible"] = visibleAtStart && visibleAtEnd
        var warnings: [String] = []
        if !(visibleAtStart && visibleAtEnd) {
            warnings.append("window occlusion state is not visible; macOS may throttle its display link")
        }
        if let measuredHz = result["displayLinkHz"] as? Double, measuredHz < Double(maxFPS) * 0.75 {
            warnings.append("display link ran at \(Int(measuredHz.rounded())) Hz, below the display's \(maxFPS) Hz; it was throttled")
        }
        // A handful of unrested frames are real overruns. Most of them unrested means something
        // else kept the main queue busy the whole time (launch indexing does), and then no
        // frame's update can be seen to finish: each reads as a whole interval and flaps
        // around the deadline.
        if let unrested = result["unrestedFrames"] as? Int, let total = result["frames"] as? Int,
           total > 0, unrested * 5 > total {
            warnings.append("the main run loop never rested after \(unrested) of \(total) frames, so their update times are upper bounds and the hitch count is inflated; let the app settle and rerun")
        }
        if result["timedOut"] as? Bool == true {
            warnings.append("the display link stopped delivering frames before the run finished")
        }
        if !warnings.isEmpty { result["warning"] = warnings.joined(separator: "; ") }
        return result
    }

    @objc private func tick(_ link: CADisplayLink) {
        // The previous frame's update was still running when this tick could finally start.
        if inFlight != nil { unrestedFrames += 1 }
        finishFrame(at: CACurrentMediaTime())

        let now = link.timestamp
        if firstTimestamp == nil { firstTimestamp = now }
        let elapsed = now - (firstTimestamp ?? now)
        if elapsed >= seconds { finish(timedOut: false); return }

        inFlight = (vsync: now, target: link.targetTimestamp)
        // Position for the frame being prepared: where a constant-speed scroll is at its target time.
        set(offset(at: link.targetTimestamp - (firstTimestamp ?? now)))
    }

    /// Closes the frame in flight, if there is one: the main run loop is about to rest (the
    /// update is committed), or the next tick has arrived without it ever resting.
    private func finishFrame(at time: CFTimeInterval) {
        guard let frame = inFlight else { return }
        inFlight = nil
        frames.append(Frame(vsync: frame.vsync, target: frame.target, finished: time))
    }

    /// Triangle wave between `top` and `bottom` at `pointsPerSecond`.
    private func offset(at time: CFTimeInterval) -> CGFloat {
        let travel = abs(bottom - top)
        guard travel > 0 else { return top }
        let distance = CGFloat(max(time, 0) * pointsPerSecond).truncatingRemainder(dividingBy: travel * 2)
        let along = distance <= travel ? distance : travel * 2 - distance
        return top + (bottom > top ? along : -along)
    }

    private func set(_ y: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func finish(timedOut: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        link?.invalidate()
        link = nil
        if let restObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), restObserver, .commonModes) }
        restObserver = nil
        // A frame still in flight has no finish time; it is not counted.
        inFlight = nil

        // When each frame reached the screen at the earliest: its target vsync, or the first
        // vsync after its update finished.
        var presented: [(at: CFTimeInterval, interval: CFTimeInterval)] = []
        for frame in frames {
            let interval = frame.target - frame.vsync
            guard interval > 0 else { continue }
            let late = max(0, frame.finished - frame.target - Self.commitSlack)
            let at = frame.target + (late / interval).rounded(.up) * interval
            // Same vsync as the frame before: that one was replaced before it was shown.
            if let last = presented.last, at - last.at < interval / 2 {
                presented[presented.count - 1] = (at, interval)
            } else {
                presented.append((at, interval))
            }
        }

        var frameTimes: [Double] = []   // ms
        var hitchTimes: [Double] = []   // ms
        for (previous, current) in zip(presented, presented.dropFirst()) {
            let frameTime = (current.at - previous.at) * 1000
            let expected = current.interval * 1000
            frameTimes.append(frameTime)
            if frameTime > expected * 1.5 { hitchTimes.append(frameTime - expected) }
        }
        let updateTimes = frames.map { ($0.finished - $0.vsync) * 1000 }
        let intervals = presented.map { $0.interval * 1000 }

        let duration = (presented.last?.at ?? 0) - (presented.first?.at ?? 0)
        let hitchTotal = hitchTimes.reduce(0, +)
        let medianInterval = Self.percentile(intervals, 0.5)
        continuation.resume(returning: [
            "seconds": Self.round(duration),
            "pointsPerSecond": pointsPerSecond,
            "travelPoints": Self.round(Double(abs(bottom - top))),
            "documentHeight": Self.round(Double(scrollView.documentView?.frame.height ?? 0)),
            "viewportHeight": Self.round(Double(scrollView.contentView.bounds.height)),
            "frames": presented.count,
            "frameTimeMs": [
                "p50": Self.round(Self.percentile(frameTimes, 0.5)),
                "p95": Self.round(Self.percentile(frameTimes, 0.95)),
                "max": Self.round(frameTimes.max() ?? 0),
            ],
            "updateTimeMs": [
                "p50": Self.round(Self.percentile(updateTimes, 0.5)),
                "p95": Self.round(Self.percentile(updateTimes, 0.95)),
                "max": Self.round(updateTimes.max() ?? 0),
            ],
            "hitches": hitchTimes.count,
            "hitchTimeMs": Self.round(hitchTotal),
            "longestHitchMs": Self.round(hitchTimes.max() ?? 0),
            "hitchTimeRatioMsPerS": Self.round(duration > 0 ? hitchTotal / duration : 0),
            "displayLinkHz": medianInterval > 0 ? Self.round(1000 / medianInterval) : 0,
            "unrestedFrames": unrestedFrames,
            "timedOut": timedOut,
        ])
    }

    /// Nearest-rank percentile; 0 for no samples.
    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    private static func round(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}

#endif
