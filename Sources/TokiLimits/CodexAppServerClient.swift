/// Reads ChatGPT-plan Codex rate limits through the official Codex App Server protocol.
import Darwin
import Foundation
import TokiEnvironment
import TokiLogging
import TokiModels

// MARK: - Errors

public enum CodexLimitsError: Error, Sendable, Equatable {
    case executableNotFound
    case launchFailed
    case timedOut
    case serverExited(Int32)
    case rpc(Int)
    case notLoggedIn
    case invalidResponse(String)
}

extension CodexLimitsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Codex CLI was not found. Install Codex or set TOKI_CODEX_EXECUTABLE."
        case .launchFailed:
            return "Codex App Server could not be started."
        case .timedOut:
            return "Codex App Server did not respond in time."
        case let .serverExited(status):
            return "Codex App Server exited with status \(status)."
        case let .rpc(code):
            return "Codex App Server rejected the request (\(code))."
        case .notLoggedIn:
            return "Codex is not signed in with ChatGPT."
        case let .invalidResponse(detail):
            return "Codex returned an invalid response: \(detail)"
        }
    }
}

// MARK: - Executable discovery

/// Compatibility shim for the transport's tests. Discovery itself lives in
/// `TokiEnvironment`, where the UI uses the exact same rule to decide whether Codex exists.
enum CodexExecutableResolver {
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        ProviderExecutableResolver.codex(
            environment: environment,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
    }
}

// MARK: - Wire DTOs

private struct WireCodexWindow: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int?
}

private struct WireCodexSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let planType: String?
    let primary: WireCodexWindow?
    let secondary: WireCodexWindow?
}

private struct WireBankedResetCredit: Decodable {
    let id: String
    let grantedAt: Int
    let expiresAt: Int?
    let status: String
    let resetType: String
}

private struct WireBankedResets: Decodable {
    let availableCount: Int
    let credits: [WireBankedResetCredit]?

    private enum CodingKeys: String, CodingKey {
        case availableCount
        case credits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try container.decode(Int.self, forKey: .availableCount)
        // Details are explicitly optional and may evolve independently of the count. A bad
        // row must not erase an otherwise valid authoritative count.
        do {
            credits = try container.decodeIfPresent(
                [WireBankedResetCredit].self,
                forKey: .credits
            )
        } catch {
            TokiLog.logger("codex-limits").debug(
                "Codex reset credit details unavailable \(error: error)"
            )
            credits = nil
        }
    }
}

private struct WireCodexRateLimitsResponse: Decodable {
    let rateLimits: WireCodexSnapshot
    let rateLimitsByLimitId: [String: WireCodexSnapshot]?
    let accountId: String?
    let rateLimitResetCredits: WireBankedResets?

    private enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitId
        case accountId
        case rateLimitResetCredits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimits = try container.decode(WireCodexSnapshot.self, forKey: .rateLimits)
        rateLimitsByLimitId = try container.decodeIfPresent(
            [String: WireCodexSnapshot].self,
            forKey: .rateLimitsByLimitId
        )
        do {
            accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        } catch {
            TokiLog.logger("codex-limits").debug(
                "Codex usage account identity unavailable \(error: error)"
            )
            accountId = nil
        }
        // Reset-credit metadata is additive. Old, absent, or malformed metadata must never
        // make the ordinary rate-limit snapshot unusable.
        do {
            rateLimitResetCredits = try container.decodeIfPresent(
                WireBankedResets.self,
                forKey: .rateLimitResetCredits
            )
        } catch {
            TokiLog.logger("codex-limits").debug(
                "Codex reset credit summary unavailable \(error: error)"
            )
            rateLimitResetCredits = nil
        }
    }
}

private struct WireCodexAccount: Decodable {
    let type: String
    let email: String?
    let planType: String?
}

private struct WireCodexAccountReadResponse: Decodable {
    let account: WireCodexAccount?
}

