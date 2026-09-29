import Foundation
import Testing
@testable import QuotaCore

private func json(_ string: String) -> Data { Data(string.utf8) }

@Suite struct ClaudeParserTests {
    @Test func mapsSessionWeeklyAndFableWindows() throws {
        let windows = try ClaudeParser.windows(from: json("""
        {
          "five_hour": { "used_percentage": 23.5, "resets_at": 1770000000 },
          "seven_day": { "used_percentage": 41.2, "resets_at": 1770604800 },
          "fable_weekly": { "used_percentage": 12.3, "resets_at": 1770691200 }
        }
        """))
        #expect(windows.map(\.kind) == [.session, .weekly, .weeklyModel("Fable")])
        #expect(windows[0].usedPercent == 23.5)
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_770_000_000))
        #expect(windows[2].resetsAt == Date(timeIntervalSince1970: 1_770_691_200))
    }

    @Test func prefersScopedLimitsAndParsesMicrosecondTimestamps() throws {
        let windows = try ClaudeParser.windows(from: json("""
        {
          "five_hour": { "utilization": 36, "resets_at": "2026-07-17T15:00:00.099908+00:00" },
          "seven_day": { "utilization": 73 },
          "fable_weekly": { "utilization": 12 },
          "seven_day_opus": null,
          "seven_day_oauth_apps": { "utilization": 99 },
          "limits": [
            { "kind": "weekly_scoped", "percent": 55, "scope": null },
            {
              "kind": "weekly_scoped",
              "percent": 100,
              "resets_at": "2026-07-17T20:00:00.099908+00:00",
              "scope": { "model": { "display_name": "Fable" } }
            }
          ]
        }
        """))
        #expect(windows.map(\.kind) == [.session, .weekly, .weeklyModel("Fable")])
        #expect(windows[2].usedPercent == 100)
        #expect(windows[2].resetsAt == Timestamp.iso("2026-07-17T20:00:00Z"))
        #expect(windows[0].resetsAt == Timestamp.iso("2026-07-17T15:00:00Z"))
    }

    @Test func readsCredentialsAndPlan() {
        let credentials = ClaudeParser.credentials(from: json("""
        { "claudeAiOauth": { "accessToken": "token", "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x" } }
        """))
        #expect(credentials == ClaudeCredentials(accessToken: "token", plan: "Max 20x"))
        #expect(ClaudeParser.credentials(from: json(#"{ "claudeAiOauth": {} }"#)) == nil)
        #expect(ClaudeParser.planLabel(subscriptionType: "pro", tier: nil) == "Pro")
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: ProviderIssue.invalidResponse) { try ClaudeParser.windows(from: json("<html>")) }
    }
}

@Suite struct CodexParserTests {
    @Test func classifiesWindowsByDuration() throws {
        let usage = try CodexParser.usage(from: json("""
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": { "used_percent": 37, "limit_window_seconds": 604800, "reset_at": 1800000000 },
            "secondary_window": { "used_percent": 12, "limit_window_seconds": 18000, "reset_at": 1800100000 }
          }
        }
        """))
        #expect(usage.plan == "Plus")
        #expect(usage.windows.map(\.kind) == [.session, .weekly])
        #expect(usage.windows[0].usedPercent == 12)
        #expect(usage.windows[1].resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func keepsUnknownDurationsAsCustomWindows() throws {
        let usage = try CodexParser.usage(from: json("""
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": 12, "limit_window_seconds": 3600 },
            "secondary_window": null
          }
        }
        """))
        #expect(usage.windows.map(\.kind) == [.custom(minutes: 60)])
        #expect(usage.windows[0].label == "1 h window")
    }

    @Test func mapsAppServerRateLimits() throws {
        let usage = try CodexParser.rpcUsage(from: json("""
        {
          "rateLimits": {
            "limitId": "codex",
            "primary": { "usedPercent": 0, "windowDurationMins": 43200, "resetsAt": 1791954967 },
            "secondary": null,
            "credits": { "hasCredits": false, "unlimited": false, "balance": null },
            "planType": "free"
          }
        }
        """))
        #expect(usage.plan == "Free")
        #expect(usage.windows == [UsageWindow(kind: .monthly, usedPercent: 0, resetsAt: Date(timeIntervalSince1970: 1_791_954_967))])

        let paid = try CodexParser.rpcUsage(from: json("""
        { "rateLimits": {
            "primary": { "usedPercent": 41, "windowDurationMins": 300, "resetsAt": 1800000000 },
            "secondary": { "usedPercent": 12, "windowDurationMins": 10080, "resetsAt": 1800100000 },
            "planType": "pro" } }
        """))
        #expect(paid.windows.map(\.kind) == [.session, .weekly])
        #expect(throws: ProviderIssue.invalidResponse) { try CodexParser.rpcUsage(from: json(#"{ "rateLimits": null }"#)) }
    }

