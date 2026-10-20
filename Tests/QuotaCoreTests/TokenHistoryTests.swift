import Foundation
import Testing
@testable import QuotaCore

@Suite struct TokenHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func claudeStreamingAndCopiedSessionsCountOnceAndIncludeCache() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = #"{"type":"assistant","timestamp":"2027-01-15T07:00:00Z","message":{"id":"m1","content":"private-prompt-fixture","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":200,"cache_creation_input_tokens":50}}}"#
        let final = first.replacingOccurrences(of: "\"output_tokens\":10", with: "\"output_tokens\":15")
        try write(root.appendingPathComponent("a.jsonl"), lines: [first, final])
        try write(root.appendingPathComponent("copy.jsonl"), lines: [first, final])
        let history = TokenHistory.load(sources: [HistorySource(provider: .claude, root: root)], now: now, cache: root.appendingPathComponent("cache.json"))
        #expect(history.total == TokenAmounts(input: 350, output: 15, cached: 200, cacheWrite: 50))
        #expect(history.availableProviders == [.claude])
        let cache = try String(contentsOf: root.appendingPathComponent("cache.json"), encoding: .utf8)
        #expect(!cache.contains("private-prompt-fixture"))
        #expect(!cache.contains("m1"))
    }

    @Test func codexLegacyDuplicatesAndCounterResetsDoNotInflateTotals() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = [
            #"{"type":"session_meta","payload":{"id":"session-1"}}"#,
            #"{"type":"event_msg","timestamp":"2027-01-15T06:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"cached_input_tokens":80}}}}"#,
            #"{"type":"event_msg","timestamp":"2027-01-15T06:00:01Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"cached_input_tokens":80}}}}"#,
            #"{"type":"event_msg","timestamp":"2027-01-15T06:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"output_tokens":30,"cached_input_tokens":200}}}}"#,
            #"{"type":"event_msg","timestamp":"2027-01-15T06:05:01Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"output_tokens":30,"cached_input_tokens":200}}}}"#,
            #"{"type":"event_msg","timestamp":"2027-01-15T06:10:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"output_tokens":5,"cached_input_tokens":20},"last_token_usage":{"input_tokens":20,"output_tokens":5,"cached_input_tokens":10}}}}"#,
        ]
        try write(root.appendingPathComponent("rollout-main.jsonl"), lines: lines)
        try write(root.appendingPathComponent("rollout-copy.jsonl"), lines: lines)
        let history = TokenHistory.load(sources: [HistorySource(provider: .codex, root: root)], now: now, cache: root.appendingPathComponent("cache.json"))
        #expect(history.total == TokenAmounts(input: 270, output: 35, cached: 210))
    }

    @Test func codexModernCallsIgnoreLegacyCountersWithDifferentBaselines() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = [
            #"{"type":"session_meta","payload":{"id":"session-1"}}"#,
            #"{"type":"event_msg","timestamp":"2027-01-15T06:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"cached_input_tokens":80}}}}"#,
            #"{"type":"token_usage_record","timestamp":"2027-01-15T06:01:00Z","payload":{"thread_id":"session-1","response_id":"r1","thread_token_usage":{"input_tokens":160,"output_tokens":15},"usage":{"input_tokens":20,"output_tokens":3,"cached_input_tokens":10}}}"#,
            #"{"type":"event_msg","timestamp":"2027-01-15T06:01:01Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"output_tokens":13},"last_token_usage":{"input_tokens":20,"output_tokens":3}}}}"#,
            #"{"type":"token_usage_record","timestamp":"2027-01-15T06:02:00Z","payload":{"thread_id":"session-1","response_id":"r2","thread_token_usage":{"input_tokens":190,"output_tokens":20},"usage":{"input_tokens":30,"output_tokens":5,"cached_input_tokens":20}}}"#,
            #"{"type":"event_msg","timestamp":"2027-01-15T06:02:01Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"output_tokens":18},"last_token_usage":{"input_tokens":30,"output_tokens":5}}}}"#,
        ]
        try write(root.appendingPathComponent("rollout-main.jsonl"), lines: lines)
        try write(root.appendingPathComponent("rollout-copy.jsonl"), lines: lines)
        let history = TokenHistory.load(sources: [HistorySource(provider: .codex, root: root)], now: now, cache: root.appendingPathComponent("cache.json"))
        #expect(history.total == TokenAmounts(input: 150, output: 18, cached: 110))
    }

    @Test func grokAndMuseIncludeTheirOwnCallsWithoutAddingReasoningTwice() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let grok = root.appendingPathComponent("grok/session-a/updates.jsonl")
        let line = #"{"timestamp":1800000000,"params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"turn-1","usage":{"inputTokens":1000,"outputTokens":100,"cachedReadTokens":900,"reasoningTokens":60}}}}"#
        try write(grok, lines: [line, line])
        let muse = root.appendingPathComponent("muse/session-a/session.jsonl")
        let museLine = #"{"recorded_at":1800000000000000,"stream":{"id":"s1"},"payload":{"event":{"kind":"model_completed","usage":{"input_tokens":500,"output_tokens":50,"cached_tokens":400,"reasoning_tokens":30}}}}"#
        try write(muse, lines: [museLine, museLine])
        let history = TokenHistory.load(sources: [
            HistorySource(provider: .grok, root: root.appendingPathComponent("grok")),
            HistorySource(provider: .musecode, root: root.appendingPathComponent("muse")),
        ], now: now, cache: root.appendingPathComponent("cache.json"))
        #expect(history.total == TokenAmounts(input: 1500, output: 150, cached: 1300, reasoning: 90))
        #expect(history.days.reduce(0) { $0 + $1.amounts(provider: .musecode).total } == 550)
    }

    @Test func cachedReadsAndChangedFilesKeepTheSameDailyTotals() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("a.jsonl")
        let line = #"{"type":"assistant","timestamp":"2027-01-15T07:00:00Z","message":{"id":"m1","usage":{"input_tokens":20,"output_tokens":5}}}"#
        try write(path, lines: [line, "not-json"])
        let sources = [HistorySource(provider: .claude, root: root)]
        let cache = root.appendingPathComponent("cache.json")
        let first = TokenHistory.load(sources: sources, now: now, cache: cache)
        let second = TokenHistory.load(sources: sources, now: now, cache: cache)
        #expect(first == second)
        try write(path, lines: [line, line.replacingOccurrences(of: "m1", with: "m2")])
        let third = TokenHistory.load(sources: sources, now: now, cache: cache)
        #expect(third.total.total == 50)
        #expect(third.days.count == 84)
        var rome = Calendar(identifier: .gregorian)
        rome.timeZone = try #require(TimeZone(identifier: "Europe/Rome"))
        let local = TokenHistory.load(sources: sources, now: now, cache: cache, calendar: rome)
        #expect(rome.component(.weekday, from: try #require(local.days.first).date) == 2)
        #expect(local.days.filter { !$0.providers.isEmpty }.count == 1)
    }

    @Test func futureEventsBecomeVisibleWithoutAFileChangeAndMissingRootsAreNormal() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let line = #"{"type":"assistant","timestamp":"2027-01-15T09:00:00Z","message":{"id":"future","usage":{"input_tokens":20,"output_tokens":5}}}"#
        try write(root.appendingPathComponent("a.jsonl"), lines: [line])
        let sources = [HistorySource(provider: .claude, root: root), HistorySource(provider: .codex, root: root.appendingPathComponent("missing"))]
        let cache = root.appendingPathComponent("cache.json")
        let first = TokenHistory.load(sources: sources, now: now, cache: cache)
        #expect(first.total.total == 0)
        #expect(first.unreadableFiles == 0)
        let later = TokenHistory.load(sources: sources, now: now.addingTimeInterval(7_200), cache: cache)
        #expect(later.total.total == 25)
    }

    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    private func write(_ url: URL, lines: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }
}
