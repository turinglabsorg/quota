import Foundation
import Testing
import QuotaCore
@testable import Quota

@Suite @MainActor struct ServerRecoveryTests {
    @Test func keepsRemoteAccountsAndRecoversAfterKeychainFailure() async throws {
        let local = Account(provider: .claude, source: .cli, email: "local@example.com", plan: nil)
        let remote = Account(provider: .claude, source: .cli, email: "remote@example.com", plan: nil)
        let accounts = AccountStore(accounts: [local])
        accounts.showRemote([remote])
        let url = try #require(URL(string: "https://quota.example.com"))
        let server = ServerLink(serverURL: url)
        let previous = ProviderSnapshot(provider: .claude, plan: nil, windows: [UsageWindow(kind: .weekly, usedPercent: 20, resetsAt: nil)])
        let updated = ProviderSnapshot(provider: .claude, plan: nil, account: remote.email, windows: [UsageWindow(kind: .weekly, usedPercent: 30, resetsAt: nil)])
        var attempts = 0
        let usage = UsageStore(accounts: accounts, server: server, entries: [remote.id: .init(snapshot: previous)]) {
            attempts += 1
            if attempts == 1 { throw ServerConnection.Failure.keychainUnavailable }
            return UsagePayload(generatedAt: Date(), refreshedAt: Date(), accounts: [AccountUsage(account: remote, snapshot: updated, issue: nil)])
        }

        usage.refresh()
        try await finish(usage)
        #expect(server.serverURL == url)
        #expect(accounts.isRemote)
        #expect(accounts.accounts == [remote])
        #expect(accounts.fetchedHere.isEmpty)
        #expect(usage.entries[remote.id]?.snapshot == previous)
        #expect(usage.entries[remote.id]?.issue == .usageUnavailable(ServerConnection.Failure.keychainUnavailable.message))

        usage.refresh()
        try await finish(usage)
        #expect(attempts == 2)
        #expect(server.serverURL == url)
        #expect(accounts.accounts == [remote])
        #expect(usage.entries[remote.id]?.snapshot == updated)
        #expect(usage.entries[remote.id]?.issue == nil)
    }

    private func finish(_ usage: UsageStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while usage.isRefreshing && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(!usage.isRefreshing)
    }
}
