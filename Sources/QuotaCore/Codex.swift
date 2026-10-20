import Foundation

public enum CodexAuth: Equatable, Sendable {
    case chatGPT(accessToken: String, accountID: String?)
    case apiKey
}

public enum CodexParser {
    private static let sessionMinutes = 300
    private static let weeklyMinutes = 10_080
    private static let monthlyMinutes = 43_200

    public static func auth(from data: Data) -> CodexAuth? {
        guard let root = try? JSON.object(data) else { return nil }
        if let tokens = JSON.dict(root["tokens"]), let accessToken = JSON.string(tokens["access_token"]) {
            return .chatGPT(accessToken: accessToken, accountID: JSON.string(tokens["account_id"]))
        }
        return JSON.string(root["OPENAI_API_KEY"]) == nil ? nil : .apiKey
    }

    public static func identity(from data: Data) -> AccountIdentity? {
        guard let root = try? JSON.object(data), let account = JSON.dict(root["account"]) else { return nil }
        return AccountIdentity(email: JSON.string(account["email"]), plan: planLabel(account["planType"]))
    }

    public static func rpcUsage(from data: Data) throws -> (plan: String?, windows: [UsageWindow]) {
        let root = try JSON.object(data)
        guard let limits = JSON.dict(root["rateLimits"]) else { throw ProviderIssue.invalidResponse }
        let slots: [(key: String, fallback: UsageWindow.Kind)] = [("primary", .session), ("secondary", .weekly)]
        let windows = slots.compactMap { slot -> UsageWindow? in
            guard let raw = JSON.dict(limits[slot.key]), let used = JSON.number(raw["usedPercent"]) else { return nil }
            let minutes = JSON.number(raw["windowDurationMins"]).map { Int($0.rounded()) }
            return UsageWindow(kind: kind(minutes: minutes, fallback: slot.fallback), usedPercent: used, resetsAt: Timestamp.date(raw["resetsAt"]))
        }
        return (planLabel(limits["planType"]), sorted(windows))
    }

    public static func usage(from data: Data, now: Date = Date()) throws -> (plan: String?, windows: [UsageWindow]) {
        let root = try JSON.object(data)
        guard let planType = JSON.string(root["plan_type"]) else { throw ProviderIssue.invalidResponse }
        let rateLimit = JSON.dict(root["rate_limit"])
        let slots: [(key: String, fallback: UsageWindow.Kind)] = [("primary_window", .session), ("secondary_window", .weekly)]
        let windows = slots.compactMap { slot -> UsageWindow? in
            guard let raw = JSON.dict(rateLimit?[slot.key]), let used = JSON.number(raw["used_percent"]) else { return nil }
            let resetsAt = Timestamp.date(raw["reset_at"])
                ?? JSON.number(raw["reset_after_seconds"]).map { now.addingTimeInterval($0) }
            let minutes = JSON.number(raw["limit_window_seconds"]).map { Int(($0 / 60).rounded(.up)) }
            return UsageWindow(kind: kind(minutes: minutes, fallback: slot.fallback), usedPercent: used, resetsAt: resetsAt)
        }
        return (planName(planType), sorted(windows))
    }

    /// ChatGPT grants a few rate-limit resets. Codex reports the count, and each credit's expiry when it has one.
    public static func resetCredits(from data: Data, now: Date = Date()) -> ResetCredits? {
        guard let root = try? JSON.object(data),
              let box = JSON.dict(root["rateLimitResetCredits"]) ?? JSON.dict(root["rate_limit_reset_credits"])
        else { return nil }
        let reported = JSON.number(box["availableCount"] ?? box["available_count"]).map { Int($0.rounded()) }
        let credits = (box["credits"] as? [Any] ?? []).compactMap { item -> ResetCredit? in
            guard let raw = JSON.dict(item) else { return nil }
            if let status = JSON.string(raw["status"])?.lowercased(), status != "available" { return nil }
            let expiresAt = Timestamp.date(raw["expiresAt"] ?? raw["expires_at"])
            if let expiresAt, expiresAt <= now { return nil }
            let title = JSON.string(raw["title"]) ?? String(localized: "Full reset")
            let id = JSON.string(raw["id"]) ?? "\(title)-\(expiresAt?.timeIntervalSince1970 ?? 0)"
            return ResetCredit(id: id, title: title, expiresAt: expiresAt)
        }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        let count = max(reported ?? 0, credits.count)
        guard count > 0 else { return nil }
        return ResetCredits(availableCount: reported ?? credits.count, credits: credits)
    }

