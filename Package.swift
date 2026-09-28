// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokiCore",
    platforms: [.macOS(.v14)],
    products: [
        /// Umbrella library that the app target imports as `import TokiCore`.
        /// The `TokiCore` target re-exports all six sub-modules so the app
        /// needs only a single import.
        .library(name: "TokiCore", targets: ["TokiCore"]),
        /// TokiFixtures is deliberately NOT part of the `TokiCore` umbrella (it depends on
        /// TokiAccounts/TokiAnalytics/TokiModels for mock data, not app behavior), so the app
        /// target links it as its own product and imports it explicitly.
        .library(name: "TokiFixtures", targets: ["TokiFixtures"]),
        /// TokiDesign is deliberately NOT part of the `TokiCore` umbrella (see the target
        /// comment below), so the app target links it as its own product and imports it
        /// explicitly — this is what lets `App/Sources/Palette.swift` resolve its colours
        /// from the measured tokens.
        .library(name: "TokiDesign", targets: ["TokiDesign"]),
        /// TokiMenuBar is deliberately NOT part of the `TokiCore` umbrella (see the target
        /// comment below), so the app target links it as its own product and imports it
        /// explicitly.
        .library(name: "TokiMenuBar", targets: ["TokiMenuBar"]),
        .library(name: "TokiAlerts", targets: ["TokiAlerts"]),
        .library(name: "TokiStatus", targets: ["TokiStatus"]),
    ],
    targets: [
        // MARK: - Umbrella target

        /// Re-exports all sub-modules via @_exported import.
        .target(
            name: "TokiCore",
            dependencies: [
                "TokiLogging",
                "TokiModels",
                "TokiKeychain",
                "TokiLimits",
                "TokiPricing",
                "TokiTranscripts",
                "TokiAnalytics",
                "TokiEnvironment",
                "TokiProcesses",
                "TokiOnboarding",
                "TokiAccount",
                "TokiAccounts",
                "TokiSwap",
                "TokiAutoSwap",
                "TokiAlerts",
                "TokiStatus",
            ]
        ),

        // MARK: - Library targets

        // Privacy-enforcing logging: a `LogMessage` whose interpolation has no unlabelled
        // `String` overload (so a secret cannot be logged by accident at compile time), a
        // `Redactor` that scrubs every finished line at run time, and age/size-based
        // retention over `~/Library/Logs/Toki`. Deliberately dependency-free — that is what
        // lets every other module depend on it without a cycle. No external package: no
        // Swift logging library redacts secrets, which is the whole reason this exists.
        .target(name: "TokiLogging"),

        .target(
            name: "TokiModels",
            dependencies: ["TokiLogging"]
        ),

        .target(
            name: "TokiKeychain",
            dependencies: ["TokiLogging", "TokiModels"]
        ),

        .target(
            name: "TokiLimits",
            dependencies: ["TokiLogging", "TokiModels", "TokiEnvironment"]
        ),

        .target(
            name: "TokiPricing",
            dependencies: ["TokiLogging", "TokiModels"]
        ),

        .target(
            name: "TokiTranscripts",
            dependencies: ["TokiLogging", "TokiModels"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // Depends only on TokiModels (plus TokiLogging): it consumes the RecordProviding and
        // PricingProviding protocols, never the concrete impls — so each parallel
        // agent's `swift build --target` stays isolated from sibling modules.
        .target(
            name: "TokiAnalytics",
            dependencies: ["TokiLogging", "TokiModels"]
        ),

        // Reads the local Claude Code config under ~/.claude (CLI version, plugins,
        // marketplaces, skills, MCP servers). Fully local in v1: no network, no
        // spawned processes, and reads only a non-sensitive field allowlist — never
        // credentials/tokens/secrets. See Sources/TokiModels/Environment.swift.
        .target(
            name: "TokiEnvironment",
            dependencies: ["TokiLogging", "TokiModels"]
        ),

        // Enumerates running Claude Code CLI processes (version, project cwd,
        // uptime, memory) via libproc. Reads only the current user's own
        // processes; never spawns processes and never reads process argv.
        .target(
            name: "TokiProcesses",
            dependencies: ["TokiLogging", "TokiModels"]
        ),

        // First-run Keychain-access onboarding: a silent probe of credential
        // access drives a state machine that guides the user through the
        // macOS Keychain authorization dialog. See CredentialOnboarding in
        // TokiModels for the probe contract.
        .target(
            name: "TokiOnboarding",
            dependencies: ["TokiLogging", "TokiModels"]
        ),

        // Reads ONLY the active account's identity (display name, email,
        // organization) from the `oauthAccount` block of ~/.claude.json — the one
        // deliberate, narrowly-scoped exception to the "oauthAccount is off-limits"
        // rule. Never returns tokens or any other field. No deps beyond TokiLogging.
        .target(
            name: "TokiAccount",
            dependencies: ["TokiLogging"]
        ),

        // Stores several Claude accounts: identity, credential and the lineage that
        // credential belongs to. The lineage (a fingerprint of the refresh token) is
        // what lets Toki tell "the same account, rotated" from "a different account",
        // which is the difference between a safe sync-back and destroying an account's
        // only refresh token.
        .target(
            name: "TokiAccounts",
            dependencies: ["TokiLogging", "TokiModels", "TokiKeychain"]
        ),

        // The mutation side of multi-account: Claude Code's own lock protocol, a
        // credential writer that issues byte-identical `security` commands to the ones
        // Claude Code issues (any other writer would change the item's ACL partition and
        // make Claude Code itself start prompting), the config splice, the swap
        // transaction, and the refresher that keeps sleeping accounts alive.
        .target(
            name: "TokiSwap",
            dependencies: ["TokiLogging", "TokiModels", "TokiKeychain", "TokiAccounts"]
        ),

        // Pure decision layer: when is an automatic account swap worth making.
        .target(
            name: "TokiAutoSwap",
            dependencies: ["TokiLogging", "TokiModels"]
        ),

        // Decides which rate-limit threshold alerts to send: the rules the user configured,
        // the settings that gate every notification Toki sends, and the pure policy that
        // fires once and re-arms honestly. Depends on TokiModels (for WindowSelector) + TokiLogging.
        .target(
            name: "TokiAlerts",
            dependencies: ["TokiLogging", "TokiModels"]
        ),

        // Anthropic's public status page (status.claude.com), reduced to one question: is
        // Claude Code okay right now? Models, the Statuspage parser, the ETag poll client,
        // the cadence rule and the once-per-episode alert policy. No deps beyond TokiLogging — the
        // whole feature is decidable from the two JSON payloads alone, which is what keeps
        // every rule here assertable in `swift test`.
        .target(
            name: "TokiStatus",
            dependencies: ["TokiLogging"]
        ),

        // Design tokens (colour, contrast arithmetic) as plain testable data. NO
        // dependencies and must NOT import SwiftUI/AppKit — that is what makes contrast
        // assertable in `swift test` instead of only eyeballed in Xcode. Deliberately not
        // part of the `TokiCore` umbrella: wiring the app to these tokens is a later wave.
        .target(
            name: "TokiDesign"
        ),

        // The configurable, ordered menu-bar indicator list: which rate-limit windows are
        // shown, in what order, how each is drawn, and how the list degrades when data is
        // missing. Pure decision layer so `swift test` can reach the resolution rules —
        // `App/Sources` only draws what `MenuBarLayout.resolve` hands it. Depends on
        // TokiModels/TokiLogging and deliberately not part of the `TokiCore` umbrella, matching
        // TokiDesign: wiring the app to it is a later wave.
        .target(
            name: "TokiMenuBar",
            dependencies: ["TokiLogging", "TokiModels"]
        ),

        // Hand-run performance harness (see Benchmarks/AnalyticsBench). Kept out of the
        // app and out of the test suite: it reports timings rather than asserting.
        .executableTarget(
            name: "AnalyticsBench",
            dependencies: ["TokiModels", "TokiTranscripts", "TokiAnalytics", "TokiPricing"],
            path: "Benchmarks/AnalyticsBench",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // Hand-run indexing harness (see Benchmarks/IndexBench): cold build and warm
        // catch-up of the real transcript archive into a scratch database.
        .executableTarget(
            name: "IndexBench",
            dependencies: ["TokiTranscripts"],
            path: "Benchmarks/IndexBench"
        ),

        // Deterministic named mock-data scenarios (fresh/multi-account/near-limit/…), shared
        // by the snapshot harness, a debug control channel, and tests. Dev-only: intentionally
        // NOT a dependency of the TokiCore umbrella target, so it never ships inside the app.
        .target(
            name: "TokiFixtures",
            dependencies: ["TokiModels", "TokiAccounts", "TokiAnalytics", "TokiStatus"]
        ),

        // MARK: - Test targets

        .testTarget(
            name: "TokiLoggingTests",
            dependencies: ["TokiLogging"]
        ),

        .testTarget(
            name: "TokiModelsTests",
            dependencies: ["TokiModels"]
        ),

        .testTarget(
            name: "TokiKeychainTests",
            dependencies: ["TokiKeychain"]
        ),

        .testTarget(
            name: "TokiLimitsTests",
            dependencies: ["TokiLimits"]
        ),

        .testTarget(
            name: "TokiPricingTests",
            dependencies: ["TokiPricing"]
        ),

        .testTarget(
            name: "TokiTranscriptsTests",
            dependencies: ["TokiTranscripts"]
        ),

        .testTarget(
            name: "TokiAnalyticsTests",
            dependencies: ["TokiAnalytics"]
        ),

        .testTarget(
            name: "TokiEnvironmentTests",
            dependencies: ["TokiEnvironment"]
        ),

        .testTarget(
            name: "TokiProcessesTests",
            dependencies: ["TokiProcesses"]
        ),

        .testTarget(
            name: "TokiOnboardingTests",
            dependencies: ["TokiOnboarding"]
        ),

        .testTarget(
            name: "TokiAccountTests",
            dependencies: ["TokiAccount"]
        ),

        .testTarget(
            name: "TokiAccountsTests",
            dependencies: ["TokiAccounts"]
        ),

        .testTarget(
            name: "TokiSwapTests",
            dependencies: ["TokiSwap"]
        ),

        .testTarget(
            name: "TokiAutoSwapTests",
            dependencies: ["TokiAutoSwap"]
        ),

        .testTarget(
            name: "TokiFixturesTests",
            dependencies: ["TokiFixtures"]
        ),

        .testTarget(
            name: "TokiDesignTests",
            dependencies: ["TokiDesign"]
        ),

        .testTarget(
            name: "TokiMenuBarTests",
            dependencies: ["TokiMenuBar"]
        ),

        .testTarget(
            name: "TokiAlertsTests",
            dependencies: ["TokiAlerts"]
        ),

        .testTarget(
            name: "TokiStatusTests",
            dependencies: ["TokiStatus"]
        ),
    ]
)
