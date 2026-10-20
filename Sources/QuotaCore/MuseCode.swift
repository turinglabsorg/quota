import Foundation

// Muse Code reports the same two bars as accountscenter.meta.com on the key mint the CLI already
// performs: POST https://api.meta.ai/muse-code/key with the Meta account token from the Keychain
// item `ai.meta.dev.credentials` / `meta`. The call is idempotent (the same API key comes back) and
// `subs_usage` is the current 5-hour window plus the weekly window. Quota does not store that key.
// Session logs under ~/.local/share/muse only have token totals, not these percentages.
enum MuseCodeLogin {
    static let service = "ai.meta.dev.credentials"
    static let account = "meta"
    static let keyURL = URL(string: "https://api.meta.ai/muse-code/key")!

    static func accessToken() async -> String? {
        guard let data = await Keychain.read(service: service, account: account) else { return nil }
        return MuseCodeParser.accessToken(from: data)
    }

    /// Email recorded by `muse login` in ~/.config/muse/auth.json. The file holds no tokens.
    static func profileEmail() -> String? {
        let url = LocalFiles.home.appendingPathComponent(".config/muse/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSON.object(data),
              let providers = JSON.dict(root["providers"]),
              let meta = JSON.dict(providers["meta"])
        else { return nil }
        return JSON.string(meta["user_email"])
    }
}

public enum MuseCodeParser {
    public static func accessToken(from data: Data) -> String? {
        guard let root = try? JSON.object(data) else { return nil }
        return JSON.string(root["access_token"])
    }

    /// `subs_tier_name` is "Muse Code High Usage"; the badge shows "High Usage" next to the provider name.
    public static func planLabel(_ name: String?) -> String? {
        guard var name else { return nil }
        let prefix = "Muse Code "
        if name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        return name.isEmpty ? nil : name
    }

    public static func snapshot(from data: Data, fallbackPlan: String? = nil, fallbackEmail: String? = nil) throws -> ProviderSnapshot {
        let root = try JSON.object(data)
        if let active = root["is_subs_active"] as? Bool, !active {
            throw ProviderIssue.noQuota(String(localized: "This Muse Code account has no active subscription."))
        }
        guard let usage = JSON.dict(root["subs_usage"]) else {
            guard root["is_subs_active"] as? Bool == true else { throw ProviderIssue.invalidResponse }
            return ProviderSnapshot(provider: .musecode,
                plan: planLabel(JSON.string(root["subs_tier_name"])) ?? fallbackPlan,
                account: JSON.string(root["user_email"]) ?? fallbackEmail,
                windows: [], issue: .usageUnavailable(String(localized: "Meta has not returned the subscription usage yet.")))
        }
        var windows: [UsageWindow] = []
        if let window = JSON.dict(usage["window"]), let used = JSON.number(window["used_percent"]) {
            let minutes = JSON.number(window["window_duration_mins"]).map { Int($0) }
            let kind: UsageWindow.Kind = minutes == 300 || minutes == nil ? .session : .custom(minutes: minutes ?? 0)
            windows.append(UsageWindow(kind: kind, usedPercent: used, resetsAt: Timestamp.date(window["resets_at"])))
        }
        if let weekly = JSON.dict(usage["weekly"]), let used = JSON.number(weekly["used_percent"]) {
            windows.append(UsageWindow(kind: .weekly, usedPercent: used, resetsAt: Timestamp.date(weekly["resets_at"])))
        }
        guard !windows.isEmpty else {
            throw ProviderIssue.noQuota(String(localized: "This account has no subscription limits."))
        }
        return ProviderSnapshot(
            provider: .musecode,
            plan: planLabel(JSON.string(root["subs_tier_name"])) ?? fallbackPlan,
            account: JSON.string(root["user_email"]) ?? fallbackEmail,
            windows: windows
        )
    }
}

struct MuseCodeFetcher {
    let account: Account

