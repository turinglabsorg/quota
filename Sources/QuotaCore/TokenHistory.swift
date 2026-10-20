import CryptoKit
import Darwin
import Foundation

public struct TokenAmounts: Codable, Equatable, Sendable {
    public var input: Int = 0
    public var output: Int = 0
    public var cached: Int = 0
    public var cacheWrite: Int = 0
    public var reasoning: Int = 0
    public var total: Int { input + output }

    public init(input: Int = 0, output: Int = 0, cached: Int = 0, cacheWrite: Int = 0, reasoning: Int = 0) {
        self.input = input
        self.output = output
        self.cached = cached
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, output: lhs.output + rhs.output, cached: lhs.cached + rhs.cached,
             cacheWrite: lhs.cacheWrite + rhs.cacheWrite, reasoning: lhs.reasoning + rhs.reasoning)
    }

    func maximum(_ other: Self) -> Self {
        Self(input: max(input, other.input), output: max(output, other.output), cached: max(cached, other.cached),
             cacheWrite: max(cacheWrite, other.cacheWrite), reasoning: max(reasoning, other.reasoning))
    }

    func subtracting(_ other: Self) -> Self {
        Self(input: max(0, input - other.input), output: max(0, output - other.output), cached: max(0, cached - other.cached),
             cacheWrite: max(0, cacheWrite - other.cacheWrite), reasoning: max(0, reasoning - other.reasoning))
    }
}

public struct TokenActivityDay: Equatable, Sendable, Identifiable {
    public let date: Date
    public var providers: [Provider: TokenAmounts]
    public var id: Date { date }
    public func amounts(provider: Provider?) -> TokenAmounts {
        if let provider { return providers[provider] ?? TokenAmounts() }
        return providers.values.reduce(TokenAmounts(), +)
    }

    public init(date: Date, providers: [Provider: TokenAmounts]) {
        self.date = date
        self.providers = providers
    }
}

public struct TokenHistory: Equatable, Sendable {
    public var days: [TokenActivityDay]
    public var availableProviders: [Provider]
    public var unreadableFiles: Int
    public var total: TokenAmounts { days.reduce(TokenAmounts()) { $0 + $1.amounts(provider: nil) } }

    public init(days: [TokenActivityDay] = [], availableProviders: [Provider] = [], unreadableFiles: Int = 0) {
        self.days = days
        self.availableProviders = availableProviders
        self.unreadableFiles = unreadableFiles
    }

    public static func load(accounts: [Account], now: Date = Date()) -> Self {
        let home = LocalFiles.home
        let linked = Set(accounts.map(\.provider))
        var sources: [HistorySource] = []
        func add(_ provider: Provider, _ path: String) {
            if linked.contains(provider) { sources.append(HistorySource(provider: provider, root: home.appendingPathComponent(path))) }
        }
        add(.claude, ".claude/projects")
        add(.codex, ".codex/sessions")
        add(.codex, ".codex/archived_sessions")
        add(.grok, ".grok/sessions")
        if linked.contains(.musecode) { sources.append(HistorySource(provider: .musecode, root: MuseLogs.sessionsRoot())) }
        for account in accounts {
            guard let root = account.home else { continue }
            switch account.provider {
            case .claude: sources.append(HistorySource(provider: .claude, root: root.appendingPathComponent("projects")))
            case .codex:
                sources.append(HistorySource(provider: .codex, root: root.appendingPathComponent("sessions")))
                sources.append(HistorySource(provider: .codex, root: root.appendingPathComponent("archived_sessions")))
            case .grok: sources.append(HistorySource(provider: .grok, root: root.appendingPathComponent("sessions")))
            default: break
            }
        }
        return load(sources: sources, now: now, cache: AccountPaths.root.deletingLastPathComponent().appendingPathComponent("TokenActivity/index-v2.json"))
    }

