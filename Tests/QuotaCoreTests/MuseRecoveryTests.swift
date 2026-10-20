import Foundation
import Testing
@testable import QuotaCore

@Suite struct MuseRecoveryTests {
    @Test func missingWindowsRetainPlanAndExposeTheProblem() throws {
        let data = Data(#"{"is_subs_active":true,"subs_tier_name":"Muse Code High Usage","user_email":"a@example.com"}"#.utf8)
        let snapshot = try MuseCodeParser.snapshot(from: data)
        #expect(snapshot.plan == "High Usage")
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.issue != nil)
        let account = Account(provider: .musecode, source: .cli, email: snapshot.account, plan: snapshot.plan)
        #expect(AccountUsage(account: account, snapshot: snapshot, issue: nil).issue?.kind == "usageUnavailable")
    }

    @Test func wakeIsOneMinimalCallAndNeverGoesToAnotherHost() throws {
        let data = Data(#"{"is_subs_active":true,"api_key":"fixture-key","base_url":"https://api.meta.ai/muse-code/v1"}"#.utf8)
        let request = try MuseIdleWake.request(from: data)
        #expect(request.url.absoluteString == "https://api.meta.ai/muse-code/v1/responses")
        let body = try JSON.object(request.body)
        #expect(JSON.number(body["max_output_tokens"]) == 16)
        #expect(body["store"] as? Bool == false)
        #expect((body["tools"] as? [String])?.isEmpty == true)
        let invalid = Data(#"{"is_subs_active":true,"api_key":"fixture-key","base_url":"https://other.example/v1"}"#.utf8)
        #expect(throws: ProviderIssue.invalidResponse) { try MuseIdleWake.request(from: invalid) }
    }

    @Test func successfulWakeCannotRepeatAfterReopeningOrRestarting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("wake.json")
        let now = Date()
        let first = try await MuseIdleWake.run(file: file, now: now) { }
        #expect(first)
        let again = try await MuseIdleWake.run(file: file, now: now.addingTimeInterval(300)) { Issue.record("Duplicate inference") }
        #expect(!again)
        let later = try await MuseIdleWake.run(file: file, now: now.addingTimeInterval(5 * 3_600 + 1)) { }
        #expect(later)
    }

    @Test func failedWakeAlsoHasACooldown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("wake.json")
        let now = Date()
        do {
            _ = try await MuseIdleWake.run(file: file, now: now) { throw ProviderIssue.rateLimited }
            Issue.record("Expected the failure")
        } catch ProviderIssue.rateLimited { }
        let again = try await MuseIdleWake.run(file: file, now: now.addingTimeInterval(60)) { Issue.record("Duplicate failed inference") }
        #expect(!again)
    }

    @Test func concurrentOpensCannotSendTwoRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("wake.json")
        let count = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await MuseIdleWake.run(file: file) { try await Task.sleep(nanoseconds: 100_000_000) }
                }
            }
            var count = 0
            for try await didRun in group { if didRun { count += 1 } }
            return count
        }
        #expect(count == 1)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["QUOTA_MUSE_WAKE_TEST"] == "1"))
struct MuseRecoveryLiveTests {
    @Test func restoresBothBarsWithOneMinimalRequest() async throws {
        let identity = try #require(await AccountLinker.detectCLILogin(.musecode))
        let account = Account(provider: .musecode, source: .cli, email: identity.email, plan: identity.plan)
        let snapshot = try await UsageFetchers.fetch(account, wakeIdleMuse: true)
        #expect(snapshot.issue == nil)
        #expect(snapshot.windows.contains { $0.kind == .session })
        #expect(snapshot.windows.contains { $0.kind == .weekly })
        print("Muse recovery: \(snapshot.windows.map { "\($0.label): \(Int($0.usedPercent))% used" }.joined(separator: ", "))")
        if let issue = snapshot.issue { print("Muse recovery: \(issue.message)") }
    }
}