    @Test func requiresPlanType() {
        #expect(throws: ProviderIssue.invalidResponse) { try CodexParser.usage(from: json(#"{ "detail": "x" }"#)) }
    }

    @Test func detectsAuthMode() {
        #expect(CodexParser.auth(from: json(#"{ "tokens": { "access_token": "a", "account_id": "acc" } }"#)) == .chatGPT(accessToken: "a", accountID: "acc"))
        #expect(CodexParser.auth(from: json(#"{ "OPENAI_API_KEY": "sk-test", "tokens": null }"#)) == .apiKey)
        #expect(CodexParser.auth(from: json(#"{ "OPENAI_API_KEY": null }"#)) == nil)
    }
}

@Suite struct GrokParserTests {
    @Test func mapsWeeklyCredits() throws {
        let billing = try GrokParser.credits(from: json("""
        {
          "config": {
            "creditUsagePercent": 42,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-06-30T18:36:14.268512+00:00",
              "end": "2026-07-07T18:36:14.268512+00:00"
            },
            "subscriptionTier": "SuperGrok"
          }
        }
        """))
        let expected = UsageWindow(kind: .weekly, usedPercent: 42, resetsAt: Timestamp.iso("2026-07-07T18:36:14Z"))
        #expect(billing == .usage(plan: "SuperGrok", window: expected))
    }

    @Test func fallsBackToMonthlyBudget() throws {
        let billing = try GrokParser.credits(from: json("""
        { "config": { "subscriptionTier": "SuperGrok Heavy", "monthlyLimit": { "val": "200" }, "used": { "val": 50 } } }
        """))
        #expect(billing == .usage(plan: "SuperGrok Heavy", window: UsageWindow(kind: .monthly, usedPercent: 25, resetsAt: nil)))
    }

    @Test func asksForMonthlyViewWhenPercentMissing() throws {
        #expect(try GrokParser.credits(from: json(#"{ "config": { "subscriptionTier": "Enterprise" } }"#)) == .needsMonthlyView(plan: "Enterprise"))
        #expect(try GrokParser.credits(from: json(#"{ "unrelated": true }"#)) == .noQuota)
    }

    @Test func prefersFreshDefaultIssuer() {
        let now = Timestamp.iso("2026-09-28T10:00:00Z")!
        let credentials = GrokParser.credentials(from: json("""
        {
          "https://auth.x.ai::stale": { "key": "old", "expires_at": "2026-09-01T00:00:00.000Z" },
          "https://auth.x.ai::client": { "key": "fresh", "user_id": "user-1", "expires_at": "2099-01-01T00:00:00.000Z" },
          "https://other.example": { "key": "alternate" }
        }
        """), now: now)
        #expect(credentials?.accessToken == "fresh")
        #expect(credentials?.userID == "user-1")
    }

    @Test func reportsExpiredSessionsAndIgnoresAlternatesWhenDefaultExists() {
        let now = Timestamp.iso("2026-09-28T10:00:00Z")!
        let expired = GrokParser.credentials(from: json("""
        { "https://auth.x.ai": { "key": "old", "expires_at": "2026-09-28T10:02:00Z" } }
        """), now: now)
        #expect(expired?.accessToken == "old")
        #expect(expired?.isFresh(at: now) == false)
        #expect(GrokParser.credentials(from: json(#"{ "https://auth.x.ai": {}, "https://other": { "key": "x" } }"#), now: now) == nil)
        #expect(GrokParser.credentials(from: json(#"{ "https://other": { "key": "x" } }"#), now: now)?.accessToken == "x")
    }
}

@Suite struct WindowTests {
    @Test func treatsPassedResetAsFullyAvailable() {
        let now = Date()
        let window = UsageWindow(kind: .session, usedPercent: 91.6, resetsAt: now.addingTimeInterval(-10))
        #expect(window.remainingPercent(at: now) == 100)
        #expect(UsageWindow(kind: .session, usedPercent: 91.6, resetsAt: nil).remainingPercent(at: now) == 8)
    }

