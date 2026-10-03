// EVERYTHING in this file is behind `#if DEBUG` — the type declarations too, not just the
// startup call — so none of these symbols exist in a Release binary. Toki holds real Claude
// OAuth refresh tokens; a control channel that reached a shipped build would be a local
// backdoor to the user's accounts, and "#if DEBUG stays correct by convention" is not a
// sufficient guarantee for a socket that presses buttons.
#if DEBUG

import AppKit
import Darwin
import Foundation
import SwiftUI
import TokiCore
import TokiFixtures

/// DEBUG-only control channel: lets an automated agent see and drive this app WITHOUT any
/// TCC grant.
///
/// `screencapture` and AppleScript both need Screen Recording / Accessibility, which macOS
/// periodically revokes — an automated loop built on them breaks on a schedule and needs a
/// human at a GUI to repair. TCC guards access to *other* processes, so an app that renders
/// its own views and presses its own buttons needs no permission at all. Hence: in-process
/// `NSAccessibility` (never `AXUIElementCreateApplication` against an external pid) and the
/// app's own `SurfaceRenderer`.
///
/// Transport is an `AF_UNIX` socket, not TCP: filesystem permissions are the authorization
/// (mode 0600, owner only) and there is no port for anything to scan. The protocol is
/// line-delimited JSON — one request per line, one response per line.
///
/// **No command reads or writes Keychain items, credentials, tokens or account secrets.**
/// The channel moves UI state only: scenarios, navigation, appearance, window size,
/// snapshots, window ids, the accessibility tree, and a tab's scroll position.
///
/// **No command takes focus from the user.** An agent driving this channel runs while its
/// owner is at the keyboard, so a command that threw a window over their work would make the
/// channel unusable exactly when it is wanted. `navigate` shows the dashboard with
/// `orderFrontRegardless()` and leaves the frontmost app alone; activation is opt-in
/// (`{"activate": true}`), for handing the app to a human to look at.
///
/// **Invariant: exactly one command runs at a time, process-wide.** Hopping to the main actor
/// is not enough on its own — `press` and `withAccessibilityHierarchy` spin
/// `RunLoop.main.run(until:)`, and a nested run loop drains the main queue, so a second
/// connection's main-actor work would execute *inside* the first's (a `scenario` landing
/// halfway through a `snapshot`). `commandLock` therefore serialises whole request/response
/// round trips on the connection threads: a second connection blocks before it ever enqueues
/// main-actor work, so no nested run loop can find any to run.
@MainActor
enum DebugControlChannel {

    /// The environment variable that moves the rendezvous point off the shared default.
    ///
    /// `start()` `unlink`s the path before binding it, which is correct for clearing a dead
    /// socket file but fatal to a LIVE one: a second instance on the same path silently
    /// steals the name, and the developer's already-running Debug build keeps a listening fd
    /// nobody can reach any more. Two CI jobs on one runner collide the same way. So anything
    /// that launches its own instance — `scripts/flow-onboarding.sh` does — sets this to a
    /// private path and leaves the shared one alone.
    static let socketPathEnvironmentKey = "TOKI_DEBUG_SOCKET"

    /// The one filesystem rendezvous point. `temporaryDirectory` is `$TMPDIR`, which is
    /// already per-user on macOS, so two users' apps never collide on this path.
    ///
    /// Overridable via `TOKI_DEBUG_SOCKET`; with the variable unset (or empty) this is
    /// exactly the path it has always been, so nothing that already knows
    /// `"$TMPDIR"toki-debug.sock` has to learn anything new.
    static let socketURL: URL = {
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-debug.sock")
        guard
            let override = ProcessInfo.processInfo.environment[socketPathEnvironmentKey],
            !override.isEmpty
        else { return fallback }
        return URL(fileURLWithPath: override)
    }()

    /// The app's dependency graph, handed over at construction (see the two marked lines in
    /// `ServiceContainer.init`). Weak: the channel must never be the reason the graph — and
    /// through it the whole app — stays alive.
    private(set) static weak var container: ServiceContainer?

    /// Registers the graph the commands operate on. Called from `ServiceContainer.init`,
    /// which is the smallest possible hand-over: `TokiApp` owns the container as `@State`
    /// and `AppDelegate` cannot reach it.
    static func register(_ container: ServiceContainer) {
        self.container = container
    }

    private static var listeningFD: Int32 = -1
    private static var acceptSource: DispatchSourceRead?

    /// Depth cap on the accessibility dump. Deep enough to reach any leaf in this app's
    /// hierarchy, shallow enough that a pathological tree cannot blow up a reply.
    private static let maxTreeDepth = 12

    /// Hard ceiling on nodes per `tree` reply, for the same reason as the depth cap.
    private static let maxTreeNodes = 4_000

    // MARK: - Lifecycle

    /// Binds, listens, and starts accepting. Idempotent; failures are reported on stdout and
    /// leave the app running normally — a broken debug channel must never take the app down.
    static func start() {
        guard listeningFD < 0 else { return }
        let path = socketURL.path

        // A leftover socket file from a previous run is not reusable: `bind` fails with
        // EADDRINUSE on an existing path even when nothing is listening on it.
        unlink(path)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            print("[toki-debug] socket path too long for sockaddr_un: \(path)")
            return
        }
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = path.withCString { strlcpy(destination, $0, capacity) }
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[toki-debug] socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            print("[toki-debug] bind() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        // Owner-only, set explicitly rather than trusting whatever `umask` this process
        // inherited: the socket IS the authorization boundary.
        guard chmod(path, 0o600) == 0 else {
            print("[toki-debug] chmod 0600 failed: \(String(cString: strerror(errno)))")
            close(fd)
            unlink(path)
            return
        }

        guard listen(fd, 8) == 0 else {
            print("[toki-debug] listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            unlink(path)
            return
        }

        listeningFD = fd
        acceptSource = acceptSource(for: fd)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in MainActor.assumeIsolated { stop() } }

        print("[toki-debug] control channel listening on \(path)")
        fflush(stdout)
    }

