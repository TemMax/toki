import Foundation
import Testing
import TokiModels
@testable import TokiLimits

private let multiBucketResponse = """
{
  "rateLimits": {
    "limitId": "codex",
    "limitName": null,
    "planType": "pro",
    "primary": {
      "usedPercent": 24,
      "windowDurationMins": 10080,
      "resetsAt": 1788541200
    },
    "secondary": null
  },
  "rateLimitsByLimitId": {
    "codex_bengalfox": {
      "limitId": "codex_bengalfox",
      "limitName": "GPT-5.3-Codex-Spark",
      "planType": "pro",
      "primary": {
        "usedPercent": 135,
        "windowDurationMins": 300,
        "resetsAt": 1788501600
      },
      "secondary": {
        "usedPercent": -5,
        "windowDurationMins": 10080,
        "resetsAt": 1788541200
      }
    },
    "codex": {
      "limitId": "codex",
      "limitName": null,
      "planType": "pro",
      "primary": {
        "usedPercent": 24,
        "windowDurationMins": 10080,
        "resetsAt": 1788541200
      },
      "secondary": null
    }
  }
}
"""

private let bankedResetResponse = """
{
  "accountId": "account-123",
  "rateLimits": {
    "limitId": "codex",
    "limitName": null,
    "primary": {
      "usedPercent": 24,
      "windowDurationMins": 300,
      "resetsAt": 1788541200
    },
    "secondary": null
  },
  "rateLimitResetCredits": {
    "availableCount": 2,
    "credits": [
      {
        "id": "credit-1",
        "grantedAt": 1788581903,
        "expiresAt": 1791173903,
        "status": "available",
        "resetType": "codexRateLimits"
      },
      {
        "id": "credit-2",
        "grantedAt": 1788582000,
        "expiresAt": null,
        "status": "available",
        "resetType": "codexRateLimits"
      }
    ]
  }
}
"""

@Suite("Codex limits")
struct CodexLimitsTests {
    @Test("account/read maps the non-secret ChatGPT identity fields")
    func mapsAccountRead() throws {
        let result = try CodexAccountMapper.map(resultData: Data(
            #"{"account":{"type":"chatgpt","email":"dev@example.com","planType":"pro"}}"#.utf8
        ))

        #expect(result == CodexAccountInfo(
            type: "chatgpt",
            email: "dev@example.com",
            planType: "pro"
        ))
    }

    @Test("account/read with no account is a signed-out state")
    func rejectsMissingAccount() {
        #expect(throws: CodexLimitsError.notLoggedIn) {
            try CodexAccountMapper.map(resultData: Data(#"{"account":null}"#.utf8))
        }
    }

    @Test("multi-bucket response maps general and model windows in stable order")
    func mapsMultiBucketResponse() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let limits = try CodexRateLimitsMapper.map(
            resultData: Data(multiBucketResponse.utf8),
            fetchedAt: fetchedAt
        )

        #expect(limits.fetchedAt == fetchedAt)
        #expect(limits.extra == nil)
        #expect(limits.windows.map(\.id) == [
            "weekly_all",
            "session_scoped:GPT-5.3 Codex Spark",
            "weekly_scoped:GPT-5.3 Codex Spark",
        ])
        #expect(limits.windows.map(\.title) == [
            "7-day",
            "5-hour · GPT-5.3 Codex Spark",
            "7-day · GPT-5.3 Codex Spark",
        ])
        #expect(limits.windows.map(\.utilization) == [0.24, 1, 0])
        #expect(limits.windows[0].resetsAt == Date(timeIntervalSince1970: 1_788_541_200))
    }

    @Test("same response maps account identity and banked reset Unix timestamps")
    func mapsBankedResets() throws {
        let limits = try CodexRateLimitsMapper.map(resultData: Data(bankedResetResponse.utf8))

        #expect(limits.account == UsageAccount(
            accountUuid: "account-123",
            organizationUuid: nil
        ))
        #expect(limits.bankedResets?.availableCount == 2)
        #expect(limits.bankedResets?.credits?.count == 2)
        #expect(limits.bankedResets?.credits?[0] == BankedResetCredit(
            id: "credit-1",
            grantedAt: Date(timeIntervalSince1970: 1_788_581_903),
            expiresAt: Date(timeIntervalSince1970: 1_791_173_903),
            status: "available",
            resetType: "codexRateLimits"
        ))
        #expect(limits.bankedResets?.credits?[1].expiresAt == nil)
    }

    @Test("null credit details preserve the authoritative available count")
    func mapsCountWithoutCreditDetails() throws {
        let body = bankedResetResponse.replacingOccurrences(
            of: #""credits": ["#,
            with: #""creditsIgnored": ["#
        ).replacingOccurrences(
            of: #""availableCount": 2,"#,
            with: #""availableCount": 2, "credits": null,"#
        )

        let limits = try CodexRateLimitsMapper.map(resultData: Data(body.utf8))

        #expect(limits.bankedResets == BankedResets(availableCount: 2, credits: nil))
    }

    @Test("malformed reset metadata does not discard valid ordinary usage")
    func malformedResetMetadataIsIsolated() throws {
        let body = bankedResetResponse.replacingOccurrences(
            of: #""availableCount": 2"#,
            with: #""availableCount": "two""#
        )

        let limits = try CodexRateLimitsMapper.map(resultData: Data(body.utf8))

        #expect(limits.windows.map(\.id) == ["session"])
        #expect(limits.account?.accountUuid == "account-123")
        #expect(limits.bankedResets == nil)
    }

    @Test("negative reset count is unknown rather than zero")
    func rejectsNegativeResetCount() throws {
        let body = bankedResetResponse.replacingOccurrences(
            of: #""availableCount": 2"#,
            with: #""availableCount": -1"#
        )

        let limits = try CodexRateLimitsMapper.map(resultData: Data(body.utf8))

        #expect(limits.bankedResets == nil)
    }

    @Test("legacy single bucket is used when the multi-bucket map is absent")
    func mapsSingleBucketResponse() throws {
        let body = """
        {
          "rateLimits": {
            "limitId": "codex",
            "limitName": null,
            "primary": { "usedPercent": 50, "windowDurationMins": 60, "resetsAt": null },
            "secondary": null
          }
        }
        """

        let limits = try CodexRateLimitsMapper.map(resultData: Data(body.utf8))

        #expect(limits.windows.count == 1)
        #expect(limits.windows[0].title == "1-hour")
        #expect(limits.windows[0].utilization == 0.5)
        #expect(limits.windows[0].resetsAt == nil)
    }

    @Test("response with no windows fails instead of replacing cached data")
    func rejectsEmptyResponse() {
        let body = """
        { "rateLimits": { "limitId": "codex", "primary": null, "secondary": null } }
        """

        #expect(throws: CodexLimitsError.invalidResponse("no rate-limit windows")) {
            try CodexRateLimitsMapper.map(resultData: Data(body.utf8))
        }
    }

    @Test("executable override takes priority over PATH")
    func resolverHonorsOverride() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("custom-codex")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        let result = CodexExecutableResolver.resolve(
            environment: ["TOKI_CODEX_EXECUTABLE": executable.path, "PATH": "/missing"],
            homeDirectory: root
        )

        #expect(result?.standardizedFileURL == executable.standardizedFileURL)
    }
}
