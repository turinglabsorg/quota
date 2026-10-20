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

    /// Same JSON body Claude Code posts to the token endpoint. `scopes` is omitted when the stored
    /// login has none, so the server keeps the grant's existing scopes.
    public static func refreshRequest(refreshToken: String, scopes: [String], clientID: String) -> Data? {
        var fields: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        if !scopes.isEmpty {
            fields["scope"] = scopes.joined(separator: " ")
        }
        return try? JSONSerialization.data(withJSONObject: fields)
    }

    public static func scopes(from stored: Data) -> [String] {
        guard let root = try? JSON.object(stored),
              let oauth = JSON.dict(root["claudeAiOauth"])
        else { return [] }
        if let scopes = oauth["scopes"] as? [String] {
            return scopes.compactMap { JSON.string($0) }
        }
        guard let scopes = oauth["scopes"] as? [Any] else { return [] }
        return scopes.compactMap { JSON.string($0) }
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
    fileprivate static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    fileprivate static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    let account: Account

    func fetch() async throws -> ProviderSnapshot {
        try await ClaudeUsageGate().fetch(account: account) { retryAfter in
            guard let home = account.home else { return try await fetchSharedLogin(retryAfter: retryAfter) }
            return try await fetchManaged(home: home, retryAfter: retryAfter)
        }
    }

    private func fetchSharedLogin(retryAfter: RetryAfter) async throws -> ProviderSnapshot {
        guard var credentials = await SharedClaudeLogin.read() else {
            throw ProviderIssue.signedOut(String(localized: "Not signed in to Claude Code. Run `claude` in a terminal."))
        }
        let expired = ProviderIssue.sessionExpired(String(localized: "The Claude Code session expired and could not be renewed automatically. Run `claude` in a terminal."))
        if credentials.isExpiring(at: Date()) {
            switch await SharedClaudeLogin.renew(replacing: credentials.accessToken) {
            case .current(let fresh):
                credentials = fresh
            case .rateLimited:
                if let expiresAt = credentials.expiresAt, expiresAt <= Date() {
                    throw ProviderIssue.rateLimited
                }
                // The access token can still be accepted during the early-expiry window. A dead
                // token comes back 401 and the card keeps the last snapshot until the backoff ends.
                do {
                    return try await snapshot(credentials, retryAfter: retryAfter)
                } catch ProviderIssue.http(let status) where status == 401 || status == 403 {
                    throw ProviderIssue.rateLimited
                }
            case .failed:
                throw expired
            }
        }
        do {
            return try await snapshot(credentials, retryAfter: retryAfter)
        } catch ProviderIssue.http(let status) where status == 401 || status == 403 {
            let renewed = try await renewed(replacing: credentials.accessToken, expired: expired)
            do {
                return try await snapshot(renewed, retryAfter: retryAfter)
            } catch ProviderIssue.http(let status) where status == 401 || status == 403 {
                throw expired
            }
        }
    }

    private func renewed(replacing token: String, expired: ProviderIssue) async throws -> ClaudeCredentials {
        switch await SharedClaudeLogin.renew(replacing: token) {
        case .current(let credentials): return credentials
        case .rateLimited: throw ProviderIssue.rateLimited
        case .failed: throw expired
        }
    }

    private func fetchManaged(home: URL, retryAfter: RetryAfter) async throws -> ProviderSnapshot {
        let store = ManagedClaudeCredentials(home: home)
        guard var stored = await store.read(), var credentials = ClaudeParser.credentials(from: stored) else {
            throw ProviderIssue.signedOut(String(localized: "Credentials not found: unlink and relink the account."))
        }
        var attemptedRefresh = false
        if credentials.isExpiring(at: Date()) {
            attemptedRefresh = true
            if let refreshed = try await refresh(stored, store: store, retryAfter: retryAfter) {
                (stored, credentials) = refreshed
            }
        }
        do {
            return try await snapshot(credentials, retryAfter: retryAfter)
        } catch ProviderIssue.http(let status) where status == 401 || status == 403 {
            guard !attemptedRefresh, let refreshed = try await refresh(stored, store: store, retryAfter: retryAfter) else {
                throw ProviderIssue.sessionExpired(String(localized: "Session expired: unlink and relink the account."))
            }
            return try await snapshot(refreshed.1, retryAfter: retryAfter)
        }
    }

    private func refresh(_ stored: Data, store: ManagedClaudeCredentials, retryAfter: RetryAfter) async throws -> (Data, ClaudeCredentials)? {
        guard let refreshToken = ClaudeParser.credentials(from: stored)?.refreshToken,
              let body = ClaudeParser.refreshRequest(refreshToken: refreshToken, scopes: ClaudeParser.scopes(from: stored), clientID: Self.clientID)
        else { return nil }
        let response: Data
        do {
            response = try await HTTP.postJSON(Self.tokenURL, body: body, headers: ["Accept": "application/json"], logBody: false, retryAfter: retryAfter)
        } catch ProviderIssue.rateLimited {
            throw ProviderIssue.rateLimited
        } catch {
            return nil
        }
        guard let updated = ClaudeParser.applyingRefresh(response, to: stored),
              let credentials = ClaudeParser.credentials(from: updated)
        else { return nil }
        await store.write(updated)
        return (updated, credentials)
    }

    private func snapshot(_ credentials: ClaudeCredentials, retryAfter: RetryAfter) async throws -> ProviderSnapshot {
        let data = try await HTTP.get(Self.usageURL, headers: [
            "Authorization": "Bearer \(credentials.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.0",
        ], retryAfter: retryAfter)
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
    private var file: URL { home.appendingPathComponent(".credentials.json") }

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

struct SharedClaudeCredentials: Equatable {
    var credentials: ClaudeCredentials
    /// File payload to write over a Keychain item that has no access token. Claude Code treats any
    /// Keychain hit as the login, so a blank item hides `~/.claude/.credentials.json`.
    var keychainRepair: Data?
}

enum SharedClaudeRenewal: Sendable {
    case current(ClaudeCredentials)
    /// The token endpoint asked us to wait. The stored login is left untouched.
    case rateLimited
    /// The saved session was rejected, or it could not be written back. Nothing was cleared.
    case failed
}

// Renews the shared Claude Code login at the same token endpoint the CLI uses, then writes the
// rotated refresh token to every store Claude reads before returning. Launching `claude` to renew
// is not safe: on `invalid_grant` the CLI clears the Keychain item, which hides the credentials file.
enum SharedClaudeLogin {
    private static let gate = RenewalGate()
    private static let userAgent = "claude-code/2.1.0"

    static func select(keychain: Data?, file: Data?) -> SharedClaudeCredentials? {
        if let keychain, let credentials = ClaudeParser.credentials(from: keychain) {
            return SharedClaudeCredentials(credentials: credentials, keychainRepair: nil)
        }
        guard let file, let credentials = ClaudeParser.credentials(from: file) else { return nil }
        return SharedClaudeCredentials(credentials: credentials, keychainRepair: keychain == nil ? nil : file)
    }

    static func read() async -> ClaudeCredentials? {
        let keychain = await Keychain.read(service: Keychain.claudeService)
        let file = try? Data(contentsOf: LocalFiles.home.appendingPathComponent(".claude/.credentials.json"))
        guard let selected = select(keychain: keychain, file: file) else { return nil }
        if let repair = selected.keychainRepair {
            await Keychain.write(service: Keychain.claudeService, data: repair)
        }
        return selected.credentials
    }

    static func renew(replacing token: String) async -> SharedClaudeRenewal {
        await gate.renew {
            let keychain = await Keychain.read(service: Keychain.claudeService)
            let directory = LocalFiles.home.appendingPathComponent(".claude")
            let file = try? Data(contentsOf: directory.appendingPathComponent(".credentials.json"))
            let stored = storedPayload(keychain: keychain, file: file)
            guard let stored, let credentials = ClaudeParser.credentials(from: stored) else { return .failed }
            if credentials.accessToken != token, !credentials.isExpiring(at: Date()) {
                return .current(credentials)
            }
            guard let refreshToken = credentials.refreshToken,
                  let body = ClaudeParser.refreshRequest(
                    refreshToken: refreshToken,
                    scopes: ClaudeParser.scopes(from: stored),
                    clientID: ClaudeFetcher.clientID
                  )
            else { return .failed }
            if ClaudeTokenBackoff.isCoolingDown() {
                if ProcessInfo.processInfo.environment["QUOTA_DEBUG"] != nil {
                    FileHandle.standardError.write(Data("[Claude token] cooldown active; no HTTP request\n".utf8))
                }
                return .rateLimited
            }
            let response: Data
            let retryAfter = RetryAfter()
            do {
                response = try await HTTP.postJSON(ClaudeFetcher.tokenURL, body: body, headers: [
                    "Accept": "application/json",
                    "User-Agent": userAgent,
                ], logBody: false, retryAfter: retryAfter)
            } catch ProviderIssue.rateLimited {
                // Retrying every few minutes keeps the token endpoint limited, so the saved
                // access token stays expired and the card keeps showing the last snapshot.
                ClaudeTokenBackoff.recordLimit(retryAfter: retryAfter.seconds)
                return .rateLimited
            } catch {
                return .failed
            }
            guard let updated = ClaudeParser.applyingRefresh(response, to: stored),
                  let refreshed = ClaudeParser.credentials(from: updated),
                  !refreshed.isExpiring(at: Date())
            else { return .failed }
            guard await persist(updated, previousRefresh: refreshToken, directory: directory) else { return .failed }
            ClaudeTokenBackoff.clear()
            return .current(refreshed)
        }
    }

    private static func storedPayload(keychain: Data?, file: Data?) -> Data? {
        if let keychain, ClaudeParser.credentials(from: keychain) != nil { return keychain }
        return file
    }

    /// Writes the rotated login to the credentials file and to each Keychain item that still holds
    /// the refresh token the server just consumed. A stale copy would fail with `invalid_grant`
    /// and Claude would clear it.
    private static func persist(_ data: Data, previousRefresh: String, directory: URL) async -> Bool {
        let file = directory.appendingPathComponent(".credentials.json")
        var wroteFile = false
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                wroteFile = true
            } catch {
                wroteFile = false
            }
        }
        let wroteKeychain = await Keychain.write(service: Keychain.claudeService, data: data)
        if !wroteKeychain, wroteFile {
            await Keychain.delete(service: Keychain.claudeService)
        }
        let scoped = Keychain.scopedClaudeService(configDirectory: directory)
        if let existing = await Keychain.read(service: scoped),
           ClaudeParser.credentials(from: existing)?.refreshToken == previousRefresh {
            _ = await Keychain.write(service: scoped, data: data)
        }
        return wroteFile || wroteKeychain
    }
}

