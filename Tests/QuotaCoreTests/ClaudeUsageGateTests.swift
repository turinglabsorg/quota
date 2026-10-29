import Foundation
import Testing
@testable import QuotaCore

@Suite struct ClaudeUsageGateTests {
    private let account = Account(provider: .claude, source: .cli, email: "test@example.com", plan: "Max")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(at date: Date) -> ProviderSnapshot {
        ProviderSnapshot(provider: .claude, plan: "Max", windows: [
            UsageWindow(kind: .weekly, usedPercent: 25, resetsAt: date.addingTimeInterval(86_400)),
        ], fetchedAt: date)
    }

    @Test func concurrentReadersAndRelaunchUseOnePoll() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls()
        let expected = snapshot(at: now)
        let account = account
        let now = now
        try await withThrowingTaskGroup(of: ProviderSnapshot.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await ClaudeUsageGate(directory: directory).fetch(account: account, now: { now }) { _ in
                        await calls.record()
                        try await Task.sleep(nanoseconds: 100_000_000)
                        return expected
                    }
                }
            }
            for try await result in group {
                #expect(result.windows == expected.windows)
                #expect(result.fetchedAt == expected.fetchedAt)
            }
        }
        #expect(await calls.count == 1)
        _ = try await ClaudeUsageGate(directory: directory).fetch(account: account, now: { now.addingTimeInterval(301) }) { _ in
            await calls.record()
            return snapshot(at: now.addingTimeInterval(301))
        }
        #expect(await calls.count == 2)
    }

    @Test func limitsSurviveRelaunchAndGrowUntilSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls()
        let now = now
        for offset in [0.0, 60, 1_799, 1_801, 2_000, 5_400] {
            do {
                _ = try await ClaudeUsageGate(directory: directory).fetch(account: account, now: { now.addingTimeInterval(offset) }) { retry in
                    await calls.record()
                    retry.seconds = 0
                    throw ProviderIssue.rateLimited
                }
                Issue.record("Expected a persisted rate limit")
            } catch ProviderIssue.retryLater(let date) {
                #expect(date > now.addingTimeInterval(offset))
                #expect(IssueUsage(.retryLater(date)).kind == "rateLimited")
            }
        }
        #expect(await calls.count == 2)
        _ = try await ClaudeUsageGate(directory: directory).fetch(account: account, now: { now.addingTimeInterval(5_402) }) { _ in
            await calls.record()
            return snapshot(at: now.addingTimeInterval(5_402))
        }
        #expect(await calls.count == 3)
        do {
            _ = try await ClaudeUsageGate(directory: directory).fetch(account: account, now: { now.addingTimeInterval(5_703) }) { _ in
                throw ProviderIssue.rateLimited
            }
        } catch ProviderIssue.retryLater(let date) {
            #expect(date == now.addingTimeInterval(5_703 + 1_800))
        }
    }

    @Test func tokenWaitDoesNotLockUsagePolls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls()
        let now = now
        let tokenWait = now.addingTimeInterval(12 * 3_600)
        do {
            _ = try await ClaudeUsageGate(directory: directory).fetch(account: account, now: { now }) { _ in
                await calls.record()
                throw ProviderIssue.retryLater(tokenWait)
            }
            Issue.record("Expected the token wait")
        } catch ProviderIssue.retryLater(let date) {
            #expect(date == tokenWait)
        }
        let result = try await ClaudeUsageGate(directory: directory).fetch(account: account, now: { now.addingTimeInterval(60) }) { _ in
            await calls.record()
            return snapshot(at: now.addingTimeInterval(60))
        }
        #expect(result.windows.count == 1)
        #expect(await calls.count == 2)
    }

    @Test func tokenWaitReportsTheLaterOfBackoffAndNextPoll() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("claude-token-backoff.json")
        #expect(ClaudeTokenBackoff.wait(now: now, from: url) == .retryLater(now.addingTimeInterval(300)))
        ClaudeTokenBackoff.recordLimit(retryAfter: nil, now: now, to: url)
        #expect(ClaudeTokenBackoff.wait(now: now, from: url) == .retryLater(now.addingTimeInterval(1_800)))
        #expect(ClaudeTokenBackoff.wait(now: now.addingTimeInterval(3_600), from: url) == .retryLater(now.addingTimeInterval(3_900)))
    }

    @Test func retryAfterHonorsDatesLongWaitsAndZero() {
        #expect(RetryAfter.parse("0", now: now) == nil)
        #expect(RetryAfter.parse("garbage", now: now) == nil)
        #expect(RetryAfter.parse("90", now: now) == 90)
        #expect(RetryAfter.parse("Fri, 15 Jan 2027 08:01:00 GMT", now: now) == 60)
        #expect(ClaudeUsageGate.delay(attempt: 0, retryAfter: 90) == 1_800)
        #expect(ClaudeUsageGate.delay(attempt: 0, retryAfter: 86_400) == 86_400)
        #expect(ClaudeUsageGate.delay(attempt: 100, retryAfter: nil) == 43_200)
    }

    @Test func differentAccountsDoNotShareLimits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = now
        let gate = ClaudeUsageGate(directory: directory)
        do {
            _ = try await gate.fetch(account: account, now: { now }) { _ in throw ProviderIssue.rateLimited }
        } catch ProviderIssue.retryLater { }
        let other = Account(provider: .claude, source: .managed, email: "other@example.com", plan: nil)
        let result = try await gate.fetch(account: other, now: { now }) { _ in snapshot(at: now) }
        #expect(result.windows.count == 1)
    }
}

private actor Calls {
    private(set) var count = 0
    func record() { count += 1 }
}