    @Test func menuBarIgnoresModelScopedLimits() {
        let now = Date()
        let snapshot = ProviderSnapshot(provider: .claude, plan: nil, windows: [
            UsageWindow(kind: .session, usedPercent: 30, resetsAt: nil),
            UsageWindow(kind: .weekly, usedPercent: 60, resetsAt: nil),
            UsageWindow(kind: .weeklyModel("Fable"), usedPercent: 95, resetsAt: nil),
        ])
        #expect(snapshot.tightestWindow(at: now)?.kind == .weekly)
        let modelOnly = ProviderSnapshot(provider: .claude, plan: nil, windows: [UsageWindow(kind: .weeklyModel("Fable"), usedPercent: 95, resetsAt: nil)])
        #expect(modelOnly.tightestWindow(at: now)?.kind == .weeklyModel("Fable"))
    }

    @Test func levelsFollowRemainingPercent() {
        #expect(UsageLevel(remainingPercent: 50) == .normal)
        #expect(UsageLevel(remainingPercent: 20) == .warning)
        #expect(UsageLevel(remainingPercent: 5) == .critical)
    }

    @Test func formatsCountdowns() {
        let now = Date()
        #expect(Formatting.countdown(to: now.addingTimeInterval(2 * 3_600 + 10 * 60 + 5), from: now) == "2h 10m")
        #expect(Formatting.countdown(to: now.addingTimeInterval(3 * 86_400 + 4 * 3_600 + 30), from: now) == "3d 4h")
        #expect(Formatting.countdown(to: now.addingTimeInterval(20), from: now) == "1m")
        #expect(Formatting.countdown(to: now.addingTimeInterval(-5), from: now) == "now")
    }
}

@Suite struct AccountTests {
    @Test func parsesClaudeAuthStatus() {
        let identity = ClaudeParser.identity(fromStatus: json("""
        { "loggedIn": true, "authMethod": "claude.ai", "email": "me@example.com", "orgName": "Example", "subscriptionType": "team" }
        """))
        #expect(identity == AccountIdentity(email: "me@example.com", plan: "Team"))
        #expect(ClaudeParser.identity(fromStatus: json(#"{ "loggedIn": false }"#)) == nil)
    }

    @Test func mergesRefreshedClaudeTokenKeepingOtherFields() throws {
        let stored = json("""
        { "claudeAiOauth": { "accessToken": "old", "refreshToken": "r1", "expiresAt": 1, "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x" }, "other": 1 }
        """)
        let now = Date(timeIntervalSince1970: 1_000)
        let merged = try #require(ClaudeParser.applyingRefresh(json(#"{ "access_token": "new", "refresh_token": "r2", "expires_in": 3600 }"#), to: stored, now: now))
        let credentials = try #require(ClaudeParser.credentials(from: merged))
        #expect(credentials.accessToken == "new")
        #expect(credentials.refreshToken == "r2")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 4_600))
        #expect(credentials.plan == "Max 5x")
        #expect((try JSON.object(merged))["other"] as? Int == 1)
        #expect(ClaudeParser.applyingRefresh(json(#"{ "error": "invalid_grant" }"#), to: stored) == nil)
    }

    @Test func parsesCodexAccount() {
        #expect(CodexParser.identity(from: json(#"{ "account": { "type": "chatgpt", "email": "me@example.com", "planType": "plus" }, "requiresOpenaiAuth": true }"#))
            == AccountIdentity(email: "me@example.com", plan: "Plus"))
        #expect(CodexParser.identity(from: json(#"{ "account": null, "requiresOpenaiAuth": true }"#)) == nil)
    }

    @Test func extractsLoginURLFromTerminalOutput() {
        let output = "\u{1B}[1mStarting local login server.\u{1B}[0m If your browser did not open, navigate to:\n\n  https://auth.openai.com/oauth/authorize?client_id=abc&state=xyz\n"
        #expect(LoginURL.first(in: output)?.absoluteString == "https://auth.openai.com/oauth/authorize?client_id=abc&state=xyz")
        #expect(LoginURL.first(in: "no link here") == nil)
    }

    @Test func scopesClaudeKeychainServiceByConfigDirectory() {
        let directory = URL(filePath: "/Users/test/Library/Application Support/Quota/Accounts/claude/X")
        #expect(Keychain.scopedClaudeService(configDirectory: directory) == "Claude Code-credentials-a586252a")
    }

    @Test func accountsRoundTripWithoutSecrets() throws {
        let account = Account(provider: .grok, source: .managed, email: "me@example.com", plan: nil)
        let encoded = try JSONEncoder().encode([account])
        #expect(try JSONDecoder().decode([Account].self, from: encoded) == [account])
        #expect(account.home?.path.hasSuffix("Quota/Accounts/grok/\(account.id.uuidString)") == true)
        #expect(Account(provider: .claude, source: .cli, email: nil, plan: nil).home == nil)
    }
}
