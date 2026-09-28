import Foundation
import Testing
@testable import TokiEnvironment

@Suite("Provider availability")
struct ProviderAvailabilityTests {
    @Test("detects explicit Claude and Codex executables")
    func detectsOverrides() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-availability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let claude = try executable(named: "custom-claude", in: root)
        let codex = try executable(named: "custom-codex", in: root)
        let availability = ProviderAvailability.detected(
            environment: [
                "TOKI_CLAUDE_EXECUTABLE": claude.path,
                "TOKI_CODEX_EXECUTABLE": codex.path,
                "PATH": "/missing",
            ],
            homeDirectory: root
        )

        #expect(availability == .all)
    }

    @Test("detects Conductor-managed binaries outside PATH")
    func detectsConductorManagedBinaries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-availability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let managed = root.appendingPathComponent(
            "Library/Application Support/com.conductor.app/agent-binaries"
        )
        let claude = try executable(named: "claude", in: managed.appendingPathComponent("claude/2.1.0"))
        let codex = try executable(named: "codex", in: managed.appendingPathComponent("codex/0.100.0"))

        #expect(FileManager.default.isExecutableFile(atPath: claude.path))
        #expect(FileManager.default.isExecutableFile(atPath: codex.path))
        #expect(ProviderExecutableResolver.claudeCode(
            environment: ["PATH": "/missing"], homeDirectory: root
        )?.resolvingSymlinksInPath() == claude.resolvingSymlinksInPath())
        #expect(ProviderExecutableResolver.codex(
            environment: ["PATH": "/missing"], homeDirectory: root
        )?.resolvingSymlinksInPath() == codex.resolvingSymlinksInPath())

        let availability = ProviderAvailability.detected(
            environment: ["PATH": "/missing"],
            homeDirectory: root
        )

        #expect(availability == .all)
    }

    private func executable(named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