/// Non-secret identity fields returned by App Server's official `account/read` method.
public struct CodexAccountInfo: Equatable, Sendable {
    public let type: String
    public let email: String?
    public let planType: String?

    public init(type: String, email: String?, planType: String?) {
        self.type = type
        self.email = email
        self.planType = planType
    }
}

enum CodexAccountMapper {
    static func map(resultData: Data) throws -> CodexAccountInfo {
        let response: WireCodexAccountReadResponse
        switch Result(catching: {
            try JSONDecoder().decode(WireCodexAccountReadResponse.self, from: resultData)
        }) {
        case let .success(decoded):
            response = decoded
        case let .failure(error):
            throw CodexLimitsError.invalidResponse(decodingDiagnostic(error))
        }
        guard let account = response.account else { throw CodexLimitsError.notLoggedIn }
        return CodexAccountInfo(
            type: account.type,
            email: account.email,
            planType: account.planType
        )
    }
}

/// Pure mapping kept separate from the subprocess transport so schema behavior stays easy
/// to test with captured JSON and never requires a real Codex installation in `swift test`.
enum CodexRateLimitsMapper {
    static func map(resultData: Data, fetchedAt: Date = Date()) throws -> UsageLimits {
        let response: WireCodexRateLimitsResponse
        switch Result(catching: {
            try JSONDecoder().decode(WireCodexRateLimitsResponse.self, from: resultData)
        }) {
        case let .success(decoded):
            response = decoded
        case let .failure(error):
            throw CodexLimitsError.invalidResponse(decodingDiagnostic(error))
        }

        let buckets: [(key: String, snapshot: WireCodexSnapshot)]
        if let byID = response.rateLimitsByLimitId, !byID.isEmpty {
            buckets = byID.map { (key: $0.key, snapshot: $0.value) }.sorted {
                let leftGeneral = $0.key == "codex"
                let rightGeneral = $1.key == "codex"
                if leftGeneral != rightGeneral { return leftGeneral }
                let leftName = $0.snapshot.limitName ?? $0.key
                let rightName = $1.snapshot.limitName ?? $1.key
                return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
            }
        } else {
            buckets = [(response.rateLimits.limitId ?? "codex", response.rateLimits)]
        }

        var windows: [RateLimitWindow] = []
        for bucket in buckets {
            let limitID = bucket.snapshot.limitId ?? bucket.key
            let modelName = displayName(for: bucket.snapshot, key: bucket.key)
            let candidates: [(role: String, window: WireCodexWindow?)] = [
                ("primary", bucket.snapshot.primary),
                ("secondary", bucket.snapshot.secondary),
            ]

            for candidate in candidates {
                guard let window = candidate.window else { continue }
                let duration = durationTitle(minutes: window.windowDurationMins, role: candidate.role)
                let title = modelName.map { "\(duration) · \($0)" } ?? duration
                windows.append(RateLimitWindow(
                    id: semanticID(
                        limitID: limitID,
                        modelName: modelName,
                        durationMinutes: window.windowDurationMins,
                        role: candidate.role
                    ),
                    title: title,
                    utilization: min(max(Double(window.usedPercent) / 100, 0), 1),
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    isAvailable: true
                ))
            }
        }

        guard !windows.isEmpty else {
            throw CodexLimitsError.invalidResponse("no rate-limit windows")
        }
        let bankedResets = response.rateLimitResetCredits.flatMap { summary -> BankedResets? in
            guard summary.availableCount >= 0 else { return nil }
            return BankedResets(
                availableCount: summary.availableCount,
                credits: summary.credits?.map { credit in
                    BankedResetCredit(
                        id: credit.id,
                        grantedAt: Date(timeIntervalSince1970: TimeInterval(credit.grantedAt)),
                        expiresAt: credit.expiresAt.map {
                            Date(timeIntervalSince1970: TimeInterval($0))
                        },
                        status: credit.status,
                        resetType: credit.resetType
                    )
                }
            )
        }
        let account = response.accountId.map {
            UsageAccount(accountUuid: $0, organizationUuid: nil)
        }
        return UsageLimits(
            windows: windows,
            extra: nil,
            fetchedAt: fetchedAt,
            account: account,
            bankedResets: bankedResets
        )
    }

