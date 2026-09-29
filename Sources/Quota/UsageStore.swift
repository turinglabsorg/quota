import AppKit
import Combine
import QuotaCore

@MainActor
final class UsageStore: ObservableObject {
    struct Entry: Equatable {
        var snapshot: ProviderSnapshot?
        var issue: ProviderIssue?
    }

    @Published private(set) var entries: [UUID: Entry]
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false

    private let accounts: AccountStore
    private let refreshInterval: TimeInterval = 5 * 60
    private var refreshTimer: Timer?
    private var resetTimer: Timer?
    private var needsAnotherRefresh = false
    private var cancellables = Set<AnyCancellable>()

    init(accounts: AccountStore, entries: [UUID: Entry] = [:]) {
        self.accounts = accounts
        self.entries = entries
    }

    func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .delay(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &cancellables)
        accounts.$accounts
            .map { Set($0.map(\.id)) }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &cancellables)
    }

    func refreshIfStale() {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        refresh()
    }

    func refresh() {
        guard !isRefreshing else {
            needsAnotherRefresh = true
            return
        }
        let current = accounts.accounts
        let ids = Set(current.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        isRefreshing = true
        Task {
            await withTaskGroup(of: (Account, Result<ProviderSnapshot, ProviderIssue>).self) { group in
                for account in current {
                    group.addTask {
                        do {
                            return (account, .success(try await UsageFetchers.fetch(account)))
                        } catch let issue as ProviderIssue {
                            return (account, .failure(issue))
                        } catch {
                            return (account, .failure(.network))
                        }
                    }
                }
                for await (account, result) in group {
                    apply(result, to: account)
                }
            }
            lastRefresh = Date()
            isRefreshing = false
            scheduleRefreshAfterNextReset()
            if needsAnotherRefresh {
                needsAnotherRefresh = false
                refresh()
            }
        }
    }

    private func apply(_ result: Result<ProviderSnapshot, ProviderIssue>, to account: Account) {
        guard accounts.accounts.contains(where: { $0.id == account.id }) else { return }
        switch result {
        case .success(let snapshot):
            entries[account.id] = Entry(snapshot: snapshot, issue: nil)
            accounts.updateIdentity(id: account.id, email: snapshot.account, plan: snapshot.plan)
        case .failure(let issue):
            let previous = issue.keepsLastSnapshot ? entries[account.id]?.snapshot : nil
            entries[account.id] = Entry(snapshot: previous, issue: issue)
        }
    }

    private func scheduleRefreshAfterNextReset() {
        resetTimer?.invalidate()
        let now = Date()
        let nextReset = entries.values
            .compactMap(\.snapshot)
            .flatMap(\.windows)
            .compactMap(\.resetsAt)
            .filter { $0 > now }
            .min()
        guard let nextReset, nextReset.timeIntervalSince(now) < refreshInterval else { return }
        resetTimer = Timer.scheduledTimer(withTimeInterval: nextReset.timeIntervalSince(now) + 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}
