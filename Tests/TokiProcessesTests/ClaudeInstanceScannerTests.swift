import Testing
import Foundation
@testable import TokiProcesses
import TokiModels

/// Fake enumerator: returns a fixed fixture list.
private struct FakeEnumerator: ProcessEnumerating {
    let processes: [RawProcess]
    func enumerate() -> [RawProcess] { processes }
}

private func scanner(_ processes: [RawProcess], reference: String? = nil) -> ClaudeInstanceScanner {
    ClaudeInstanceScanner(enumerator: FakeEnumerator(processes: processes), referenceVersion: { reference })
}

private func bothProviderScanner(_ processes: [RawProcess]) -> ClaudeInstanceScanner {
    ClaudeInstanceScanner(
        enumerator: FakeEnumerator(processes: processes),
        referenceVersion: { "2.1.197" },
        includeClaude: true,
        includeCodex: true
    )
}

@Suite("ClaudeInstanceScanner")
struct ClaudeInstanceScannerTests {

    @Test("empty enumerator yields empty snapshot")
    func emptyEnumeratorYieldsEmpty() async {
        let snapshot = await scanner([]).loadInstances()
        #expect(snapshot.instances.isEmpty)
        #expect(snapshot.referenceVersion == nil)
    }

    @Test("native install: source .native, version parsed")
    func nativeInstall() async {
        let path = "/Users/me/.local/share/claude/versions/2.1.197"
        let snapshot = await scanner([RawProcess(pid: 100, executablePath: path)]).loadInstances()
        #expect(snapshot.instances.count == 1)
        let inst = snapshot.instances[0]
        #expect(inst.source == .native)
        #expect(inst.version == "2.1.197")
        #expect(inst.pid == 100)
    }

    @Test("managed Conductor install: source .managed, version parsed")
    func managedInstall() async {
        let path = "/Users/me/Library/Application Support/com.conductor.app/agent-binaries/claude/2.1.190/claude"
        let snapshot = await scanner([RawProcess(pid: 200, executablePath: path)]).loadInstances()
        #expect(snapshot.instances.count == 1)
        let inst = snapshot.instances[0]
        #expect(inst.source == .managed)
        #expect(inst.version == "2.1.190")
    }

    @Test("unknown-location claude still detected")
    func unknownLocationDetected() async {
        // Has /claude/ segment and a semver component and basename "claude",
        // but neither native nor managed marker.
        let path = "/opt/custom/claude/2.1.100/claude"
        let snapshot = await scanner([RawProcess(pid: 250, executablePath: path)]).loadInstances()
        #expect(snapshot.instances.count == 1)
        #expect(snapshot.instances[0].source == .unknown)
        #expect(snapshot.instances[0].version == "2.1.100")
    }

    @Test("excludes node child, desktop app, shell, and unrelated binary")
    func exclusions() async {
        let processes = [
            // MCP-server child running as node — must NOT match.
            RawProcess(pid: 1, executablePath: "/opt/homebrew/Cellar/node/24.0.0/bin/node"),
            // node under a claude versions dir — still excluded (basename not claude/semver).
            RawProcess(pid: 2, executablePath: "/Users/me/.local/share/claude/versions/2.1.197/node"),
            // Desktop app.
            RawProcess(pid: 3, executablePath: "/Applications/Claude.app/Contents/MacOS/Claude"),
            // Shell.
            RawProcess(pid: 4, executablePath: "/bin/zsh"),
            // Random unrelated binary.
            RawProcess(pid: 5, executablePath: "/usr/bin/ssh"),
        ]
        let snapshot = await scanner(processes).loadInstances()
        #expect(snapshot.instances.isEmpty)
    }

    @Test("carries cwd, pid, startedAt, memoryBytes through")
    func carriesFactsThrough() async {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let raw = RawProcess(
            pid: 4242,
            executablePath: "/Users/me/.local/share/claude/versions/2.1.197",
            workingDirectory: "/Users/me/Developer/myproject",
            startedAt: start,
            memoryBytes: 123_456_789
        )
        let snapshot = await scanner([raw]).loadInstances()
        #expect(snapshot.instances.count == 1)
        let inst = snapshot.instances[0]
        #expect(inst.pid == 4242)
        #expect(inst.workingDirectory == "/Users/me/Developer/myproject")
        #expect(inst.projectName == "myproject")
        #expect(inst.startedAt == start)
        #expect(inst.memoryBytes == 123_456_789)
    }

