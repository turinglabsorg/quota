import Foundation

public struct ClaudeCredentials: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var plan: String?

    func isExpiring(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < 5 * 60
    }
}

public enum ClaudeParser {
    private static let modelWeeklyKeys = ["opus", "sonnet", "haiku", "fable"]

    public static func credentials(from data: Data) -> ClaudeCredentials? {
        guard let root = try? JSON.object(data),
              let oauth = JSON.dict(root["claudeAiOauth"]),
              let token = JSON.string(oauth["accessToken"])
        else { return nil }
        return ClaudeCredentials(
            accessToken: token,
            refreshToken: JSON.string(oauth["refreshToken"]),
            expiresAt: JSON.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1_000) },
            plan: planLabel(subscriptionType: JSON.string(oauth["subscriptionType"]), tier: JSON.string(oauth["rateLimitTier"]))
        )
    }

    public static func planLabel(subscriptionType: String?, tier: String?) -> String? {
        guard let type = subscriptionType?.lowercased() else { return nil }
        if type == "max", let tier = tier?.lowercased() {
            if tier.contains("20x") { return "Max 20x" }
            if tier.contains("5x") { return "Max 5x" }
        }
        return Formatting.capitalized(type)
    }

    public static func identity(fromStatus data: Data) -> AccountIdentity? {
        guard let root = try? JSON.object(data), (root["loggedIn"] as? Bool) == true else { return nil }
        return AccountIdentity(
            email: JSON.string(root["email"]),
            plan: planLabel(subscriptionType: JSON.string(root["subscriptionType"]), tier: nil)
        )
    }

    public static func applyingRefresh(_ response: Data, to stored: Data, now: Date = Date()) -> Data? {
        guard var root = try? JSON.object(stored),
              var oauth = JSON.dict(root["claudeAiOauth"]),
              let refreshed = try? JSON.object(response),
              let accessToken = JSON.string(refreshed["access_token"])
        else { return nil }
        oauth["accessToken"] = accessToken
        if let expiresIn = JSON.number(refreshed["expires_in"]) {
            oauth["expiresAt"] = Int((now.timeIntervalSince1970 + expiresIn) * 1_000)
        }
        if let refreshToken = JSON.string(refreshed["refresh_token"]) {
            oauth["refreshToken"] = refreshToken
        }
        if let scope = JSON.string(refreshed["scope"]) {
            oauth["scopes"] = scope.split(separator: " ").map(String.init)
        }
        root["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: root)
    }

    public static func windows(from data: Data) throws -> [UsageWindow] {
        let root = try JSON.object(data)
        var windows: [UsageWindow] = []
        if let session = window(root["five_hour"], kind: .session) { windows.append(session) }
        if let weekly = window(root["seven_day"], kind: .weekly) { windows.append(weekly) }

        var modelWindows: [UsageWindow] = []
        func addModel(_ rawName: String, usedPercent: Double, resetsAt: Date?) {
            let name = Formatting.capitalized(rawName)
            let exists = modelWindows.contains { window in
                if case .weeklyModel(let existing) = window.kind {
                    return existing.caseInsensitiveCompare(name) == .orderedSame
                }
                return false
            }
            guard !name.isEmpty, !exists else { return }
            modelWindows.append(UsageWindow(kind: .weeklyModel(name), usedPercent: usedPercent, resetsAt: resetsAt))
        }

        if let limits = root["limits"] as? [Any] {
            for case let limit as [String: Any] in limits where JSON.string(limit["kind"]) == "weekly_scoped" {
                let model = JSON.dict(JSON.dict(limit["scope"])?["model"])
                guard let name = JSON.string(model?["display_name"]),
                      let percent = JSON.number(limit["percent"])
                else { continue }
                addModel(name, usedPercent: percent, resetsAt: Timestamp.date(limit["resets_at"]))
            }
        }

        for key in ["fable_weekly", "fable_seven_day"] {
            if let fable = window(root[key], kind: .weeklyModel("Fable")) {
                addModel("Fable", usedPercent: fable.usedPercent, resetsAt: fable.resetsAt)
            }
        }

        for model in modelWeeklyKeys {
            if let scoped = window(root["seven_day_\(model)"], kind: .weeklyModel(model)) {
                addModel(model, usedPercent: scoped.usedPercent, resetsAt: scoped.resetsAt)
            }
        }

        return windows + modelWindows
    }

    private static func window(_ value: Any?, kind: UsageWindow.Kind) -> UsageWindow? {
        guard let raw = JSON.dict(value),
              let used = JSON.number(raw["utilization"]) ?? JSON.number(raw["used_percentage"])
        else { return nil }
        return UsageWindow(kind: kind, usedPercent: used, resetsAt: Timestamp.date(raw["resets_at"]))
    }
}

struct ClaudeFetcher {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    let account: Account

    func fetch() async throws -> ProviderSnapshot {
        guard let home = account.home else { return try await fetchSharedLogin() }
        return try await fetchManaged(home: home)
    }

