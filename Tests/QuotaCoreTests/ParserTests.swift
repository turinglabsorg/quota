import CryptoKit
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

    @Test func readsAvailableChatGPTResetsAndDropsUsedOrExpiredOnes() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let credits = CodexParser.resetCredits(from: json("""
        { "rateLimitResetCredits": {
            "availableCount": 2,
            "credits": [
              { "id": "soon", "status": "available", "expiresAt": 1792700725, "title": "Full reset" },
              { "id": "later", "status": "available", "expiresAt": 1794007322, "title": "Full reset (Weekly + 5h)" },
              { "id": "used", "status": "consumed", "expiresAt": 1793299846, "title": "Full reset" },
              { "id": "gone", "status": "available", "expiresAt": 1780000000, "title": "Full reset" }
            ]
        } }
        """), now: now)
        #expect(credits?.count == 2)
        #expect(credits?.credits.map(\.id) == ["soon", "later"])
        #expect(credits?.credits[0].label == "Full reset")
        #expect(credits?.credits[1].label == "Full reset (Weekly + 5h)")

        let countOnly = CodexParser.resetCredits(from: json(#"{ "rate_limit_reset_credits": { "available_count": 1 } }"#), now: now)
        #expect(countOnly == ResetCredits(availableCount: 1, credits: []))
        #expect(CodexParser.resetCredits(from: json(#"{ "rateLimitResetCredits": { "availableCount": 0, "credits": [] } }"#), now: now) == nil)
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

    @Test func treatsOmittedPercentInConfirmedWeeklyPeriodAsZero() throws {
        let billing = try GrokParser.credits(from: json("""
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-10-01T07:17:10.164276+00:00",
              "end": "2026-10-08T07:17:10.164276+00:00"
            },
            "onDemandCap": { "val": 0 },
            "onDemandUsed": { "val": 0 },
            "isUnifiedBillingUser": true,
            "prepaidBalance": { "val": 0 },
            "topUpMethod": "TOP_UP_METHOD_SAVED_PAYMENT_METHOD",
            "billingPeriodStart": "2026-10-01T07:17:10.164276+00:00",
            "billingPeriodEnd": "2026-10-08T07:17:10.164276+00:00"
          }
        }
        """))
        #expect(billing == .usage(plan: nil, window: UsageWindow(kind: .weekly, usedPercent: 0, resetsAt: Timestamp.iso("2026-10-08T07:17:10Z"))))
    }

    @Test func keepsOmittedPercentUnknownWithoutConfirmation() throws {
        let mismatchedPeriod = try GrokParser.credits(from: json("""
        { "config": {
            "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-10-01T00:00:00Z", "end": "2026-10-08T00:00:00Z" },
            "billingPeriodStart": "2026-10-01T00:00:00Z", "billingPeriodEnd": "2026-11-01T00:00:00Z" } }
        """))
        #expect(mismatchedPeriod == .needsMonthlyView(plan: nil))

        let spendWithoutPercent = try GrokParser.credits(from: json("""
        { "config": {
            "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-10-01T00:00:00Z", "end": "2026-10-08T00:00:00Z" },
            "billingPeriodStart": "2026-10-01T00:00:00Z", "billingPeriodEnd": "2026-10-08T00:00:00Z",
            "onDemandCap": { "val": 0 }, "onDemandUsed": { "val": 3 } } }
        """))
        #expect(spendWithoutPercent == .needsMonthlyView(plan: nil))

        let explicitZeros = try GrokParser.credits(from: json("""
        { "config": {
            "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-10-01T00:00:00Z", "end": "2026-10-08T00:00:00Z" },
            "billingPeriodStart": "2026-10-01T00:00:00Z", "billingPeriodEnd": "2026-10-08T00:00:00Z",
            "onDemandCap": { "val": 50 }, "prepaidBalance": { "val": 0 } } }
        """))
        #expect(explicitZeros == .needsMonthlyView(plan: nil))
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

    @Test func menuBarStacksSessionAboveTheLongerWindow() {
        let now = Date()
        let claude = ProviderSnapshot(provider: .claude, plan: nil, windows: [
            UsageWindow(kind: .session, usedPercent: 30, resetsAt: nil),
            UsageWindow(kind: .weekly, usedPercent: 60, resetsAt: nil),
            UsageWindow(kind: .weeklyModel("Fable"), usedPercent: 95, resetsAt: nil),
        ])
        #expect(claude.menuBarWindows(at: now).map(\.kind) == [.session, .weekly])
        let weeklyOnly = ProviderSnapshot(provider: .codex, plan: nil, windows: [UsageWindow(kind: .weekly, usedPercent: 40, resetsAt: nil)])
        #expect(weeklyOnly.menuBarWindows(at: now).map(\.kind) == [.weekly])
        let legacyOllama = ProviderSnapshot(provider: .ollama, plan: nil, windows: [
            UsageWindow(kind: .monthly, usedPercent: 50, resetsAt: nil),
            UsageWindow(kind: .session, usedPercent: 10, resetsAt: nil),
        ])
        #expect(legacyOllama.menuBarWindows(at: now).map(\.kind) == [.session, .monthly])
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
        #expect(Formatting.relative(now.addingTimeInterval(-90 * 60), from: now) == "1 h ago")
        #expect(Formatting.relative(now.addingTimeInterval(-(3 * 86_400 + 4 * 3_600)), from: now) == "3d 4h ago")
        #expect(Formatting.relative(now.addingTimeInterval(-2 * 86_400), from: now) == "2d ago")
        #expect(Formatting.formatTokens(950) == "950")
        #expect(Formatting.formatTokens(45_200) == "45.2k")
        #expect(Formatting.formatTokens(1_250_000) == "1.25M")
        #expect(Formatting.formatTokens(26_009_930_000) == "26.01B")
        #expect(Formatting.formatTokens(1_000) == "1k")
    }

    @Test func claudeTokenBackoffGrowsAndRemembersTheWait() throws {
        #expect(ClaudeTokenBackoff.delay(attempt: 0, retryAfter: nil) == 30 * 60)
        #expect(ClaudeTokenBackoff.delay(attempt: 1, retryAfter: nil) == 60 * 60)
        #expect(ClaudeTokenBackoff.delay(attempt: 20, retryAfter: nil) == 12 * 3_600)
        #expect(ClaudeTokenBackoff.delay(attempt: 3, retryAfter: 90) == 90)
        #expect(ClaudeTokenBackoff.delay(attempt: 3, retryAfter: 10) == 60)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("claude-token-backoff.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!ClaudeTokenBackoff.isCoolingDown(at: now, from: url))
        ClaudeTokenBackoff.recordLimit(retryAfter: nil, now: now, to: url)
        #expect(ClaudeTokenBackoff.isCoolingDown(at: now.addingTimeInterval(10 * 60), from: url))
        #expect(!ClaudeTokenBackoff.isCoolingDown(at: now.addingTimeInterval(31 * 60), from: url))
        ClaudeTokenBackoff.recordLimit(retryAfter: 120, now: now, to: url)
        #expect(ClaudeTokenBackoff.load(from: url)?.attempts == 2)
        #expect(ClaudeTokenBackoff.isCoolingDown(at: now.addingTimeInterval(119), from: url))
        ClaudeTokenBackoff.clear(at: url)
        #expect(ClaudeTokenBackoff.load(from: url) == nil)
        try? FileManager.default.removeItem(at: directory)
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

    @Test func refreshRequestMatchesTheClaudeCodeBody() throws {
        let data = try #require(ClaudeParser.refreshRequest(refreshToken: "r", scopes: ["user:inference", "user:profile"], clientID: "client"))
        let object = try JSON.object(data)
        #expect(JSON.string(object["grant_type"]) == "refresh_token")
        #expect(JSON.string(object["refresh_token"]) == "r")
        #expect(JSON.string(object["client_id"]) == "client")
        #expect(JSON.string(object["scope"]) == "user:inference user:profile")
        let stored = json(#"{ "claudeAiOauth": { "accessToken": "a", "scopes": ["user:inference", " ", "user:sessions:claude_code"] } }"#)
        #expect(ClaudeParser.scopes(from: stored) == ["user:inference", "user:sessions:claude_code"])
        let withoutScopes = try #require(ClaudeParser.refreshRequest(refreshToken: "r", scopes: [], clientID: "client"))
        #expect(try JSON.object(withoutScopes)["scope"] == nil)
    }

    @Test func parsesCodexAccount() {
        #expect(CodexParser.identity(from: json(#"{ "account": { "type": "chatgpt", "email": "me@example.com", "planType": "plus" }, "requiresOpenaiAuth": true }"#))
            == AccountIdentity(email: "me@example.com", plan: "Plus"))
        #expect(CodexParser.identity(from: json(#"{ "account": null, "requiresOpenaiAuth": true }"#)) == nil)
        #expect(CodexParser.identity(from: json(#"{ "account": { "email": "me@example.com", "planType": "unknown" } }"#))?.plan == nil)
        #expect(CodexParser.identity(from: json(#"{ "account": { "email": "me@example.com", "planType": "self_serve_business_prolite" } }"#))?.plan == "Business")
    }

    @Test func extractsLoginURLFromTerminalOutput() {
        let output = "\u{1B}[1mStarting local login server.\u{1B}[0m If your browser did not open, navigate to:\n\n  https://auth.openai.com/oauth/authorize?client_id=abc&state=xyz\n"
        #expect(LoginURL.first(in: output)?.absoluteString == "https://auth.openai.com/oauth/authorize?client_id=abc&state=xyz")
        #expect(LoginURL.first(in: "no link here") == nil)
    }

    @Test func prefersFileWhenKeychainHasNoAccessToken() {
        let file = json(#"{ "claudeAiOauth": { "accessToken": "file-token", "refreshToken": "r", "expiresAt": 2000000000000, "subscriptionType": "team" } }"#)
        let blank = json(#"{ "claudeAiOauth": { "accessToken": "", "refreshToken": "", "expiresAt": 0, "subscriptionType": "team" } }"#)
        let selected = SharedClaudeLogin.select(keychain: blank, file: file)
        #expect(selected?.credentials.accessToken == "file-token")
        #expect(selected?.keychainRepair == file)
        let keychain = json(#"{ "claudeAiOauth": { "accessToken": "keychain-token", "expiresAt": 2000000000000, "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x" } }"#)
        let preferred = SharedClaudeLogin.select(keychain: keychain, file: file)
        #expect(preferred?.credentials.accessToken == "keychain-token")
        #expect(preferred?.credentials.plan == "Max 5x")
        #expect(preferred?.keychainRepair == nil)
        #expect(SharedClaudeLogin.select(keychain: blank, file: blank) == nil)
        #expect(SharedClaudeLogin.select(keychain: nil, file: file)?.keychainRepair == nil)
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

private func hex(_ string: String) -> Data {
    Data(stride(from: 0, to: string.count, by: 2).map { offset in
        let start = string.index(string.startIndex, offsetBy: offset)
        return UInt8(string[start..<string.index(start, offsetBy: 2)], radix: 16)!
    })
}

@Suite struct OllamaTests {
    // RFC 8032, section 7.1, test 1.
    private let seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")

    @Test func derivesTheRFC8032PublicKey() throws {
        let key = try #require(OllamaKey(seed: seed))
        #expect(key.publicKey == hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"))
        #expect(key.authorizedKey.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
    }

    @Test func signsRequestsLikeTheOllamaCLI() throws {
        let key = try #require(OllamaKey(seed: seed))
        let parts = try key.authorization(method: "GET", path: "/api/usage", timestamp: "1770000000").split(separator: ":").map(String.init)
        #expect(parts.count == 2)
        #expect(Data(base64Encoded: parts[0]) == key.publicBlob)
        let signature = try #require(Data(base64Encoded: parts[1]))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey)
        #expect(publicKey.isValidSignature(signature, for: Data("GET,/api/usage?ts=1770000000".utf8)))
    }

    @Test func buildsTheConnectLinkOllamaOpens() throws {
        let key = try #require(OllamaKey(seed: seed))
        let url = OllamaCloud.connectURL(for: key, deviceName: "my mac").absoluteString
        #expect(url.hasPrefix("https://ollama.com/connect?name=my%20mac&key="))
        let encoded = String(try #require(url.split(separator: "=", maxSplits: 2).last))
        #expect(!encoded.contains("="))
        let padded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        #expect(Data(base64Encoded: padded).map { String(decoding: $0, as: UTF8.self) } == key.authorizedKey)
    }

    @Test func roundTripsOpenSSHKeys() throws {
        let key = try #require(OllamaKey(seed: seed))
        let text = OpenSSHKey.text(for: key)
        #expect(text.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        #expect(OpenSSHKey.seed(from: text) == seed)
        #expect(OpenSSHKey.seed(from: "garbage") == nil)
        #expect(OpenSSHKey.seed(from: "-----BEGIN OPENSSH PRIVATE KEY-----\nbm90IGEga2V5\n-----END OPENSSH PRIVATE KEY-----") == nil)
    }

    @Test func interoperatesWithSSHKeygen() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let theirs = directory.appending(path: "theirs")
        _ = try sshKeygen(["-q", "-t", "ed25519", "-N", "", "-C", "", "-f", theirs.path])
        let theirSeed = try #require(OpenSSHKey.seed(from: String(contentsOf: theirs, encoding: .utf8)))
        let theirKey = try #require(OllamaKey(seed: theirSeed))
        let publicLine = try String(contentsOf: theirs.appendingPathExtension("pub"), encoding: .utf8)
        #expect(publicLine.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ") == theirKey.authorizedKey)

        let mine = directory.appending(path: "mine")
        let key = try #require(OllamaKey(seed: seed))
        try OpenSSHKey.text(for: key).write(to: mine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mine.path)
        let derived = try sshKeygen(["-y", "-f", mine.path])
        #expect(derived.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ") == key.authorizedKey)
    }

    @Test func mapsTheIncludedMonthlyAllowance() throws {
        let windows = try OllamaParser.usage(from: json("""
        {
          "included": {
            "balance_usd": 72.5,
            "allowance_usd": 100,
            "period": { "from": "2026-09-15T09:30:00Z", "until": "2026-10-15T09:30:00Z" }
          },
          "purchased": { "balance_usd": 25 }
        }
        """))
        #expect(windows == [UsageWindow(kind: .monthly, usedPercent: 27.5, resetsAt: Timestamp.iso("2026-10-15T09:30:00Z"))])
        #expect(windows[0].remainingPercent(at: Timestamp.iso("2026-10-01T00:00:00Z")!) == 72)
    }

    @Test func mapsLegacySessionAndWeeklyWindows() throws {
        let windows = try OllamaParser.usage(from: json("""
        {
          "included": {
            "session": { "remaining_percent": 75, "resets_at": "2026-10-01T07:00:00Z" },
            "weekly": { "remaining_percent": 40, "resets_at": "2026-10-05T00:00:00Z" }
          },
          "purchased": { "balance_usd": 25 }
        }
        """))
        #expect(windows == [
            UsageWindow(kind: .session, usedPercent: 25, resetsAt: Timestamp.iso("2026-10-01T07:00:00Z")),
            UsageWindow(kind: .weekly, usedPercent: 60, resetsAt: Timestamp.iso("2026-10-05T00:00:00Z")),
        ])
    }

    @Test func ignoresInvalidBalances() throws {
        #expect(try OllamaParser.usage(from: json(#"{ "Included": { "Session": { "Remaining_Percent": 140 }, "allowance_usd": 0, "balance_usd": 5 } }"#)).isEmpty)
        #expect(try OllamaParser.usage(from: json(#"{ "included": {}, "purchased": { "balance_usd": 25 } }"#)).isEmpty)
        #expect(throws: ProviderIssue.invalidResponse) { try OllamaParser.usage(from: json(#"{ "error": "unauthorized" }"#)) }
    }

    @Test func treatsAnEmptyUserAsNotLinked() {
        #expect(OllamaParser.identity(from: json(#"{ "ID": "1", "Email": "me@example.com", "Name": "me", "Plan": "max" }"#))
            == AccountIdentity(email: "me@example.com", plan: "Max"))
        #expect(OllamaParser.identity(from: json(#"{ "ID": "00000000-0000-0000-0000-000000000000", "Email": "", "Name": "", "Plan": "" }"#)) == nil)
    }

    private func sshKeygen(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

// Live check against the real Claude Code CLI and Keychain; run with QUOTA_LIVE_TESTS=1 scripts/test.sh.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["QUOTA_LIVE_TESTS"] != nil))
struct SharedClaudeLoginLiveTests {
    @Test func renewReturnsTheCurrentCLISession() async throws {
        let current = try #require(await SharedClaudeLogin.read())
        guard case .current(let renewed) = await SharedClaudeLogin.renew(replacing: "stale-\(UUID().uuidString)") else {
            Issue.record("Claude session was not renewed")
            return
        }
        #expect(renewed.accessToken == current.accessToken || !renewed.isExpiring(at: Date()))
    }
}

// Live check against api.meta.ai with the `muse login` Keychain item; run with QUOTA_LIVE_TESTS=1 scripts/test.sh.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["QUOTA_LIVE_TESTS"] != nil))
struct MuseCodeLiveTests {
    @Test func readsTheAccountsPageWindows() async throws {
        let identity = try #require(await AccountLinker.detectCLILogin(.musecode), "Muse Code is not signed in on this Mac")
        let account = Account(provider: .musecode, source: .cli, email: identity.email, plan: identity.plan)
        let snapshot = try await UsageFetchers.fetch(account)
        #expect(snapshot.windows.contains { $0.kind == .session })
        #expect(snapshot.windows.contains { $0.kind == .weekly })
        let windows = snapshot.windows.map { "\($0.label) \(Int($0.usedPercent.rounded()))% used" }.joined(separator: ", ")
        print("Muse Code (\(snapshot.plan ?? "no plan")): \(windows)")
    }
}

// Live check against ollama.com with the device key `ollama signin` linked; run with QUOTA_LIVE_TESTS=1 scripts/test.sh.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["QUOTA_LIVE_TESTS"] != nil))
struct OllamaCloudLiveTests {
    @Test func readsUsageForTheSignedInDevice() async throws {
        let identity = try #require(await AccountLinker.detectCLILogin(.ollama), "Ollama is not signed in on this Mac")
        let account = Account(provider: .ollama, source: .cli, email: identity.email, plan: identity.plan)
        let snapshot = try await UsageFetchers.fetch(account)
        #expect(!snapshot.windows.isEmpty)
        let windows = snapshot.windows.map { "\($0.label) \(Int($0.usedPercent.rounded()))% used" }.joined(separator: ", ")
        print("Ollama Cloud: \(snapshot.account ?? "?") (\(snapshot.plan ?? "no plan")): \(windows)")
    }
}

@Suite struct MuseCodeParserTests {
    @Test func readsTheTokenTheCLIStoredInItsAuthFile() {
        let stored = json("""
        {"schema_version": 1, "providers": {"meta": {"mechanism": "oauth", "access_token": "file-token", "user_email": "name@example.com"}}}
        """)
        #expect(MuseCodeParser.fileAccessToken(from: stored) == "file-token")
        let keychainOnly = json("""
        {"schema_version": 1, "providers": {"meta": {"mechanism": "oauth", "user_email": "name@example.com"}}}
        """)
        #expect(MuseCodeParser.fileAccessToken(from: keychainOnly) == nil)
        let apiKey = json("""
        {"providers": {"meta": {"mechanism": "api_key", "access_token": "x"}}}
        """)
        #expect(MuseCodeParser.fileAccessToken(from: apiKey) == nil)
    }

    @Test func mapsTheAccountsPageWindows() throws {
        let snapshot = try MuseCodeParser.snapshot(from: json("""
        {
          "is_subs_active": true,
          "subs_tier_name": "Muse Code High Usage",
          "user_email": "name@example.com",
          "api_key": "must-not-matter",
          "subs_usage": {
            "tier": "27681527378179523",
            "window": { "used_percent": 7, "window_duration_mins": 300, "resets_at": 1792086750 },
            "weekly": { "used_percent": 36, "resets_at": 1792368000 }
          }
        }
        """))
        #expect(snapshot.provider == .musecode)
        #expect(snapshot.plan == "High Usage")
        #expect(snapshot.account == "name@example.com")
        #expect(snapshot.windows.map(\.kind) == [.session, .weekly])
        #expect(snapshot.windows.map { Int($0.usedPercent) } == [7, 36])
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_792_086_750))
        #expect(snapshot.windows[1].resetsAt == Date(timeIntervalSince1970: 1_792_368_000))
        let now = Date(timeIntervalSince1970: 1_792_080_000)
        #expect(snapshot.menuBarWindows(at: now).map(\.kind) == [.session, .weekly])
    }

    @Test func keepsANonFiveHourWindowCustom() throws {
        let snapshot = try MuseCodeParser.snapshot(from: json("""
        {
          "subs_tier_name": "Everyday Usage",
          "subs_usage": {
            "window": { "used_percent": 12.5, "window_duration_mins": 60, "resets_at": 1700000000 }
          }
        }
        """))
        #expect(snapshot.plan == "Everyday Usage")
        #expect(snapshot.windows.map(\.kind) == [.custom(minutes: 60)])
        #expect(snapshot.windows[0].usedPercent == 12.5)
    }

    @Test func rejectsAnInactiveSubscriptionAndABlankToken() {
        let inactive = json(#"{ "is_subs_active": false, "subs_usage": { "weekly": { "used_percent": 1, "resets_at": 1700000000 } } }"#)
        #expect(throws: ProviderIssue.noQuota(String(localized: "This Muse Code account has no active subscription."))) {
            try MuseCodeParser.snapshot(from: inactive)
        }
        #expect(MuseCodeParser.accessToken(from: json(#"{"access_token":""}"#)) == nil)
        #expect(MuseCodeParser.accessToken(from: json(#"{"access_token":"account-token"}"#)) == "account-token")
        #expect(MuseCodeParser.planLabel("Muse Code High Usage") == "High Usage")
        #expect(MuseCodeParser.planLabel(nil) == nil)
    }

    @Test func sumsTodayAndTheLastSevenDaysFromSessionLogs() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeLog(root: root, at: now, session: "session-a", lines: [
            record(at: now, session: "session-a", usage: #"{"input_tokens":1000,"output_tokens":50,"cached_tokens":800,"cache_write_tokens":10,"reasoning_tokens":5}"#),
            record(at: now, session: "session-a", usage: #"{"input_tokens":500,"output_tokens":25,"cache_read_tokens":400}"#),
            "not json",
            #"{"recorded_at":\#(Int(now.timeIntervalSince1970 * 1_000_000)),"payload":{"event":{"kind":"model_response_created"}}}"#,
        ])
        try writeLog(root: root, at: now, session: "session-a", lines: [
            record(at: now, session: "session-a", usage: #"{"input_tokens":200,"output_tokens":10,"cached_tokens":100,"reasoning_tokens":0}"#),
        ], subagent: true)
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        try writeLog(root: root, at: threeDaysAgo, session: "session-b", lines: [
            record(at: threeDaysAgo, session: "session-b", usage: #"{"input_tokens":2000,"output_tokens":100,"cached_tokens":1500,"reasoning_tokens":20}"#),
        ])
        let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)
        try writeLog(root: root, at: tenDaysAgo, session: "session-old", lines: [
            record(at: tenDaysAgo, session: "session-old", usage: #"{"input_tokens":9999,"output_tokens":9999,"cached_tokens":0,"reasoning_tokens":0}"#),
        ])
        let aggregate = MuseLogs.aggregate(root: root, now: now)
        let today = try #require(aggregate.usage.first { $0.period == "today" })
        let week = try #require(aggregate.usage.first { $0.period == "last7Days" })
        #expect(aggregate.model == "muse-wonder-1.0")
        #expect(today.inputTokens == 1_700)
        #expect(today.outputTokens == 85)
        #expect(today.cachedTokens == 1_300)
        #expect(today.cacheWriteTokens == 10)
        #expect(today.reasoningTokens == 5)
        #expect(today.sessions == 1)
        #expect(today.steps == 3)
        #expect(today.totalTokens == 1_785)
        #expect(today.resetsAt != nil)
        #expect(today.label == "Today")
        #expect(week.inputTokens == 3_700)
        #expect(week.outputTokens == 185)
        #expect(week.steps == 4)
        #expect(week.sessions == 2)
        #expect(week.resetsAt == nil)
        #expect(week.label == "Last 7 days")
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(!MuseLogs.aggregate(root: empty, now: now).hasSteps)
    }
}

private func record(at date: Date, session: String, usage: String) -> String {
    let recorded = Int(date.timeIntervalSince1970 * 1_000_000)
    return #"{"recorded_at":\#(recorded),"stream":{"kind":"session","id":"\#(session)"},"payload":{"event":{"kind":"model_completed","model":"muse-wonder-1.0","usage":\#(usage)}}}"#
}

private func writeLog(root: URL, at date: Date, session: String, lines: [String], subagent: Bool = false) throws {
    let calendar = Calendar.current
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    var directory = root
        .appendingPathComponent(String(format: "%04d", parts.year ?? 0))
        .appendingPathComponent(String(format: "%02d", parts.month ?? 0))
        .appendingPathComponent(String(format: "%02d", parts.day ?? 0))
        .appendingPathComponent(session)
    if subagent {
        directory = directory.appendingPathComponent("subagent").appendingPathComponent("child-1")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let text = lines.joined(separator: "\n") + "\n"
    try text.write(to: directory.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
}

@Suite struct UsagePayloadTests {
    @Test func roundTripsEveryWindowKind() throws {
        let account = Account(provider: .claude, source: .managed, email: "me@example.com", plan: "Max 5x")
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ProviderSnapshot(provider: .claude, plan: "Max 5x", account: "me@example.com", windows: [
            UsageWindow(kind: .session, usedPercent: 12.5, resetsAt: reset),
            UsageWindow(kind: .weekly, usedPercent: 40, resetsAt: nil),
            UsageWindow(kind: .weeklyModel("Fable"), usedPercent: 90, resetsAt: reset),
            UsageWindow(kind: .monthly, usedPercent: 3, resetsAt: reset),
            UsageWindow(kind: .custom(minutes: 60), usedPercent: 7, resetsAt: nil),
        ], fetchedAt: reset)
        let payload = UsagePayload(generatedAt: reset, refreshedAt: reset, accounts: [
            AccountUsage(account: account, snapshot: snapshot, issue: .rateLimited),
        ])
        let decoded = try UsagePayload.decode(UsagePayload.encode(payload))
        #expect(decoded == payload)
        #expect(decoded.accounts[0].usageWindows == snapshot.windows)
        #expect(decoded.accounts[0].snapshot == snapshot)
        #expect(decoded.accounts[0].issue?.kind == "rateLimited")
    }

    @Test func skipsWindowKindsFromNewerServers() throws {
        let json = #"{"version":1,"generatedAt":"2026-10-07T00:00:00Z","accounts":[{"id":"6F1A2C9E-3B7D-4E58-9A10-1B2C3D4E5F60","provider":"codex","source":"cli","windows":[{"kind":"daily","usedPercent":5},{"kind":"weekly","usedPercent":10}]}]}"#
        let payload = try UsagePayload.decode(Data(json.utf8))
        #expect(payload.accounts[0].usageWindows.map(\.kind) == [.weekly])
        #expect(payload.accounts[0].snapshot == nil)
    }
}