    /// Stops listening and removes the socket file, so the next launch does not have to
    /// clean up after this one.
    static func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listeningFD = -1
        unlink(socketURL.path)
    }

    // MARK: - Connections

    /// Accepting on a dispatch source keeps the main thread free; each connection then gets
    /// its own thread (see `serve`), so a blocking read never occupies a libdispatch worker
    /// or a cooperative-pool thread.
    ///
    /// Built in a `nonisolated` function on purpose: a closure written inside a main-actor
    /// method inherits that isolation, and the isolation check the compiler then inserts
    /// traps the moment the handler runs on the source's own queue.
    private nonisolated static func acceptSource(for fd: Int32) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: DispatchQueue(label: "dev.komar.toki.debug-channel.accept")
        )
        source.setEventHandler { acceptOne(on: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private nonisolated static func acceptOne(on listeningFD: Int32) {
        let fd = accept(listeningFD, nil, nil)
        guard fd >= 0 else { return }
        let thread = Thread { serve(fd) }
        thread.name = "dev.komar.toki.debug-channel.connection"
        thread.start()
    }

    /// Serialises command execution across every connection — see the type's doc comment for
    /// why the main-actor hop alone does not. Held by the connection thread (never by the main
    /// actor), so a blocked connection cannot stall the app.
    private nonisolated static let commandLock = NSLock()

    /// One connection, one thread, blocking reads. Lines are handled strictly in order:
    /// each hops to the main actor and waits, which is what makes `click` → `snapshot`
    /// sequences deterministic for the caller.
    private nonisolated static func serve(_ fd: Int32) {
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)

        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 8192) }
            guard count > 0 else { break }
            pending.append(contentsOf: chunk[0..<count])

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending = Data(pending[pending.index(after: newline)...])
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                // The lock spans the reply write too, so a caller's response can never be
                // interleaved with another connection's work on the same UI state.
                commandLock.lock()
                writeLine(handleOnMain(line), to: fd)
                commandLock.unlock()
            }
        }
        close(fd)
    }

    /// Command execution hops to the main actor because every piece of state it touches —
    /// the container, the view models, the windows, `NSApp` — is main-actor isolated.
    private nonisolated static func handleOnMain(_ line: String) -> String {
        let reply = ReplyBox()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            reply.value = await respondAllowingSuspension(to: line)
            done.signal()
        }
        done.wait()
        return reply.value
    }

    /// Carries one reply back across the semaphore. `@unchecked Sendable` is honest here:
    /// the semaphore is the synchronization — the write happens-before the wait returns.
    private final class ReplyBox: @unchecked Sendable {
        var value = ""
    }

    private nonisolated static func writeLine(_ text: String, to fd: Int32) {
        let bytes = Array((text + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes {
                write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            guard written > 0 else { return }
            offset += written
        }
    }

    // MARK: - Protocol

    private static let commands = [
        "surfaces", "scenario", "navigate", "snapshot", "windows", "tree", "click", "appearance",
        "resize", "scroll",
    ]

    /// `scroll` runs for seconds and must leave the main thread free while it does — a
    /// display link, not a nested run loop, drives it, so what it measures is the app's own
    /// frame loop. Every other command answers synchronously through `respond(to:)`.
    private static func respondAllowingSuspension(to line: String) async -> String {
        guard
            let data = line.data(using: .utf8),
            let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            request["cmd"] as? String == "scroll"
        else { return respond(to: line) }
        return await scroll(request["args"] as? [String: Any] ?? [:])
    }

    private static func respond(to line: String) -> String {
        guard
            let data = line.data(using: .utf8),
            let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let command = request["cmd"] as? String
        else {
            // Malformed input is an answer, not a disconnect: the connection stays open so a
            // caller that fumbled one line can just send the next one.
            return fail("malformed request: expected one JSON object per line, {\"cmd\":\"…\",\"args\":{…}}")
        }
        let args = request["args"] as? [String: Any] ?? [:]

        switch command {
        case "surfaces":   return ok(["surfaces": Surface.allCases.map(\.rawValue)])
        case "scenario":   return scenario(args)
        case "navigate":   return navigate(args)
        case "snapshot":   return snapshot(args)
        case "windows":    return windows()
        case "tree":       return tree(args)
        case "click":      return click(args)
        case "appearance": return appearance(args)
        case "resize":     return resize(args)
        case "scroll":     return fail("scroll is handled asynchronously")
        default:
            return fail("unknown command \"\(command)\"; valid commands: \(commands.joined(separator: ", "))")
        }
    }

    private static func ok(_ fields: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["ok": true]
        for (key, value) in fields { object[key] = value }
        return encode(object)
    }

    private static func fail(_ message: String) -> String {
        encode(["ok": false, "error": message])
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8)
        else { return "{\"ok\":false,\"error\":\"reply could not be encoded as JSON\"}" }
        return text
    }

    // MARK: - Surfaces

    /// The renderable surfaces. Everything from `usage` down is the dashboard window showing
    /// that tab — rendering the real `DashboardView` (rather than each tab's content view in
    /// isolation) is what makes a snapshot show what the user actually sees, toolbar and all.
    private enum Surface: String, CaseIterable {
        case popover, dashboard, usage, machine, accounts, settings
        case gallery
        /// Not a dashboard tab anymore — `instances` and `environment` merged into `machine`,
        /// and `statistics` retired into `usage` (shown there on every range) — but still worth
        /// rendering standalone: the review compares against earlier renders of exactly
        /// these names, so they stay addressable by them.
        case instances, environment, statistics
        /// The generation speed tab.
        case speed
        /// The status item's rendered indicator strip — not the real `NSStatusItem` (there is
        /// no first-party access to it, and `screencapture`/AppleScript need a Screen Recording
        /// TCC grant this control channel exists to avoid), but the exact `MenuBarStripView`
        /// content `MenuBarLabel` rasterizes into it, resolved against whatever `container`'s
        /// `LiveLimits` currently holds — so `scenario` + this surface together prove the strip
        /// is wired to live data rather than a constant.
        case menuBarStrip
        /// `MenuBarEditorView` — the dedicated sheet Settings' "Menu Bar" row opens, rendered
        /// standalone (not through an actual `.sheet` presentation, which would need a host
        /// window and a button click to reach). Rendered with NO height override, unlike
        /// every other tab surface here: `MenuBarEditorView.body` only fixes its width, so
        /// this reports the view's true natural content height — the number the editor's
        /// density requirement ("fits at 760x560 with three indicators, no scrolling") is
        /// checked against, rather than one silently clamped to look right.
        case menuBarEditor
        /// `NotificationsEditorView` — the sheet Settings' "Notifications" row opens, rendered
        /// standalone for the same reason `menuBarEditor` is (an actual `.sheet` presentation
        /// would need a host window and a button click to reach). Rendered with NO height
        /// override, likewise: only the view's width is fixed, so this reports its true natural
        /// content height against the 560pt sheet it has to fit in.
        case notificationsEditor

        /// Sensible default render width: the popover is a fixed 320-pt panel, the gallery
        /// is measured wider (900) like SnapshotRunner's copy, the dashboard window's default
        /// is 860 (min 860), so 880 leaves it un-squeezed. The strip is `fixedSize()` and tiny
        /// regardless of the width offered, so 200 just needs to be more than that. The editor
        /// matches its own sheet width (`MenuBarEditorView.sheetWidth`).
        var defaultWidth: CGFloat {
            switch self {
            case .popover: 320
            case .gallery: 900
            case .menuBarStrip: 200
            case .menuBarEditor: MenuBarEditorView.sheetWidth
            case .notificationsEditor: NotificationsEditorView.sheetWidth
            default: 880
            }
        }

        /// The dashboard tab this surface shows, or nil for surfaces that are not a tab
        /// (the popover, the design-system gallery, the menu-bar strip, the menu-bar
        /// editor, and `instances`/`environment`/`statistics` — which render standalone
        /// below, not through a `DashboardView` tab that no longer exists for them).
        var section: DashboardSection? {
            switch self {
            case .popover, .dashboard, .gallery, .menuBarStrip, .menuBarEditor, .notificationsEditor: nil
            case .instances, .environment, .statistics: nil
            case .usage: .usage
            case .speed: .speed
            case .machine: .machine
            case .accounts: .accounts
            case .settings: .settings
            }
        }
    }

    private static func view(for surface: Surface, container: ServiceContainer) -> AnyView {
        if surface == .popover {
            return AnyView(
                MenuBarPanelView(
                    menuBar: container.menuBarVM,
                    dashboard: container.dashboardVM,
                    accounts: container.accountsVM,
                    codexAccounts: container.codexAccountsVM,
                    navigation: container.navigation,
                    serviceStatus: container.serviceStatus,
                    codexServiceStatus: container.codexServiceStatus,
                    providerAvailability: container.providerAvailability
                )
            )
        }
        // The gallery has no view model and is not a dashboard tab (section == nil above) —
        // it must be special-cased here too, or it would fall through to the DashboardView
        // build below with a nil section, silently rendering whatever tab `container`'s own
        // navigation happens to be on instead of the gallery.
        if surface == .gallery {
            return AnyView(GalleryView())
        }
        // `instances`/`environment`/`statistics` are no longer dashboard tabs (`section ==
        // nil` above), so — like the gallery — they must be special-cased here or they would
        // fall through to the `DashboardView` build below and silently render whatever tab
        // `container`'s own navigation happens to be on. Rendered as the same standalone
        // views the snapshot harness uses for these surfaces.
        if surface == .instances {
            return AnyView(InstancesView(model: container.instancesVM, topInset: Spacing.xl))
        }
        if surface == .environment {
            return AnyView(EnvironmentView(model: container.environmentVM, topInset: Spacing.xl))
        }
        if surface == .statistics {
            return AnyView(StatisticsView(model: container.statisticsVM, topInset: Spacing.xl))
        }
        if surface == .menuBarStrip {
            let menuBar = container.menuBarVM
            let indicators = menuBar.isExtraUsageActive
                ? [menuBar.extraUsageIndicator]
                : menuBar.resolvedIndicators
            // The real production view — the exact rasterized, template `NSImage` `MenuBarLabel`
            // hands `MenuBarExtra`, not a re-derivation of it — so this surface proves both the
            // live-data wiring AND the template image itself, not just the pre-rasterization
            // shapes.
            return AnyView(
                MenuBarLabel(
                    indicators: indicators,
                    isExtraUsage: menuBar.isExtraUsageActive,
                    style: menuBar.configuration.style
                )
                .padding(Spacing.sm)
                .background(Palette.card)
            )
        }
        if surface == .menuBarEditor {
            // No height override — see the case's own doc comment above: this surface exists
            // to report the editor's true natural content height, not one clamped to look
            // right regardless of what's actually inside it.
            return AnyView(MenuBarEditorView(menuBar: container.menuBarVM))
        }
        if surface == .notificationsEditor {
            // No height override, same as the menu-bar editor above.
            return AnyView(NotificationsEditorView(menuBar: container.menuBarVM))
        }

        // A throwaway navigation object, so rendering a tab never moves the tab the user
        // (or a previous `navigate`) is on.
        let navigation = DashboardNavigation()
        navigation.section = surface.section ?? container.navigation.section
        let dashboard = DashboardView(
            model: container.dashboardVM,
            instances: container.instancesVM,
            environment: container.environmentVM,
            menuBar: container.menuBarVM,
            serviceStatus: container.serviceStatus,
            codexServiceStatus: container.codexServiceStatus,
            providerAvailability: container.providerAvailability,
            accounts: container.accountsVM,
            codexAccounts: container.codexAccountsVM,
            statistics: container.statisticsVM,
            speed: container.speedVM,
            navigation: navigation
        )

        // The Settings tab reads `UpdaterController` as an `@EnvironmentObject`, so that one
        // surface has to be handed one. It must be the container's — building a second live
        // `SPUStandardUpdaterController` would give the process two schedulers writing the
        // same Sparkle `UserDefaults` keys.
        guard navigation.section == .settings else { return AnyView(dashboard) }
        return AnyView(dashboard.environmentObject(container.updater))
    }

    // MARK: - Commands

    private static func scenario(_ args: [String: Any]) -> String {
        guard let container else { return fail(noContainer) }
        guard let name = args["name"] as? String else {
            return fail("scenario needs {\"name\":\"…\"}; valid names: \(scenarioNames)")
        }
        if name == "live" {
            container.apply(.live)
        } else if let scenario = Scenario(rawValue: name) {
            container.apply(.fixture(scenario))
        } else {
            return fail("unknown scenario \"\(name)\"; valid names: \(scenarioNames)")
        }
        return ok(["scenario": name])
    }

    private static var scenarioNames: String {
        (["live"] + Scenario.allCases.map(\.rawValue)).joined(separator: ", ")
    }

    private static func navigate(_ args: [String: Any]) -> String {
        guard let container else { return fail(noContainer) }
        guard
            let raw = args["section"] as? String,
            let section = DashboardSection(identifier: raw)
        else {
            return fail("navigate needs {\"section\":\"…\"}; valid sections: \(sectionNames)")
        }
        container.navigation.section = section
        // `openDashboard` is wired by `TokiApp` (which owns SwiftUI's `openWindow`); the
        // notification is the same bridge `AppDelegate` uses when it has no container.
        if let open = container.openDashboard {
            open()
        } else {
            NotificationCenter.default.post(
                name: .tokiOpenDashboard, object: nil, userInfo: ["section": raw]
            )
        }
        // Showing a window and STEALING THE USER'S FOCUS are two different things, and this
        // command only ever needed the first. It used to do both — `activateAsRegularApp` ends
        // in `NSApp.activate(ignoringOtherApps: true)` — so every navigation threw Toki over
        // whatever the user was working in. That is not a cosmetic annoyance: it makes the
        // channel unusable while its owner is at the keyboard, which is exactly when an agent
        // is driving it.
        //
        // `orderFrontRegardless()` is the whole fix. It puts the window on screen from a
        // background app without activating it, so the user keeps focus and Toki simply exists,
        // usually underneath their frontmost window. That is enough for everything the channel
        // does downstream: `tree` and `click` go through in-process `NSAccessibility` (neither
        // needs key-ness), `snapshot` renders offscreen, and a real screen capture of the
        // window by id gets its FULL content even fully occluded — the compositor renders a
        // captured window independently of what is stacked over it (see `windows` below).
        //
        // The activation path stays reachable via {"activate": true} for the one case that
        // genuinely wants it: handing the running app to the user to look at.
        let shouldActivate = args["activate"] as? Bool ?? false
        if shouldActivate {
            activateAsRegularApp(orderingFrontWindowTitled: dashboardWindowTitle)
        } else {
            // `openDashboard` routes through SwiftUI's `openWindow`, which materialises the
            // window on a later turn of the run loop. Spin until it shows up so the reply is
            // true when it is sent — an agent's next command is typically `windows` or
            // `snapshot`, and both need the window to already exist.
            let deadline = Date().addingTimeInterval(1.5)
            while dashboardWindow == nil, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            dashboardWindow?.orderFrontRegardless()
        }
        return ok(["section": raw, "activated": shouldActivate])
    }

    /// Vends each on-screen window's `windowNumber` — which IS its `CGWindowID` — so a caller
    /// can take a REAL screen capture of one window with `screencapture -x -o -l<id>`.
    ///
    /// ## Why this exists next to `snapshot`
    /// They answer different questions and neither replaces the other.
    ///
    /// `snapshot` renders offscreen through `SurfaceRenderer`: deterministic, full scroll
    /// height, no window required, no TCC grant. But `cacheDisplay` cannot draw backdrop blur —
    /// `NSVisualEffectView` samples what is *behind the window*, which is not in the view
    /// hierarchy — so Liquid Glass comes out as its flat fallback tint. It is the right tool
    /// for layout, copy, spacing and long scrolling content.
    ///
    /// A real capture by window id is the only way to judge the actual materials, and going
    /// through the window id rather than a rectangle of the screen is what makes it usable:
    /// the compositor renders the requested window's full content even when other windows are
    /// stacked over it, so nothing has to be raised, focused, or moved out of the user's way.
    ///
    /// ## Why the app does not capture itself
    /// It easily could — `SCScreenshotManager` with `SCContentFilter(desktopIndependentWindow:)`
    /// is a few lines. It would also mean Toki asking for Screen Recording, a grant macOS
    /// re-confirms on a schedule, to photograph pixels it just drew. Handing out the id instead
    /// keeps every TCC prompt out of this app: the caller captures with Apple's own
    /// `screencapture`, under whatever grant the calling terminal already holds.
    ///
    /// Windows that are minimised or on another Space are excluded — they have an id but no
    /// content to capture, and returning one would produce a blank PNG and a confusing hunt.
    private static func windows() -> String {
        let visible = NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized }
        let described = visible.map { window -> [String: Any] in
            let frame = window.frame
            // `NSWindow.windowNumber` is usually the window's `CGWindowID` — but not always,
            // and the exception is one an agent hits immediately. The `MenuBarExtra` status
            // item reports 4294967296 (0x1_0000_0000), one past the top of `CGWindowID`'s
            // 32-bit range, and `screencapture -l` on it fails with "could not create image
            // from window" (measured, not assumed). Say so in the reply rather than letting a
            // caller discover it by taking a screenshot that produces no file.
            //
            // The menu-bar strip is reachable anyway — `snapshot` renders the `menuBarStrip`
            // surface offscreen, and it carries no glass to lose.
            let isCapturable = window.windowNumber > 0
                && window.windowNumber <= Int(CGWindowID.max)
            var entry: [String: Any] = [
                "id": window.windowNumber,
                "capturable": isCapturable,
                "title": window.title,
                "key": window.isKeyWindow,
                // A sheet has no id of its own worth capturing: it is composited with the
                // window it is attached to, and `screencapture -l` on either id returns the
                // parent WITH the sheet drawn on it. Say which is which so a caller reading
                // two same-sized entries is not left guessing.
                "sheet": window.isSheet,
            ]
            if [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) {
                entry["frame"] = [frame.minX, frame.minY, frame.width, frame.height]
                    .map { Int($0.rounded()) }
            }
            if let parent = window.sheetParent {
                entry["parent"] = parent.windowNumber
            }
            return entry
        }
        return ok([
            "windows": described,
            "capture": "screencapture -x -o -l<id> <path.png>",
        ])
    }

    private static var sectionNames: String {
        Surface.allCases.compactMap { $0.section == nil ? nil : $0.rawValue }
            .joined(separator: ", ")
    }

    private static func snapshot(_ args: [String: Any]) -> String {
        guard let container else { return fail(noContainer) }
        guard
            let raw = args["surface"] as? String,
            let surface = Surface(rawValue: raw)
        else {
            return fail("snapshot needs {\"surface\":\"…\"}; valid surfaces: \(Surface.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("snapshot needs {\"path\":\"/absolute/file.png\"}")
        }
        let colorScheme: ColorScheme
        switch (args["appearance"] as? String) ?? "system" {
        case "dark": colorScheme = .dark
        case "light": colorScheme = .light
        case "system": colorScheme = systemColorScheme
        case let other: return fail("unknown appearance \"\(other)\"; valid: dark, light, system")
        }
        let width = (args["width"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? surface.defaultWidth
        guard width >= 120 else { return fail("width \(width) is too small to lay a surface out") }
        let height = (args["height"] as? NSNumber).map { CGFloat($0.doubleValue) }
        if let height, height < 120 || height > 30_000 {
            return fail("height \(height) must be between 120 and 30000")
        }

        // Both of these are restored below. `flatSurfaces` is global and read during body
        // evaluation, so leaving it on would flatten the app's real glass windows on their
        // next redraw; `isVisible` is what gates live analytics reloads, and an offscreen
        // render's `onAppear` would otherwise leave the dashboard "visible" forever.
        let previousFlat = SnapshotConfig.flatSurfaces
        let previousVisible = container.dashboardVM.isVisible
        SnapshotConfig.flatSurfaces = true
        defer {
            SnapshotConfig.flatSurfaces = previousFlat
            container.dashboardVM.isVisible = previousVisible
        }

        do {
            let url = URL(fileURLWithPath: path)
            // Callers hand us a path, not a prepared directory; making it is one syscall and
            // saves a round trip on every fresh output folder.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let pixels = try SurfaceRenderer.writePNG(
                view(for: surface, container: container),
                to: url,
                width: width,
                height: height,
                colorScheme: colorScheme
            )
            return ok([
                "path": path,
                "width": Int(pixels.width),
                "height": Int(pixels.height),
                "surface": surface.rawValue,
                "appearance": colorScheme == .dark ? "dark" : "light",
            ])
        } catch {
            return fail("snapshot failed: \(error)")
        }
    }

    private static func tree(_ args: [String: Any]) -> String {
        withAccessibilityHierarchy { () -> String in
            guard let window = targetWindow(args) else { return fail(noWindow) }
            var budget = maxTreeNodes
            let root = node(window, depth: 0, budget: &budget)
            return ok([
                "window": window.title,
                "nodes": maxTreeNodes - budget,
                "tree": root,
            ])
        }
    }

    private static func click(_ args: [String: Any]) -> String {
        guard let match = args["match"] as? String, !match.isEmpty else {
            return fail("click needs {\"match\":\"identifier-or-label\"}")
        }
        return withAccessibilityHierarchy { () -> String in
            guard let window = targetWindow(args) else { return fail(noWindow) }

            var candidates: [String] = []
            guard let element = find(match, in: window, depth: 0, candidates: &candidates) else {
                var seen = Set<String>()
                let unique = candidates.filter { seen.insert($0).inserted }
                return fail("no element with identifier or label \"\(match)\"; candidates: \(unique.prefix(80).joined(separator: " | "))")
            }
            let role = element.accessibilityRole?()?.rawValue ?? "?"
            switch press(element, in: window) {
            case let .failed(reason):
                return fail("found \"\(match)\" (role \(role)) but \(reason)")
            case let .pressed(how):
                return ok([
                    "matched": match,
                    "role": role,
                    "via": how,
                    "label": element.accessibilityLabel?() ?? element.accessibilityTitle?() ?? "",
                ])
            }
        }
    }

    private static func appearance(_ args: [String: Any]) -> String {
        guard let mode = args["mode"] as? String else {
            return fail("appearance needs {\"mode\":\"dark|light|system\"}")
        }
        switch mode {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "system": NSApp.appearance = nil
        default: return fail("unknown appearance mode \"\(mode)\"; valid: dark, light, system")
        }
        return ok(["mode": mode])
    }

    private static func resize(_ args: [String: Any]) -> String {
        guard
            let width = (args["width"] as? NSNumber).map({ CGFloat($0.doubleValue) }),
            let height = (args["height"] as? NSNumber).map({ CGFloat($0.doubleValue) })
        else { return fail("resize needs {\"width\":…,\"height\":…}") }
        guard let window = dashboardWindow else { return fail(noWindow) }
        window.setContentSize(NSSize(width: width, height: height))
        // The content rect, not `contentLayoutRect`: this window hides its title bar and
        // extends content under it, so the layout rect is ~32pt shorter than what was set
        // and reporting it back would look like the resize had been clamped.
        let size = window.contentRect(forFrameRect: window.frame).size
        return ok(["width": Int(size.width.rounded()), "height": Int(size.height.rounded())])
    }

    /// Opens `section` (unfocused, as `navigate` does), waits for its content to outgrow the
    /// viewport, then hands the tab's main scroll view to `ScrollProbe`.
    private static func scroll(_ args: [String: Any]) async -> String {
        let section = args["section"] as? String ?? "speed"
        let seconds = (args["seconds"] as? NSNumber)?.doubleValue ?? 10
        let pointsPerSecond = (args["pointsPerSecond"] as? NSNumber)?.doubleValue ?? 600
        guard seconds > 0, seconds <= 120 else { return fail("seconds must be in (0, 120]") }
        guard pointsPerSecond > 0 else { return fail("pointsPerSecond must be positive") }

        let opened = navigate(["section": section])
        guard opened.contains("\"ok\":true") else { return opened }

        // The tab may still be computing its content; give it up to 10 s to become scrollable.
        var scrollView: NSScrollView?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let found = dashboardWindow.flatMap(mainScrollView(in:)) { scrollView = found; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let scrollView else {
            return fail("no scrollable content on \"\(section)\" — is the tab populated and taller than the window?")
        }
        // One more beat so the entrance animation has settled before frames are counted.
        try? await Task.sleep(for: .milliseconds(800))
        var fields = await ScrollProbe.run(scrollView, seconds: seconds, pointsPerSecond: pointsPerSecond)
        fields["section"] = section
        return ok(fields)
    }

    /// The largest on-screen scroll view whose document is taller than its viewport.
    private static func mainScrollView(in window: NSWindow) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor,
               let document = scroll.documentView,
               document.frame.height > scroll.contentView.bounds.height + 1 {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        window.contentView.map(walk)
        return found.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    // MARK: - Windows

    private static let dashboardWindowTitle = "Toki Dashboard"

    private static var dashboardWindow: NSWindow? {
        NSApp.windows.first { $0.title == dashboardWindowTitle }
    }

    /// The window a `tree`/`click` applies to. `surface` is a hint, not a requirement: with
    /// no hint we use the key window (what a user's keystroke would reach), which is also
    /// the only sane answer for the menu-bar popover — it is an anonymous `MenuBarExtra`
    /// panel with no title to match on, and it is key exactly while it is open.
    private static func targetWindow(_ args: [String: Any]) -> NSWindow? {
        let surface = (args["surface"] as? String).flatMap(Surface.init(rawValue:))
        // The one surface that is NOT in the dashboard window and has no title to match on:
        // the real status item. Its button lives in AppKit's own status-bar window, which
        // belongs to this process, so walking it is the same in-process accessibility as any
        // other window here — and it is the only way to see what the status item actually
        // announces (`MenuBarLabel`'s accessibility label), rather than what the label view
        // asked for. Matched by class name because the window is AppKit's, private, untitled,
        // and never key.
        if surface == .menuBarStrip {
            return NSApp.windows.first { $0.className.contains("StatusBarWindow") }
        }
        if let surface, surface != .popover, let window = dashboardWindow {
            return window
        }
        if surface == .popover {
            return NSApp.keyWindow ?? NSApp.windows.first {
                $0.isVisible && $0.title != dashboardWindowTitle
            }
        }
        return NSApp.keyWindow ?? NSApp.mainWindow ?? dashboardWindow
            ?? NSApp.windows.first(where: \.isVisible)
    }

    private static let noWindow =
        "no window to inspect — open the dashboard first (navigate) or open the popover"

    private static let noContainer =
        "the service container is not registered yet; try again once the app has finished launching"

    private static var systemColorScheme: ColorScheme {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    // MARK: - Accessibility walking

    /// Runs `body` with AppKit's accessibility hierarchy fully materialized, then puts the
    /// flag back the way it was found.
    ///
    /// Without this, `NSHostingView` reports **no children at all** — SwiftUI builds its AX
    /// elements lazily and only bothers once a client has announced itself, which normally
    /// happens when VoiceOver or an Accessibility-granted app attaches. `AXEnhancedUserInterface`
    /// is the flag such a client sets; setting it on ourselves is the in-process equivalent
    /// and needs no TCC grant. It is reached through the ObjC runtime because the typed API
    /// (`accessibilitySetValue(_:forAttribute:)`) is deprecated and there is no modern
    /// replacement for this particular attribute.
    ///
    /// Scoped to the walk rather than latched on for the process's lifetime: while the flag is
    /// set AppKit keeps rebuilding full AX hierarchies for every window on every pass, and the
    /// channel is idle almost all of the time. Clearing it is **not** one-way — measured: two
    /// consecutive `tree` commands return the same node count, so the next command's `true`
    /// re-materializes the hierarchy just as the first one did.
    private static func withAccessibilityHierarchy<T>(_ body: () -> T) -> T {
        setEnhancedUserInterface(true)
        defer { setEnhancedUserInterface(false) }
        // AppKit rebuilds the hierarchy on its next pass; give it one before we walk.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return body()
    }

    private static func setEnhancedUserInterface(_ enabled: Bool) {
        let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        guard NSApp.responds(to: selector) else { return }
        _ = NSApp.perform(
            selector, with: NSNumber(value: enabled), with: "AXEnhancedUserInterface" as NSString
        )
    }

    /// In-process accessibility: the app reads and actuates its OWN hierarchy, so no TCC
    /// grant is involved. (`AXUIElementCreateApplication` against a pid is the
    /// permission-gated path this whole channel exists to avoid.)
    ///
    /// Elements are addressed through ObjC dynamic dispatch on `AnyObject` rather than a
    /// `as? any NSAccessibilityProtocol` cast: SwiftUI's own AX elements implement the
    /// accessibility selectors without their classes *declaring* conformance, so the Swift
    /// cast fails on them and the whole SwiftUI subtree comes back as unreadable — measured,
    /// not assumed. `responds(to:)` is implicit in the `?()` optional calls.
    private static func node(
        _ element: Any, depth: Int, budget: inout Int, viaViews: Bool = false
    ) -> [String: Any] {
        let object = element as AnyObject
        budget -= 1

        var dictionary: [String: Any] = ["role": object.accessibilityRole?()?.rawValue ?? "AXUnknown"]
        if let subrole = object.accessibilitySubrole?()?.rawValue, !subrole.isEmpty {
            dictionary["subrole"] = subrole
        }
        if let identifier = object.accessibilityIdentifier?(), !identifier.isEmpty {
            dictionary["identifier"] = identifier
        }
        if let label = object.accessibilityLabel?(), !label.isEmpty {
            dictionary["label"] = label
        }
        if let title = object.accessibilityTitle?(), !title.isEmpty {
            dictionary["title"] = title
        }
        if let value = axValue(object), !value.isEmpty {
            dictionary["value"] = value
        }
        // One-of-many controls (the tab strip, the range strip) look selected; whether they
        // *report* being selected is a different question, and the only way to answer it from
        // out here is to dump the attribute. Reported only when true, so no tree that had no
        // selection anywhere changes shape.
        if object.isAccessibilitySelected?() == true {
            dictionary["selected"] = true
        }
        // Screen coordinates, as AppKit reports them — enough to tell two same-labelled
        // elements apart and to see where one sits relative to another.
        //
        // Every component is checked for finiteness first, because `Int(.infinity)` traps and
        // takes the whole app down with it. An accessibility frame is legitimately allowed to
        // be `CGRect.infinite` or `.null` for an element with no meaningful geometry, and this
        // walk crashed on exactly that against a real `~/.claude` with many plugins and skills
        // — a debug tool that kills the app it is inspecting is worse than one that omits a
        // field, so a non-finite frame is simply left out of the reply.
        if let frame = object.accessibilityFrame?() {
            let components = [frame.minX, frame.minY, frame.width, frame.height]
            if components.allSatisfy(\.isFinite) {
                dictionary["frame"] = components.map { Int($0.rounded()) }
            }
        }

        // Once a subtree has been entered through the view hierarchy it keeps being walked that
        // way: the status-bar button's accessibility children are its *cell*, which reports
        // nothing, while the button itself carries the announced text.
        let axChildren = viaViews ? [] : (object.accessibilityChildren?() ?? [])
        let descendViaViews = axChildren.isEmpty
        let children = descendViaViews ? viewChildren(of: object) : axChildren
        if !children.isEmpty {
            if depth >= maxTreeDepth || budget <= 0 {
                dictionary["truncatedChildren"] = children.count
            } else {
                dictionary["children"] = children.map {
                    node($0, depth: depth + 1, budget: &budget, viaViews: descendViaViews)
                }
            }
        }
        return dictionary
    }

    /// Plain AppKit children, used only where the accessibility walk found none.
    ///
    /// The status item is why this exists: `NSStatusBarWindow` vends ZERO accessibility
    /// children — the menu bar's AX hierarchy is published by the system, not by our window —
    /// so an AX-only walk dead-ends at the window and never reaches the `NSStatusBarButton`
    /// that carries `MenuBarLabel`'s accessibility text. Scoped to the empty case so no tree
    /// that already had AX children changes shape.
    private static func viewChildren(of object: AnyObject) -> [Any] {
        if let window = object as? NSWindow { return window.contentView.map { [$0] } ?? [] }
        if let view = object as? NSView { return view.subviews }
        return []
    }

    /// Presses an element, returning how it was pressed (or nil if it could not be).
    ///
    /// Buttons answer the modern `accessibilityPerformPress`; row- and tab-like elements
    /// sometimes only answer pick; some elements only advertise `AXPress` through the old
    /// action API. A SwiftUI `Text` carrying an `onTapGesture` — which is exactly what this
    /// app's tab strip is — answers **none** of them and advertises no actions at all
    /// (measured, see the report). For those the fallback is a synthetic mouse down/up sent
    /// into this app's own event queue at the element's centre: still in-process, still no
    /// TCC grant, and it goes through the same hit-testing the user's real click does.
    /// The mechanism is reported back so a caller is never left guessing which one ran.
    private static func press(_ object: AnyObject, in window: NSWindow) -> PressOutcome {
        if object.accessibilityPerformPress?() == true { return .pressed("press") }
        if object.accessibilityPerformPick?() == true { return .pressed("pick") }

        let selector = NSSelectorFromString("accessibilityPerformAction:")
        if object.responds(to: selector), actionNames(object).contains("AXPress") {
            _ = object.perform(selector, with: "AXPress" as NSString)
            return .pressed("action")
        }

        guard let frame = object.accessibilityFrame?(), frame.width > 0, frame.height > 0 else {
            return .failed("it advertises no press action and has no usable frame")
        }
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        func mouse(_ type: NSEvent.EventType, _ pressure: Float) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: pressure
            )
        }
        guard let down = mouse(.leftMouseDown, 1), let up = mouse(.leftMouseUp, 0) else {
            return .failed("it advertises no press action and a synthetic event could not be built")
        }

        // Toki must be the ACTIVE app, and it may not be: since macOS 14 a background app
        // cannot take focus, so if the agent's terminal is frontmost this activation is
        // refused and the mouse-down goes nowhere. We say so rather than sending a click and
        // reporting success — a `click` that silently does nothing is worse than one that
        // fails loudly. (Window key-ness is not the gate: the mouse-down is what makes the
        // window key, which is exactly what a user's click does too.)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(1.5)
        while !NSApp.isActive, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard NSApp.isActive else {
            return .failed("""
                it advertises no press action, so it needs a synthetic click — and that needs \
                Toki frontmost, which macOS refused while another app holds focus (app active: \
                \(NSApp.isActive), window key: \(window.isKeyWindow), policy: \
                \(NSApp.activationPolicy().rawValue)). Bring Toki forward and retry
                """)
        }

        // Through `NSWindow.sendEvent`, not straight at the hit view: SwiftUI's tap gestures
        // are gesture recognizers, and recognizers are driven from `sendEvent` — dispatching
        // `mouseDown` at the hit view directly skips them entirely (measured).
        window.sendEvent(down)
        // SwiftUI settles a tap over a run-loop turn, not within one call.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.sendEvent(up)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return .pressed("synthetic-click")
    }

    private enum PressOutcome {
        case pressed(String)
        case failed(String)
    }

    private static func actionNames(_ object: AnyObject) -> [String] {
        let selector = NSSelectorFromString("accessibilityActionNames")
        guard object.responds(to: selector),
              let names = object.perform(selector)?.takeUnretainedValue() as? [String]
        else { return [] }
        return names
    }

    /// An element's `AXValue`, reached by selector because `accessibilityValue` is the one
    /// accessibility getter whose Swift overloads are ambiguous under `AnyObject` dispatch
    /// (three protocols declare it with three different return types). Its ObjC signature
    /// returns `id`, so `perform` is well-defined here.
    private static func axValue(_ object: AnyObject) -> String? {
        let selector = NSSelectorFromString("accessibilityValue")
        guard object.responds(to: selector),
              let value = object.perform(selector)?.takeUnretainedValue()
        else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// First element (depth-first) whose identifier, label, title, value — or, for an element
    /// that has none of those, subrole — equals `match`.
    ///
    /// Matching the visible text as well as the identifier is deliberate: this UI is almost
    /// entirely untagged today (one `accessibilityIdentifier` in the whole codebase) and the
    /// redesign rewrites these views, so a tagging campaign now would be thrown away. Value
    /// counts too because SwiftUI exposes a tappable `Text` (which is what the dashboard's
    /// tab strip is built from) as static text whose label is empty and whose value is the
    /// word on screen.
    ///
    /// Subrole is the fallback for the one family of controls that carries no text at all:
    /// the window's own chrome. `AXCloseButton` / `AXZoomButton` / `AXMinimizeButton` have an
    /// empty identifier, label, title AND value, so before this they were unreachable and
    /// invisible — they did not even appear in the "candidates" list a failed match prints.
    /// Closing the window is a real user action with real consequences elsewhere in the app
    /// (`scripts/flow-onboarding.sh` drives exactly that), so the channel has to be able to
    /// perform it. Only consulted when the element is otherwise nameless, so a subrole can
    /// never shadow a match on something the user can actually read.
    private static func find(
        _ match: String,
        in element: Any,
        depth: Int,
        candidates: inout [String]
    ) -> AnyObject? {
        guard depth <= maxTreeDepth else { return nil }
        let object = element as AnyObject
        let identifier = object.accessibilityIdentifier?()
        let label = object.accessibilityLabel?()
        let title = object.accessibilityTitle?()
        let value = axValue(object)
        if identifier == match || label == match || title == match || value == match {
            return object
        }
        let names = [identifier, label, title, value].compactMap { $0 }.filter { !$0.isEmpty }
        if names.isEmpty, let subrole = object.accessibilitySubrole?()?.rawValue, !subrole.isEmpty {
            if subrole == match { return object }
            candidates.append(subrole)
        }
        candidates.append(contentsOf: names)
        for child in object.accessibilityChildren?() ?? [] {
            if let hit = find(match, in: child, depth: depth + 1, candidates: &candidates) {
                return hit
            }
        }
        return nil
    }
}

#endif