    static func load(sources: [HistorySource], now: Date, cache: URL, calendar: Calendar = .current) -> Self {
        let today = calendar.startOfDay(for: now)
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7
        let start = calendar.date(byAdding: .day, value: -77 - weekday, to: today) ?? today
        let prior = (try? Data(contentsOf: cache)).flatMap { try? JSONDecoder().decode([String: HistoryFile].self, from: $0) } ?? [:]
        var files: [String: HistoryFile] = [:]
        var available = Set<Provider>()
        var unreadable = 0
        var events: [String: HistoryEvent] = [:]
        for source in sources {
            guard FileManager.default.fileExists(atPath: source.root.path) else { continue }
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            guard let enumerator = FileManager.default.enumerator(at: source.root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, _ in unreadable += 1; return true }) else { continue }
            for case let url as URL in enumerator {
                guard source.accepts(url), let properties = try? url.resourceValues(forKeys: Set(keys)), properties.isRegularFile == true,
                      let size = properties.fileSize, let modified = properties.contentModificationDate,
                      modified >= start.addingTimeInterval(-86_400)
                else { continue }
                let key = historyHash("\(source.provider.rawValue):\(url.standardizedFileURL.path)")
                var file: HistoryFile
                if let cached = prior[key], cached.size == size, cached.modified == modified {
                    file = cached
                } else {
                    guard let parsed = HistoryParser.parse(url, provider: source.provider) else { unreadable += 1; continue }
                    file = HistoryFile(size: size, modified: modified, events: parsed)
                }
                file.events = file.events.filter { $0.date >= start }
                files[key] = file
                if file.events.contains(where: { $0.date <= now.addingTimeInterval(0.001) }) { available.insert(source.provider) }
                for event in file.events where event.date <= now.addingTimeInterval(0.001) {
                    if var existing = events[event.id] {
                        existing.amounts = existing.amounts.maximum(event.amounts)
                        existing.date = min(existing.date, event.date)
                        events[event.id] = existing
                    } else { events[event.id] = event }
                }
            }
        }
        var buckets: [Date: [Provider: TokenAmounts]] = [:]
        for event in events.values {
            let day = calendar.startOfDay(for: event.date)
            buckets[day, default: [:]][event.provider, default: TokenAmounts()] = (buckets[day]?[event.provider] ?? TokenAmounts()) + event.amounts
        }
        let days = (0..<84).compactMap { offset -> TokenActivityDay? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return TokenActivityDay(date: day, providers: buckets[day] ?? [:])
        }
        if let data = try? JSONEncoder().encode(files) { try? MuseQuotaCache.save(data, to: cache) }
        return Self(days: days, availableProviders: Provider.allCases.filter { available.contains($0) }, unreadableFiles: unreadable)
    }
}

struct HistorySource {
    var provider: Provider
    var root: URL
    func accepts(_ url: URL) -> Bool {
        guard url.pathExtension == "jsonl" else { return false }
        switch provider {
        case .claude: return true
        case .codex: return url.lastPathComponent.hasPrefix("rollout-")
        case .grok: return url.lastPathComponent == "updates.jsonl"
        case .musecode: return url.lastPathComponent == "session.jsonl"
        case .ollama: return false
        }
    }
}

private struct HistoryFile: Codable {
    var size: Int
    var modified: Date
    var events: [HistoryEvent]
}

struct HistoryEvent: Codable {
    var id: String
    var provider: Provider
    var date: Date
    var amounts: TokenAmounts
}

func historyHash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