    private static func planLabel(_ value: Any?) -> String? {
        guard let plan = JSON.string(value), plan.lowercased() != "unknown" else { return nil }
        return planName(plan)
    }

    // ChatGPT plan identifiers as people know them: `self_serve_business_prolite` is a Business seat.
    static func planName(_ plan: String) -> String {
        if plan.lowercased().hasPrefix("self_serve_business") { return "Business" }
        return Formatting.capitalized(plan.replacingOccurrences(of: "_", with: " "))
    }

    private static func kind(minutes: Int?, fallback: UsageWindow.Kind) -> UsageWindow.Kind {
        guard let minutes, minutes > 0 else { return fallback }
        if abs(minutes - sessionMinutes) <= 1 { return .session }
        if abs(minutes - weeklyMinutes) <= 1 { return .weekly }
        if abs(minutes - monthlyMinutes) <= 1_440 { return .monthly }
        return .custom(minutes: minutes)
    }

    private static func sorted(_ windows: [UsageWindow]) -> [UsageWindow] {
        windows.sorted { order($0.kind) < order($1.kind) }
    }

    private static func order(_ kind: UsageWindow.Kind) -> Int {
        switch kind {
        case .custom(let minutes): minutes
        case .session: sessionMinutes
        case .weekly, .weeklyModel: weeklyMinutes
        case .monthly: monthlyMinutes
        }
    }
}

struct CodexFetcher {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let accountMethod = "account/read"
    static let rateLimitsMethod = "account/rateLimits/read"

    let account: Account

    func fetch() async throws -> ProviderSnapshot {
        guard let executable = await CLI.locate(.codex) else {
            guard account.home == nil else { throw ProviderIssue.signedOut(String(localized: "`codex` CLI not found.")) }
            return try await fetchFromBackend()
        }
        let response: CodexRPC.Response
        do {
            response = try await CodexRPC.call(executable, home: account.home, methods: [Self.accountMethod, Self.rateLimitsMethod])
        } catch {
            guard account.home == nil else { throw ProviderIssue.network }
            return try await fetchFromBackend()
        }
        if let accountData = response.results[Self.accountMethod], CodexParser.identity(from: accountData) == nil {
            throw ProviderIssue.signedOut(String(localized: "This Codex account is not signed in with ChatGPT."))
        }
        if let message = response.errors[Self.rateLimitsMethod] {
            throw CodexRPC.issue(forErrorMessage: message)
        }
        guard let data = response.results[Self.rateLimitsMethod] else { throw ProviderIssue.invalidResponse }
        let identity = response.results[Self.accountMethod].flatMap(CodexParser.identity)
        let usage = try CodexParser.rpcUsage(from: data)
        return try snapshot(plan: usage.plan ?? identity?.plan, email: identity?.email ?? account.email, windows: usage.windows, credits: CodexParser.resetCredits(from: data))
    }

    private func fetchFromBackend() async throws -> ProviderSnapshot {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? LocalFiles.home.appendingPathComponent(".codex")
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let auth = CodexParser.auth(from: data)
        else {
            throw ProviderIssue.signedOut(String(localized: "Codex is not signed in with ChatGPT. Run `codex login`."))
        }
        guard case .chatGPT(let accessToken, let accountID) = auth else {
            throw ProviderIssue.noQuota(String(localized: "Codex uses an API key: no subscription limits."))
        }
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "User-Agent": "codex-cli",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop",
        ]
        if let accountID { headers["ChatGPT-Account-Id"] = accountID }

        let response: Data
        do {
            response = try await HTTP.get(Self.usageURL, headers: headers)
        } catch ProviderIssue.http(let status) where status == 401 || status == 403 {
            throw ProviderIssue.sessionExpired(String(localized: "Session expired. Open Codex to renew it."))
        }
        let usage = try CodexParser.usage(from: response)
        return try snapshot(plan: usage.plan, email: account.email, windows: usage.windows, credits: CodexParser.resetCredits(from: response))
    }

    private func snapshot(plan: String?, email: String?, windows: [UsageWindow], credits: ResetCredits?) throws -> ProviderSnapshot {
        guard !windows.isEmpty else {
            throw ProviderIssue.noQuota(String(localized: "This account has no subscription limits."))
        }
        return ProviderSnapshot(provider: .codex, plan: plan, account: email, windows: windows, resetCredits: credits)
    }
}

extension ProviderIssue {
    var isAuthFailure: Bool {
        switch self {
        case .signedOut, .sessionExpired: true
        default: false
        }
    }
}