    private func fetchSharedLogin() async throws -> ProviderSnapshot {
        guard var credentials = await SharedClaudeLogin.read() else {
            throw ProviderIssue.signedOut(String(localized: "Not signed in to Claude Code. Run `claude` in a terminal."))
        }
        let expired = ProviderIssue.sessionExpired(String(localized: "The Claude Code session expired and could not be renewed automatically. Run `claude` in a terminal."))
        if credentials.isExpiring(at: Date()) {
            guard let renewed = await SharedClaudeLogin.renew(replacing: credentials.accessToken) else { throw expired }
            credentials = renewed
        }
        do {
            return try await snapshot(credentials)
        } catch ProviderIssue.http(let status) where status == 401 || status == 403 {
            guard let renewed = await SharedClaudeLogin.renew(replacing: credentials.accessToken) else { throw expired }
            do {
                return try await snapshot(renewed)
            } catch ProviderIssue.http(let status) where status == 401 || status == 403 {
                throw expired
            }
        }
    }

    private func fetchManaged(home: URL) async throws -> ProviderSnapshot {
        let store = ManagedClaudeCredentials(home: home)
        guard var stored = await store.read(), var credentials = ClaudeParser.credentials(from: stored) else {
            throw ProviderIssue.signedOut(String(localized: "Credentials not found: unlink and relink the account."))
        }
        if credentials.isExpiring(at: Date()), let refreshed = await refresh(stored, store: store) {
            (stored, credentials) = refreshed
        }
        do {
            return try await snapshot(credentials)
        } catch ProviderIssue.http(let status) where status == 401 || status == 403 {
            guard let refreshed = await refresh(stored, store: store) else {
                throw ProviderIssue.sessionExpired(String(localized: "Session expired: unlink and relink the account."))
            }
            return try await snapshot(refreshed.1)
        }
    }

    private func refresh(_ stored: Data, store: ManagedClaudeCredentials) async -> (Data, ClaudeCredentials)? {
        guard let refreshToken = ClaudeParser.credentials(from: stored)?.refreshToken,
              let response = try? await HTTP.postForm(Self.tokenURL, fields: [
                  "grant_type": "refresh_token",
                  "refresh_token": refreshToken,
                  "client_id": Self.clientID,
              ]),
              let updated = ClaudeParser.applyingRefresh(response, to: stored),
              let credentials = ClaudeParser.credentials(from: updated)
        else { return nil }
        await store.write(updated)
        return (updated, credentials)
    }

    private func snapshot(_ credentials: ClaudeCredentials) async throws -> ProviderSnapshot {
        let data = try await HTTP.get(Self.usageURL, headers: [
            "Authorization": "Bearer \(credentials.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.0",
        ])
        let windows = try ClaudeParser.windows(from: data)
        guard !windows.isEmpty else {
            throw ProviderIssue.noQuota(String(localized: "This account has no subscription limits."))
        }
        return ProviderSnapshot(provider: .claude, plan: credentials.plan ?? account.plan, account: account.email, windows: windows)
    }
}

struct ManagedClaudeCredentials {
    let home: URL

    var service: String { Keychain.scopedClaudeService(configDirectory: home) }
    private var file: URL { home.appending(path: ".credentials.json") }

    func read() async -> Data? {
        if let data = await Keychain.read(service: service) { return data }
        return try? Data(contentsOf: file)
    }

    func write(_ data: Data) async {
        if FileManager.default.fileExists(atPath: file.path) {
            try? data.write(to: file, options: .atomic)
        } else {
            await Keychain.write(service: service, data: data)
        }
    }
}

// The shared Claude Code login is owned by the CLI: Quota never refreshes it itself, because the
// refresh token rotates and a running Claude Code would be signed out. Instead it briefly starts
// `claude`, which renews its own token in the Keychain, and waits for the new token to appear.
enum SharedClaudeLogin {
    private static let gate = RenewalGate()

    static func read() async -> ClaudeCredentials? {
        let stored = await Keychain.read(service: Keychain.claudeService)
            ?? (try? Data(contentsOf: LocalFiles.home.appending(path: ".claude/.credentials.json")))
        return stored.flatMap(ClaudeParser.credentials)
    }

    static func renew(replacing token: String) async -> ClaudeCredentials? {
        await gate.renew {
            guard let executable = await CLI.locate(.claude) else { return nil }
            let session = Task {
                _ = try? await CommandRunner.run(
                    URL(filePath: "/usr/bin/script"),
                    ["-q", "/dev/null", executable.path],
                    environment: ["CLAUDE_CONFIG_DIR": nil],
                    timeout: 45,
                    keepStdinOpen: true
                )
            }
            defer { session.cancel() }
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                if let credentials = await read(), credentials.accessToken != token, !credentials.isExpiring(at: Date()) {
                    return credentials
                }
            }
            return nil
        }
    }
}

private actor RenewalGate {
    private static let cooldown: TimeInterval = 10 * 60
    private var inFlight: Task<ClaudeCredentials?, Never>?
    private var lastFailure: Date?

    func renew(_ operation: @escaping @Sendable () async -> ClaudeCredentials?) async -> ClaudeCredentials? {
        if let inFlight { return await inFlight.value }
        if let lastFailure, Date().timeIntervalSince(lastFailure) < Self.cooldown { return nil }
        let task = Task { await operation() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        lastFailure = result == nil ? Date() : nil
        return result
    }
}