    @Test("isOutdated relative to reference version")
    func outdatedComparison() async {
        let older = RawProcess(pid: 1, executablePath: "/Users/me/.local/share/claude/versions/2.1.195")
        let current = RawProcess(pid: 2, executablePath: "/Users/me/.local/share/claude/versions/2.1.197")
        let snapshot = await scanner([older, current], reference: "2.1.197").loadInstances()
        #expect(snapshot.referenceVersion == "2.1.197")
        let byPid = Dictionary(uniqueKeysWithValues: snapshot.instances.map { ($0.pid, $0) })
        #expect(byPid[1]?.isOutdated == true)
        #expect(byPid[2]?.isOutdated == false)
    }

    @Test("no reference version → nothing outdated")
    func noReferenceNothingOutdated() async {
        let older = RawProcess(pid: 1, executablePath: "/Users/me/.local/share/claude/versions/2.1.195")
        let current = RawProcess(pid: 2, executablePath: "/Users/me/.local/share/claude/versions/2.1.197")
        let snapshot = await scanner([older, current], reference: nil).loadInstances()
        #expect(snapshot.referenceVersion == nil)
        #expect(snapshot.instances.allSatisfy { !$0.isOutdated })
    }

    @Test("dedup by pid")
    func dedupByPid() async {
        let a = RawProcess(pid: 7, executablePath: "/Users/me/.local/share/claude/versions/2.1.197")
        let b = RawProcess(pid: 7, executablePath: "/Users/me/.local/share/claude/versions/2.1.196")
        let snapshot = await scanner([a, b]).loadInstances()
        #expect(snapshot.instances.count == 1)
        #expect(snapshot.instances[0].pid == 7)
    }

    @Test("Codex and Claude are detected independently and only Claude uses its update badge")
    func detectsBothProviders() async {
        let snapshot = await bothProviderScanner([
            RawProcess(
                pid: 10,
                executablePath: "/Users/me/.codex/packages/standalone/releases/0.153.2-aarch64-apple-darwin/bin/codex"
            ),
            RawProcess(
                pid: 11,
                executablePath: "/Users/me/.local/share/claude/versions/2.1.190"
            ),
        ]).loadInstances()
        let byPID = Dictionary(uniqueKeysWithValues: snapshot.instances.map { ($0.pid, $0) })
        #expect(byPID[10]?.provider == .codex)
        #expect(byPID[10]?.version == "0.153.2-aarch64-apple-darwin")
        #expect(byPID[10]?.isOutdated == false)
        #expect(byPID[11]?.provider == .claudeCode)
        #expect(byPID[11]?.isOutdated == true)
    }
}

@Suite("Semver")
struct SemverTests {

    @Test("numeric-order compare, not lexical (2.1.9 < 2.1.10)")
    func numericOrder() {
        #expect(Semver.less("2.1.9", "2.1.10") == true)
        #expect(Semver.less("2.1.10", "2.1.9") == false)
    }

    @Test("equal versions are not less")
    func equalNotLess() {
        #expect(Semver.less("2.1.197", "2.1.197") == false)
    }

    @Test("garbage / unparseable → false")
    func garbageFalse() {
        #expect(Semver.less("unknown", "2.1.197") == false)
        #expect(Semver.less("2.1.197", "unknown") == false)
        #expect(Semver.less("", "") == false)
    }

    @Test("pre-release suffix ignored for ordering")
    func prereleaseSuffix() {
        // 2.1.0-beta parses to [2,1,0]; equal numeric parts → not less.
        #expect(Semver.less("2.1.0-beta", "2.1.0") == false)
        #expect(Semver.less("2.1.0", "2.1.1-rc1") == true)
    }

    @Test("leading v stripped")
    func leadingV() {
        #expect(Semver.components("v2.1.197") == [2, 1, 197])
    }

    @Test("zero-padding for uneven lengths")
    func zeroPadding() {
        #expect(Semver.less("2.1", "2.1.0") == false)
        #expect(Semver.less("2.1", "2.1.1") == true)
    }

    @Test("versionComponent extracts from path")
    func versionComponentFromPath() {
        #expect(Semver.versionComponent(in: "/a/b/claude/versions/2.1.197") == "2.1.197")
        #expect(Semver.versionComponent(in: "/a/b/claude/2.1.190/claude") == "2.1.190")
        #expect(Semver.versionComponent(in: "/no/version/here") == nil)
    }

    @Test("normalizedVersion requires major.minor.patch")
    func normalizedVersionShape() {
        #expect(Semver.normalizedVersion("2.1.197") == "2.1.197")
        #expect(Semver.normalizedVersion("v2.1.197") == "2.1.197")
        #expect(Semver.normalizedVersion("2.1.0-rc1") == "2.1.0-rc1")
        #expect(Semver.normalizedVersion("2.1") == nil)
        #expect(Semver.normalizedVersion("claude") == nil)
    }
}