    private static func displayName(for snapshot: WireCodexSnapshot, key: String) -> String? {
        guard let raw = snapshot.limitName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.caseInsensitiveCompare("codex") != .orderedSame else {
            return nil
        }
        return DisplayFormat.openAIModelName(raw)
    }

    private static func durationTitle(minutes: Int?, role: String) -> String {
        guard let minutes, minutes > 0 else {
            return role == "primary" ? "Primary" : "Secondary"
        }
        if minutes.isMultiple(of: 1_440) {
            let days = minutes / 1_440
            return "\(days)-day"
        }
        if minutes.isMultiple(of: 60) {
            let hours = minutes / 60
            return "\(hours)-hour"
        }
        return "\(minutes)-minute"
    }

    /// Reuses Toki's semantic window ids so every existing feature (menu-bar rules,
    /// threshold alerts and auto-swap) can address Codex without knowing App Server's
    /// primary/secondary bucket vocabulary.
    private static func semanticID(
        limitID: String,
        modelName: String?,
        durationMinutes: Int?,
        role: String
    ) -> String {
        if let modelName {
            if durationMinutes == 10_080 { return "weekly_scoped:\(modelName)" }
            if durationMinutes == 300 { return "session_scoped:\(modelName)" }
        } else {
            if durationMinutes == 300 { return "session" }
            if durationMinutes == 10_080 { return "weekly_all" }
        }
        return "codex:\(limitID):\(role)"
    }
}

// MARK: - JSONL transport

/// A small, bounded client for the JSONL protocol exposed by `codex app-server --stdio`.
/// Authentication stays owned by Codex: Toki neither reads nor refreshes Codex OAuth tokens.
public struct CodexAppServerClient: Sendable {
    private let executableURL: URL?
    private let initializeTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let log = TokiLog.logger("codex-limits")

    public init(
        executableURL: URL? = nil,
        initializeTimeout: TimeInterval = 8,
        requestTimeout: TimeInterval = 5
    ) {
        self.executableURL = executableURL
        self.initializeTimeout = initializeTimeout
        self.requestTimeout = requestTimeout
    }

    public func fetchUsage() async throws -> UsageLimits {
        try await fetchUsage(codexHome: nil)
    }

    /// Reads one saved profile without changing the user's live Codex login. The caller
    /// supplies a private temporary home containing only that profile's auth.json.
    public func fetchUsage(codexHome: URL?) async throws -> UsageLimits {
        let resolved = executableURL ?? CodexExecutableResolver.resolve()
        guard let resolved else { throw CodexLimitsError.executableNotFound }
        let initializeTimeout = self.initializeTimeout
        let requestTimeout = self.requestTimeout

        do {
            return try await Task.detached(priority: .utility) {
                let result = try Self.requestSynchronously(
                    executableURL: resolved,
                    initializeTimeout: initializeTimeout,
                    requestTimeout: requestTimeout,
                    method: "account/rateLimits/read",
                    codexHome: codexHome
                )
                let resultData = try JSONSerialization.data(withJSONObject: result)
                return try CodexRateLimitsMapper.map(resultData: resultData)
            }.value
        } catch {
            log.error("Codex App Server usage read failed \(error: error)")
            throw error
        }
    }

    public func fetchAccountInfo() async throws -> CodexAccountInfo {
        let resolved = executableURL ?? CodexExecutableResolver.resolve()
        guard let resolved else { throw CodexLimitsError.executableNotFound }
        let initializeTimeout = self.initializeTimeout
        let requestTimeout = self.requestTimeout

        do {
            return try await Task.detached(priority: .utility) {
                let result = try Self.requestSynchronously(
                    executableURL: resolved,
                    initializeTimeout: initializeTimeout,
                    requestTimeout: requestTimeout,
                    method: "account/read",
                    params: ["refreshToken": false]
                )
                let data = try JSONSerialization.data(withJSONObject: result)
                return try CodexAccountMapper.map(resultData: data)
            }.value
        } catch {
            log.error("Codex App Server account read failed \(error: error)")
            throw error
        }
    }

