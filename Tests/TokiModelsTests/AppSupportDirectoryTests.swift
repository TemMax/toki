import Testing
import Foundation
@testable import TokiModels

/// `resolve` is what every durable store (activity rollup, limits cache, price history,
/// transcript index) calls to find its directory, on every launch — so it has to create
/// the directory when it is missing and leave it alone when it is not.
@Suite("AppSupportDirectory")
struct AppSupportDirectoryTests {

    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("appsupport-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test("a fresh install gets the directory created")
    func createsDirectoryOnFreshInstall() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let resolved = AppSupportDirectory.resolve(base: base)

        #expect(resolved.lastPathComponent == "Toki")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("resolving again returns the same directory and keeps what is already in it")
    func resolvingTwiceIsIdempotent() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let first = AppSupportDirectory.resolve(base: base)
        try Data("rollup".utf8).write(to: first.appendingPathComponent("stats-rollup.json"))

        let second = AppSupportDirectory.resolve(base: base)

        #expect(second == first)
        #expect(
            try String(contentsOf: second.appendingPathComponent("stats-rollup.json"),
                       encoding: .utf8) == "rollup"
        )
    }
}
