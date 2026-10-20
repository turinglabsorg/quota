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
    private var isWakingMuse = false
    private var cancellables = Set<AnyCancellable>()

    init(accounts: AccountStore, entries: [UUID: Entry] = [:]) {
        self.accounts = accounts
        self.entries = entries
    }

    func start() {
        refresh(wakeIdleMuse: true)
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
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < refreshInterval {
            wakeMuseIfIdle()
            return
        }
        refresh(wakeIdleMuse: true)
    }

    func refresh() {
        refresh(wakeIdleMuse: false)
    }

    private func wakeMuseIfIdle() {
        guard !isRefreshing, !isWakingMuse,
              let account = accounts.accounts.first(where: { $0.provider == .musecode }),
              !(entries[account.id]?.snapshot?.windows.contains(where: { $0.kind == .session && ($0.resetsAt.map { $0 > Date() } ?? false) }) ?? false)
        else { return }
        isWakingMuse = true
        Task {
            defer { isWakingMuse = false }
            do { apply(.success(try await UsageFetchers.fetch(account, wakeIdleMuse: true)), to: account) }
            catch let issue as ProviderIssue { apply(.failure(issue), to: account) }
            catch { apply(.failure(.network), to: account) }
        }
    }

    private func refresh(wakeIdleMuse: Bool) {
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
                            return (account, .success(try await UsageFetchers.fetch(account, wakeIdleMuse: wakeIdleMuse)))
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
            var shown = snapshot
            if snapshot.windows.isEmpty, snapshot.issue?.keepsLastSnapshot == true,
               let previous = entries[account.id]?.snapshot, !previous.windows.isEmpty {
                shown.windows = previous.windows
                shown.fetchedAt = previous.fetchedAt
            }
            entries[account.id] = Entry(snapshot: shown, issue: snapshot.issue)
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
            .flatMap { snapshot in
                snapshot.windows.compactMap(\.resetsAt)
                    + snapshot.tokenUsage.compactMap(\.resetsAt)
                    + (snapshot.resetCredits?.credits.compactMap(\.expiresAt) ?? [])
            }
            .filter { $0 > now }
            .min()
        guard let nextReset, nextReset.timeIntervalSince(now) < refreshInterval else { return }
        resetTimer = Timer.scheduledTimer(withTimeInterval: nextReset.timeIntervalSince(now) + 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}