    func fetch(wakeIfIdle: Bool = false) async throws -> ProviderSnapshot {
        let logs = MuseLogs.aggregate()
        if var cached = MuseQuotaCache.read(email: account.email), Date().timeIntervalSince(cached.fetchedAt) < 5 * 60,
           !wakeIfIdle || cached.windows.contains(where: { $0.kind == .session && ($0.resetsAt.map { $0 > Date() } ?? false) }) {
            if logs.hasSteps { cached.tokenUsage = logs.usage }
            return cached
        }
        do {
            var snapshot = try await subscription(wakeIfIdle: wakeIfIdle)
            if snapshot.windows.isEmpty {
                if let cached = MuseQuotaCache.read(email: snapshot.account), !cached.windows.isEmpty {
                    if snapshot.windows.isEmpty {
                        snapshot.windows = cached.windows
                        snapshot.fetchedAt = cached.fetchedAt
                    }
                }
            }
            if logs.hasSteps {
                snapshot.tokenUsage = logs.usage
                if snapshot.plan == nil { snapshot.plan = logs.model }
            }
            MuseQuotaCache.save(snapshot, account: account)
            return snapshot
        } catch let issue as ProviderIssue {
            if ProcessInfo.processInfo.environment["QUOTA_DEBUG"] != nil {
                FileHandle.standardError.write(Data("[Muse Code] subscription unavailable: \(issue.message)\n".utf8))
            }
            var snapshot = (issue.keepsLastSnapshot ? MuseQuotaCache.read(email: account.email) : nil) ?? ProviderSnapshot(
                provider: .musecode,
                plan: account.plan,
                account: account.email,
                windows: [],
                tokenUsage: logs.usage,
                issue: issue
            )
            snapshot.issue = issue
            if logs.hasSteps { snapshot.tokenUsage = logs.usage }
            return snapshot
        }
    }

    private func subscription(wakeIfIdle: Bool) async throws -> ProviderSnapshot {
        guard let token = await MuseCodeLogin.accessToken() else { throw signedOut }
        var data = try await mint(token: token)
        var snapshot = try MuseCodeParser.snapshot(from: data, fallbackPlan: account.plan, fallbackEmail: account.email)
        if wakeIfIdle, snapshot.windows.isEmpty, let email = snapshot.account {
            let request = try MuseIdleWake.request(from: data)
            let didWake = try await MuseIdleWake.run(file: MuseQuotaCache.file(email: email, name: "wake")) {
                _ = try await HTTP.postJSON(request.url, body: request.body, headers: request.headers, logBody: false)
            }
            if didWake {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                data = try await mint(token: token)
                snapshot = try MuseCodeParser.snapshot(from: data, fallbackPlan: snapshot.plan, fallbackEmail: snapshot.account)
            }
        }
        return snapshot
    }

    private func mint(token: String) async throws -> Data {
        let data: Data
        do {
            data = try await HTTP.postJSON(MuseCodeLogin.keyURL, body: Data("{}".utf8), headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "application/json",
                "x-api-version": "1.0.0",
            ], logBody: false)
        } catch ProviderIssue.http(let status) where status == 401 || status == 403 {
            throw ProviderIssue.sessionExpired(String(localized: "Muse Code session expired. Run `muse login`."))
        }
        if ProcessInfo.processInfo.environment["QUOTA_DEBUG"] != nil,
           let root = try? JSON.object(data) {
            let usage = JSON.dict(root["subs_usage"])
            let details = "fields=\(root.keys.sorted()) active=\(String(describing: root["is_subs_active"])) usageFields=\(usage?.keys.sorted() ?? [])"
            FileHandle.standardError.write(Data("[Muse Code] \(details)\n".utf8))
        }
        return data
    }

    private var signedOut: ProviderIssue {
        .signedOut(String(localized: "Not signed in to Muse Code. Run `muse login`."))
    }
}

/// Today's and last-7-days token totals from the `muse` session logs, the same sum Quotax shows.
/// Today resets at the next local midnight. Nothing is sent anywhere.
enum MuseLogs {
    struct Aggregate {
        var usage: [TokenUsage]
        var model: String?
        var hasSteps: Bool { usage.contains { $0.steps > 0 } }
    }

    static func sessionsRoot() -> URL {
        if let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !dataHome.isEmpty {
            return URL(fileURLWithPath: dataHome).appendingPathComponent("muse").appendingPathComponent("sessions")
        }
        return LocalFiles.home
            .appendingPathComponent(".local")
            .appendingPathComponent("share")
            .appendingPathComponent("muse")
            .appendingPathComponent("sessions")
    }

