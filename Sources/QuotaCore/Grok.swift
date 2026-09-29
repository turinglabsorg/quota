import Foundation

public struct GrokCredentials: Equatable, Sendable {
    public var accessToken: String
    public var userID: String?
    public var email: String?
    public var expiresAt: Date?

    public func isFresh(at now: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > 5 * 60
    }
}

public enum GrokBilling: Equatable, Sendable {
    case usage(plan: String?, window: UsageWindow)
    case needsMonthlyView(plan: String?)
    case noQuota
}

public enum GrokParser {
    private static let preferredIssuer = "https://auth.x.ai"

    public static func credentials(from data: Data, now: Date = Date()) -> GrokCredentials? {
        guard let root = try? JSON.object(data) else { return nil }
        var preferred: [GrokCredentials] = []
        var alternates: [GrokCredentials] = []
        var sawPreferredIssuer = false
        for key in root.keys.sorted() {
            let isPreferred = key == preferredIssuer || key.hasPrefix("\(preferredIssuer)::")
            sawPreferredIssuer = sawPreferredIssuer || isPreferred
            guard let entry = JSON.dict(root[key]), let token = JSON.string(entry["key"]) else { continue }
            let credentials = GrokCredentials(
                accessToken: token,
                userID: JSON.string(entry["user_id"]),
                email: JSON.string(entry["email"]),
                expiresAt: JSON.string(entry["expires_at"]).flatMap(Timestamp.iso)
            )
            if isPreferred { preferred.append(credentials) } else { alternates.append(credentials) }
        }
        if let fresh = preferred.first(where: { $0.isFresh(at: now) }) { return fresh }
        if let stale = preferred.first { return stale }
        return sawPreferredIssuer ? nil : alternates.first
    }

    public static func credits(from data: Data) throws -> GrokBilling {
        let root = try JSON.object(data)
        guard let config = billingConfig(root) else { return .noQuota }
        let plan = JSON.string(config["subscriptionTier"])
        let period = JSON.dict(config["currentPeriod"])
        let resetsAt = Timestamp.date(period?["end"]) ?? Timestamp.date(config["billingPeriodEnd"])

        if let percent = JSON.number(config["creditUsagePercent"]) {
            let kind: UsageWindow.Kind = JSON.string(period?["type"]) == "USAGE_PERIOD_TYPE_MONTHLY" ? .monthly : .weekly
            return .usage(plan: plan, window: UsageWindow(kind: kind, usedPercent: percent, resetsAt: resetsAt))
        }
        if let monthly = monthlyWindow(config, resetsAt: resetsAt) {
            return .usage(plan: plan, window: monthly)
        }
        return .needsMonthlyView(plan: plan)
    }

    public static func monthly(from data: Data) throws -> UsageWindow? {
        let root = try JSON.object(data)
        let config = JSON.dict(root["config"]) ?? root
        let resetsAt = Timestamp.date(JSON.dict(config["currentPeriod"])?["end"]) ?? Timestamp.date(config["billingPeriodEnd"])
        return monthlyWindow(config, resetsAt: resetsAt)
    }

    private static func billingConfig(_ root: [String: Any]) -> [String: Any]? {
        if let config = JSON.dict(root["config"]) { return config }
        let flatFields = [
            "creditUsagePercent", "currentPeriod", "billingPeriodStart", "billingPeriodEnd",
            "subscriptionTier", "monthlyLimit", "used", "onDemandCap", "onDemandUsed", "prepaidBalance",
        ]
        return flatFields.contains { root[$0] != nil } ? root : nil
    }

    private static func monthlyWindow(_ config: [String: Any], resetsAt: Date?) -> UsageWindow? {
        guard let limit = JSON.number(JSON.dict(config["monthlyLimit"])?["val"]), limit > 0,
              let used = JSON.number(JSON.dict(config["used"])?["val"])
        else { return nil }
        return UsageWindow(kind: .monthly, usedPercent: used / limit * 100, resetsAt: resetsAt)
    }
}

struct GrokFetcher {
    private static let baseURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!

    let account: Account

    static func home(for account: Account) -> URL {
        account.home
            ?? ProcessInfo.processInfo.environment["GROK_HOME"].map { URL(filePath: $0) }
            ?? LocalFiles.home.appending(path: ".grok")
    }

    static func credentials(home: URL) -> GrokCredentials? {
        guard let data = try? Data(contentsOf: home.appending(path: "auth.json")) else { return nil }
        return GrokParser.credentials(from: data)
    }

    func fetch() async throws -> ProviderSnapshot {
        let home = Self.home(for: account)
        guard var credentials = Self.credentials(home: home) else {
            throw ProviderIssue.signedOut(String(localized: "This Grok account is not signed in."))
        }
        if !credentials.isFresh(at: Date()) {
            await refreshSession(home: home)
            guard let refreshed = Self.credentials(home: home), refreshed.isFresh(at: Date()) else {
                throw ProviderIssue.sessionExpired(String(localized: "Grok session expired: relink the account."))
            }
            credentials = refreshed
        }

        var headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "X-XAI-Token-Auth": "xai-grok-cli",
            "Accept": "application/json",
        ]
        if let userID = credentials.userID { headers["x-userid"] = userID }
        let email = credentials.email ?? account.email

        do {
            let creditsURL = Self.baseURL.appending(queryItems: [URLQueryItem(name: "format", value: "credits")])
            let credits = try await HTTP.get(creditsURL, headers: headers)
            switch try GrokParser.credits(from: credits) {
            case .usage(let plan, let window):
                return ProviderSnapshot(provider: .grok, plan: plan, account: email, windows: [window])
            case .needsMonthlyView(let plan):
                let billing = try await HTTP.get(Self.baseURL, headers: headers)
                if let window = try GrokParser.monthly(from: billing) {
                    return ProviderSnapshot(provider: .grok, plan: plan, account: email, windows: [window])
                }
                throw ProviderIssue.noQuota(String(localized: "Grok reports no usage percentage for this account."))
            case .noQuota:
                throw ProviderIssue.noQuota(String(localized: "This account has no subscription limits."))
            }
        } catch ProviderIssue.http(let status) where status == 401 || status == 403 {
            throw ProviderIssue.sessionExpired(String(localized: "Grok session expired: relink the account."))
        }
    }

    // Running any authenticated Grok command lets the CLI rotate its own access token.
    private func refreshSession(home: URL) async {
        guard let executable = await CLI.locate(.grok) else { return }
        _ = try? await CommandRunner.run(executable, ["models"], environment: ["GROK_HOME": home.path], timeout: 45)
    }
}
