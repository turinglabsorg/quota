import Foundation
import QuotaCore

/// Latest usage of every linked account. Like the menu bar app it refreshes every 5 minutes and keeps
/// the last good numbers through transient failures.
actor UsageCache {
    static let refreshInterval: TimeInterval = 5 * 60

    private struct Entry {
        var snapshot: ProviderSnapshot?
        var issue: ProviderIssue?
    }

    private let loadAccounts: @Sendable () -> [Account]
    private let fetch: @Sendable (Account) async throws -> ProviderSnapshot
    private var entries: [UUID: Entry] = [:]
    private var refreshedAt: Date?
    private var inFlight: Task<Void, Never>?

    init(
        loadAccounts: @escaping @Sendable () -> [Account] = { AccountStorage.load() },
        fetch: @escaping @Sendable (Account) async throws -> ProviderSnapshot = { try await UsageFetchers.fetch($0) }
    ) {
        self.loadAccounts = loadAccounts
        self.fetch = fetch
    }

    var isStale: Bool {
        refreshedAt.map { Date().timeIntervalSince($0) > Self.refreshInterval + 60 } ?? true
    }

    func refresh() async {
        if let inFlight { return await inFlight.value }
        let task = Task { await performRefresh() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    func payload(now: Date = Date()) -> UsagePayload {
        let accounts = loadAccounts().map { account in
            AccountUsage(account: account, snapshot: entries[account.id]?.snapshot, issue: entries[account.id]?.issue)
        }
        return UsagePayload(generatedAt: now, refreshedAt: refreshedAt, accounts: accounts)
    }

    private func performRefresh() async {
        let accounts = loadAccounts()
        let fetch = fetch
        let results = await withTaskGroup(of: (UUID, Result<ProviderSnapshot, ProviderIssue>).self) { group in
            for account in accounts {
                group.addTask {
                    do {
                        return (account.id, .success(try await fetch(account)))
                    } catch let issue as ProviderIssue {
                        return (account.id, .failure(issue))
                    } catch {
                        return (account.id, .failure(.network))
                    }
                }
            }
            var collected: [(UUID, Result<ProviderSnapshot, ProviderIssue>)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        let ids = Set(accounts.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        for (id, result) in results {
            switch result {
            case .success(let snapshot):
                entries[id] = Entry(snapshot: snapshot, issue: nil)
            case .failure(let issue):
                entries[id] = Entry(snapshot: issue.keepsLastSnapshot ? entries[id]?.snapshot : nil, issue: issue)
            }
        }
        refreshedAt = Date()
    }
}