    static func aggregate(root: URL = sessionsRoot(), now: Date = Date()) -> Aggregate {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)
        var today = Bucket()
        var week = Bucket()
        var models: [String: Int] = [:]
        var modelOrder: [String] = []
        let earliest = weekStart.addingTimeInterval(-86_400)
        for log in sessionLogs(root: root, from: earliest, through: now) {
            let session = sessionID(for: log)
            for record in records(in: log) {
                guard record.at >= weekStart, record.at <= now else { continue }
                week.add(record.usage, session: session)
                if record.at >= todayStart { today.add(record.usage, session: session) }
                if let model = record.model {
                    if models[model] == nil { modelOrder.append(model) }
                    models[model, default: 0] += 1
                }
            }
        }
        let model = modelOrder.max { (models[$0] ?? 0) < (models[$1] ?? 0) }
        return Aggregate(usage: [
            today.usage(period: "today", resetsAt: tomorrow),
            week.usage(period: "last7Days", resetsAt: nil),
        ], model: model)
    }

    static func shardNames(from start: Date, through end: Date) -> Set<String> {
        let calendar = Calendar.current
        var names = Set<String>()
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while day <= last {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            if let year = parts.year, let month = parts.month, let dayOfMonth = parts.day {
                names.insert(String(format: "%04d/%02d/%02d", year, month, dayOfMonth))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return names
    }

    static func sessionLogs(root: URL, from start: Date, through end: Date) -> [URL] {
        let shards = shardNames(from: start, through: end)
        let manager = FileManager.default
        guard let years = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var logs: [URL] = []
        for year in years.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard directory(year), let months = try? manager.contentsOfDirectory(at: year, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for month in months.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard directory(month), let days = try? manager.contentsOfDirectory(at: month, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
                for day in days.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let relative = "\(year.lastPathComponent)/\(month.lastPathComponent)/\(day.lastPathComponent)"
                    guard shards.contains(relative), directory(day),
                          let sessions = try? manager.contentsOfDirectory(at: day, includingPropertiesForKeys: [.isDirectoryKey])
                    else { continue }
                    for session in sessions.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                        guard directory(session) else { continue }
                        let main = session.appendingPathComponent("session.jsonl")
                        if manager.fileExists(atPath: main.path) { logs.append(main) }
                        let subagents = session.appendingPathComponent("subagent")
                        guard directory(subagents),
                              let children = try? manager.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil)
                        else { continue }
                        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                            let nested = child.appendingPathComponent("session.jsonl")
                            if manager.fileExists(atPath: nested.path) { logs.append(nested) }
                        }
                    }
                }
            }
        }
        return logs
    }

    /// A subagent log lives in `<session>/subagent/<child>/` and belongs to the parent session.
    static func sessionID(for log: URL) -> String {
        let parent = log.deletingLastPathComponent()
        let grandparent = parent.deletingLastPathComponent()
        if grandparent.lastPathComponent == "subagent" {
            return grandparent.deletingLastPathComponent().lastPathComponent
        }
        return parent.lastPathComponent
    }

    private static func directory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private struct Record {
        var at: Date
        var model: String?
        var usage: [String: Any]
    }

    private static func records(in file: URL) -> [Record] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var found: [Record] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let envelope = try? JSON.object(data),
                  let payload = JSON.dict(envelope["payload"]),
                  let event = JSON.dict(payload["event"]),
                  JSON.string(event["kind"]) == "model_completed",
                  let usage = JSON.dict(event["usage"]),
                  let recorded = JSON.number(envelope["recorded_at"])
            else { continue }
            found.append(Record(at: Date(timeIntervalSince1970: recorded / 1_000_000), model: JSON.string(event["model"]), usage: usage))
        }
        return found
    }

    private struct Bucket {
        var inputTokens = 0
        var outputTokens = 0
        var cachedTokens = 0
        var cacheWriteTokens = 0
        var reasoningTokens = 0
        var steps = 0
        var sessions = Set<String>()

        mutating func add(_ usage: [String: Any], session: String) {
            inputTokens += count(usage["input_tokens"])
            outputTokens += count(usage["output_tokens"])
            let cached = usage["cached_tokens"] ?? usage["cache_read_tokens"]
            cachedTokens += count(cached)
            cacheWriteTokens += count(usage["cache_write_tokens"])
            reasoningTokens += count(usage["reasoning_tokens"])
            steps += 1
            if !session.isEmpty { sessions.insert(session) }
        }

        func usage(period: String, resetsAt: Date?) -> TokenUsage {
            TokenUsage(
                period: period,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedTokens: cachedTokens,
                cacheWriteTokens: cacheWriteTokens,
                reasoningTokens: reasoningTokens,
                sessions: sessions.count,
                steps: steps,
                resetsAt: resetsAt
            )
        }

        private func count(_ value: Any?) -> Int {
            guard let number = JSON.number(value) else { return 0 }
            return max(0, Int(number))
        }
    }
}