enum HistoryParser {
    static func parse(_ url: URL, provider: Provider) -> [HistoryEvent]? {
        guard let handle = fopen(url.path, "r") else { return nil }
        defer { fclose(handle) }
        var line: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(line) }
        var records: [String: HistoryEvent] = [:]
        var codexTotals = TokenAmounts()
        var modernCodexSeen = false
        var session = url.deletingPathExtension().lastPathComponent
        while true {
            let length = getline(&line, &capacity, handle)
            guard length >= 0, let line else { break }
            guard length < 16 * 1_024 * 1_024 else { continue }
            let candidate: Bool
            switch provider {
            case .claude: candidate = strstr(line, "\"usage\"") != nil
            case .codex: candidate = strstr(line, "\"token_count\"") != nil || strstr(line, "\"token_usage_record\"") != nil || strstr(line, "\"session_meta\"") != nil
            case .grok: candidate = strstr(line, "\"turn_completed\"") != nil
            case .musecode: candidate = strstr(line, "\"model_completed\"") != nil
            case .ollama: candidate = false
            }
            guard candidate, let root = try? JSON.object(Data(bytes: line, count: length)) else { continue }
            if provider == .codex {
                if JSON.string(root["type"]) == "token_usage_record" {
                    modernCodexSeen = true
                } else if modernCodexSeen {
                    // Legacy counters can have a different baseline from thread counters.
                    continue
                }
            }
            if provider == .codex, JSON.string(root["type"]) == "session_meta" {
                session = JSON.string(JSON.dict(root["payload"])?["id"]) ?? session
                continue
            }
            guard let event = event(root, provider: provider, session: session, path: url.path, codexTotals: &codexTotals), event.amounts.total > 0 else { continue }
            if var existing = records[event.id] {
                existing.amounts = existing.amounts.maximum(event.amounts)
                existing.date = min(existing.date, event.date)
                records[event.id] = existing
            } else { records[event.id] = event }
        }
        return Array(records.values)
    }

    static func event(_ root: [String: Any], provider: Provider, session: String, path: String, codexTotals: inout TokenAmounts) -> HistoryEvent? {
        let date: Date
        let usage: [String: Any]
        let identity: String
        let amounts: TokenAmounts
        switch provider {
        case .claude:
            guard JSON.string(root["type"]) == "assistant", let message = JSON.dict(root["message"]),
                  let value = JSON.dict(message["usage"]), let at = Timestamp.date(root["timestamp"]),
                  let id = JSON.string(message["id"]) ?? JSON.string(root["uuid"])
            else { return nil }
            date = at
            usage = value
            identity = id
            let read = count(usage["cache_read_input_tokens"])
            let write = count(usage["cache_creation_input_tokens"])
            amounts = TokenAmounts(input: count(usage["input_tokens"]) + read + write, output: count(usage["output_tokens"]), cached: read, cacheWrite: write)
        case .codex:
            guard let payload = JSON.dict(root["payload"]), let at = Timestamp.date(root["timestamp"]) else { return nil }
            let info = JSON.dict(payload["info"])
            let modern = JSON.string(root["type"]) == "token_usage_record"
            guard modern || JSON.string(payload["type"]) == "token_count",
                  let total = JSON.dict(modern ? payload["thread_token_usage"] : info?["total_token_usage"])
            else { return nil }
            date = at
            usage = total
            let cumulative = standard(usage)
            if modern, let perCall = JSON.dict(payload["usage"]) {
                amounts = standard(perCall)
            } else if cumulative.input < codexTotals.input || cumulative.output < codexTotals.output {
                amounts = standard(JSON.dict(modern ? payload["usage"] : info?["last_token_usage"]) ?? [:])
            } else {
                amounts = cumulative.subtracting(codexTotals)
            }
            codexTotals = cumulative
            let thread = JSON.string(payload["thread_id"]) ?? session
            if modern, let response = JSON.string(payload["response_id"]) { identity = response }
            else { identity = "\(thread):\(cumulative.input):\(cumulative.output):\(at.timeIntervalSince1970)" }
        case .grok:
            guard let update = JSON.dict(JSON.dict(root["params"])?["update"]), JSON.string(update["sessionUpdate"]) == "turn_completed",
                  let value = JSON.dict(update["usage"]), let at = Timestamp.date(root["timestamp"])
            else { return nil }
            date = at
            usage = value
            identity = "\(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent):\(JSON.string(update["prompt_id"]) ?? String(at.timeIntervalSince1970))"
            amounts = TokenAmounts(input: count(usage["inputTokens"]), output: count(usage["outputTokens"]), cached: count(usage["cachedReadTokens"]), cacheWrite: count(usage["cacheCreationTokens"]), reasoning: count(usage["reasoningTokens"]))
        case .musecode:
            guard let event = JSON.dict(JSON.dict(root["payload"])?["event"]), JSON.string(event["kind"]) == "model_completed",
                  let value = JSON.dict(event["usage"]), let recorded = JSON.number(root["recorded_at"])
            else { return nil }
            date = Date(timeIntervalSince1970: recorded / 1_000_000)
            usage = value
            identity = "\(JSON.string(JSON.dict(root["stream"])?["id"]) ?? path):\(recorded)"
            amounts = standard(usage)
        case .ollama: return nil
        }
        return HistoryEvent(id: historyHash("\(provider.rawValue):\(identity)"), provider: provider, date: date, amounts: amounts)
    }

    static func standard(_ usage: [String: Any]) -> TokenAmounts {
        TokenAmounts(input: count(usage["input_tokens"]), output: count(usage["output_tokens"]),
            cached: count(usage["cached_input_tokens"] ?? usage["cached_tokens"] ?? usage["cache_read_tokens"]),
            cacheWrite: count(usage["cache_write_input_tokens"] ?? usage["cache_write_tokens"]),
            reasoning: count(usage["reasoning_output_tokens"] ?? usage["reasoning_tokens"]))
    }

    static func count(_ value: Any?) -> Int {
        guard let number = JSON.number(value), number >= 0, number < 1e15 else { return 0 }
        return Int(number)
    }
}