    private static func requestSynchronously(
        executableURL: URL,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        method: String,
        params: [String: Any] = [:],
        codexHome: URL? = nil
    ) throws -> Any {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-s", "read-only", "-a", "never", "app-server", "--stdio"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        if let codexHome {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = codexHome.path
            process.environment = environment
        }

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        if case .failure = Result(catching: { try process.run() }) {
            throw CodexLimitsError.launchFailed
        }

        defer {
            do {
                try input.fileHandleForWriting.close()
            } catch {
                TokiLog.logger("codex-limits").debug(
                    "Closing Codex App Server stdin failed \(error: error)"
                )
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let writer = input.fileHandleForWriting
        var reader = JSONLineReader(handle: output.fileHandleForReading, process: process)

        try writeJSON([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "toki", "version": "1.0"],
            ],
        ], to: writer)
        _ = try readResult(id: 1, timeout: initializeTimeout, reader: &reader)

        try writeJSON(["method": "initialized", "params": [:]], to: writer)
        try writeJSON([
            "id": 2,
            "method": method,
            "params": params,
        ], to: writer)

        return try readResult(id: 2, timeout: requestTimeout, reader: &reader)
    }

    private static func writeJSON(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func readResult(
        id: Int,
        timeout: TimeInterval,
        reader: inout JSONLineReader
    ) throws -> Any {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let line = try reader.nextLine(deadline: deadline)
            guard case let .success(decoded) = Result(catching: {
                      try JSONSerialization.jsonObject(with: line)
                  }),
                  let object = decoded as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == id else {
                // Notifications and non-protocol stdout are unrelated to this request.
                continue
            }

            if let error = object["error"] as? [String: Any] {
                let code = (error["code"] as? NSNumber)?.intValue ?? -1
                let message = (error["message"] as? String)?.lowercased() ?? ""
                if message.contains("login") || message.contains("auth") || message.contains("account") {
                    throw CodexLimitsError.notLoggedIn
                }
                throw CodexLimitsError.rpc(code)
            }
            guard let result = object["result"] else {
                throw CodexLimitsError.invalidResponse("missing result")
            }
            return result
        }
    }
}

/// Synchronous poll-based reader used from the client's detached task. It avoids a
/// permanently-blocked `readDataToEndOfFile()` because App Server remains alive until EOF.
private struct JSONLineReader {
    private static let maximumBufferSize = 1_048_576

    let handle: FileHandle
    let process: Process
    var buffer = Data()

    mutating func nextLine(deadline: Date) throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.last == 0x0D { line.removeLast() }
                if !line.isEmpty { return line }
                continue
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexLimitsError.timedOut }

            var descriptor = pollfd(
                fd: handle.fileDescriptor,
                events: Int16(POLLIN) | Int16(POLLHUP),
                revents: 0
            )
            let milliseconds = Int32(min(max(remaining * 1_000, 1), Double(Int32.max)))
            let result = Darwin.poll(&descriptor, 1, milliseconds)
            if result == 0 { throw CodexLimitsError.timedOut }
            if result < 0 {
                if errno == EINTR { continue }
                throw CodexLimitsError.invalidResponse("stdout read failed")
            }

            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                if process.isRunning {
                    throw CodexLimitsError.invalidResponse("stdout closed")
                }
                throw CodexLimitsError.serverExited(process.terminationStatus)
            }
            buffer.append(chunk)
            guard buffer.count <= Self.maximumBufferSize else {
                throw CodexLimitsError.invalidResponse("response exceeded 1 MB")
            }
        }
    }
}