private actor RenewalGate {
    private static let cooldown: TimeInterval = 10 * 60
    private var inFlight: Task<SharedClaudeRenewal, Never>?
    private var lastFailure: (date: Date, result: SharedClaudeRenewal)?

    func renew(_ operation: @escaping @Sendable () async -> SharedClaudeRenewal) async -> SharedClaudeRenewal {
        if let inFlight { return await inFlight.value }
        if let lastFailure, Date().timeIntervalSince(lastFailure.date) < Self.cooldown { return lastFailure.result }
        let task = Task { await operation() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        switch result {
        case .current: lastFailure = nil
        case .failed: lastFailure = (Date(), result)
        case .rateLimited: lastFailure = nil
        }
        return result
    }
}

/// How long to wait before asking the Claude token endpoint again.
/// The wait is on disk so a relaunch does not start the retry storm over.
enum ClaudeTokenBackoff {
    struct State: Codable, Equatable {
        var attempts: Int
        var notBefore: TimeInterval
    }

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quota")
            .appendingPathComponent("claude-token-backoff.json")
    }

    /// `attempt` is how many limits have already been recorded. No `Retry-After` grows
    /// 30 minutes, 1 hour, 2, 4, 8, then 12.
    static func delay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter, retryAfter.isFinite, retryAfter > 0 {
            return min(max(retryAfter, 60), 12 * 3_600)
        }
        let minutes = [30, 60, 120, 240, 480, 720]
        return TimeInterval(minutes[min(max(attempt, 0), minutes.count - 1)] * 60)
    }

    static func load(from url: URL = file) -> State? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    static func isCoolingDown(at now: Date = Date(), from url: URL = file) -> Bool {
        guard let state = load(from: url) else { return false }
        return state.notBefore > now.timeIntervalSince1970
    }

    static func recordLimit(retryAfter: TimeInterval?, now: Date = Date(), to url: URL = file) {
        let attempt = load(from: url)?.attempts ?? 0
        let state = State(
            attempts: attempt + 1,
            notBefore: now.timeIntervalSince1970 + delay(attempt: attempt, retryAfter: retryAfter)
        )
        save(state, to: url)
    }

    static func clear(at url: URL = file) {
        save(nil, to: url)
    }

    static func save(_ state: State?, to url: URL) {
        if state == nil {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
