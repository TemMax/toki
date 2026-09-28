import AppKit
import SwiftUI
import TokiCore
import Vision

/// Integration regression for stale, vertically inverted text backing stores.
/// Requires a logged-in macOS session and Screen Recording for the calling terminal.
/// Uses the real banner and window compositor: cacheDisplay would redraw the broken
/// layers and erase the very stale-image condition this test needs to observe.
@main
struct StatusBannerRenderingProbe {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let status = ServiceStatus(severity: .outage, incident: StatusIncident(
            id: "rendering-probe", title: "Claude Code is unavailable",
            latestUpdate: "We are investigating elevated errors. We will provide an update as soon as possible.",
            updatedAt: Date().addingTimeInterval(-360),
            affectedComponentNames: ["claude.ai", "Claude API (api.anthropic.com)", "Claude Code"]
        ))
        var failures = 0
        for dark in [false, true] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            // Positive control: if a future OS changes its layer implementation and
            // injection stops working, this must fail rather than report a false pass.
            let cases: [(String, AnyView)] = [
                ("control", AnyView(VStack {
                    Text("Claude — service outage").font(.title)
                    Text("The rendering control must detect inverted text.")
                }.padding(16).panelCard().padding(16))),
                ("full", AnyView(ServiceStatusBannerFull(status: status).padding(16))),
                ("compact", AnyView(ServiceStatusBannerCompact(status: status).padding(16))),
            ]
            for (kind, view) in cases {
                let name = "\(kind)-\(dark ? "dark" : "light")"
                let window = NSWindow(
                    contentRect: NSRect(x: 200, y: 200, width: kind == "compact" ? 320 : 840, height: 260),
                    styleMask: [.titled], backing: .buffered, defer: false
                )
                window.title = "Toki banner rendering test"
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: view)
                window.contentView = host
                window.orderBack(nil) // Never activate or cover the user's work.
                defer { window.orderOut(nil); window.close() }
                for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                let before = try capture(window, to: output.appendingPathComponent("\(name)-before.png"))

                let readable = try recognizedText(before)
                guard readable.contains("Claude"),
                      kind != "full" || readable.contains("View status page") else {
                    throw NSError(domain: "StatusBannerRenderingProbe", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing readable banner content in \(name): \(readable)"])
                }

                // Fault injection, NOT a claim to reproduce SwiftUI's natural race:
                // draw a label with the wrong Y orientation, then settle its geometry
                // without invalidating the cached pixels. This recreates the reported
                // screenshot on the original implementation. Do not enter nested native
                // control hosts (the full banner's Link was unaffected in the report).
                injectStaleFlip(host.layer)
                CATransaction.flush()
                let after = try capture(window, to: output.appendingPathComponent("\(name)-after.png"))
                let changed = changedPixels(before, after)
                // Allow tiny compositor noise, but not an inverted line of text.
                let passed = changed != Int.max && (kind == "control" ? changed >= 100 : changed < 100)
                print("\(passed ? "PASS" : "FAIL") \(name): \(changed) pixels changed after stale-flip injection")
                if !passed { failures += 1 }
                if kind != "control" {
                    let accessible = hasAccessibleAction(window, compact: kind == "compact")
                    print("\(accessible ? "PASS" : "FAIL") \(name): accessible status-page action")
                    if !accessible { failures += 1 }
                }
            }
        }
        if failures > 0 { exit(1) }
    }

    @MainActor private static func injectStaleFlip(_ root: CALayer?) {
        guard let root else { return }
        // SwiftUI groups the banner's primitives in the first backing layer. Native
        // controls introduce their own backing-layer boundary beneath that container.
        guard let container = root.sublayers?.first else { return }
        func visit(_ layer: CALayer) {
            let name = String(describing: type(of: layer))
            if name == "NSViewBackingLayer" { return }
            if name == "CGDrawingLayer" {
                let original = layer.isGeometryFlipped
                layer.isGeometryFlipped = !original
                layer.setNeedsDisplay()
                layer.displayIfNeeded()
                layer.isGeometryFlipped = original
            }
            for child in layer.sublayers ?? [] { visit(child) }
        }
        for child in container.sublayers ?? [] { visit(child) }
    }

    @MainActor private static func capture(_ window: NSWindow, to url: URL) throws -> NSBitmapImageRep {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
            throw NSError(domain: "StatusBannerRenderingProbe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Window capture failed; check Screen Recording permission"])
        }
        return bitmap
    }

    @MainActor private static func hasAccessibleAction(_ window: NSWindow, compact: Bool) -> Bool {
        let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        _ = NSApp.perform(selector, with: true as NSNumber, with: "AXEnhancedUserInterface" as NSString)
        defer { _ = NSApp.perform(selector, with: false as NSNumber, with: "AXEnhancedUserInterface" as NSString) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        func find(_ object: AnyObject, depth: Int) -> Bool {
            guard depth < 30 else { return false }
            let label = object.accessibilityLabel?() ?? object.accessibilityTitle?() ?? ""
            let role = object.accessibilityRole?()
            if (compact ? label.contains("Opens the provider status page") : label == "View status page"),
               role == .button || role == .link {
                return object.isAccessibilityEnabled?() != false
            }
            return (object.accessibilityChildren?() ?? []).contains { find($0 as AnyObject, depth: depth + 1) }
        }
        return find(window, depth: 0)
    }

    private static func recognizedText(_ bitmap: NSBitmapImageRep) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private static func changedPixels(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else { return Int.max }
        var changed = 0
        for y in 0..<lhs.pixelsHigh {
            for x in 0..<lhs.pixelsWide {
                guard let a = lhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = rhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return Int.max }
                if max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                       abs(a.blueComponent - b.blueComponent)) > 0.08 { changed += 1 }
            }
        }
        return changed
    }
}
