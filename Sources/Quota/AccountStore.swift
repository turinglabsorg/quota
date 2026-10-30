import Foundation
import QuotaCore

@MainActor
final class AccountStore: ObservableObject {
    /// The accounts on screen: the ones linked on this Mac, or the server's while one is connected,
    /// with the accounts of `readHere` providers linked on this Mac in place of the server's.
    @Published private(set) var accounts: [Account]
    @Published private(set) var isRemote = false
    private var remote: [Account] = []
    private var local: [Account] {
        didSet { if isRemote { showRemote(remote) } else { accounts = local } }
    }

    /// Providers a paired Mac still reads itself when linked here: Muse Code's idle wake on open and its
    /// token rows from the local session logs are not part of the server payload.
    nonisolated static let readHere: Set<Provider> = [.musecode]

    /// The accounts this Mac fetches itself.
    var fetchedHere: [Account] {
        isRemote ? Self.readHere(from: local) : local
    }

    nonisolated static func readHere(from accounts: [Account]) -> [Account] {
        accounts.filter { readHere.contains($0.provider) }
    }

    /// The server's accounts, without the providers this Mac reads itself.
    nonisolated static func shownRemote(_ remote: [Account], here: [Account]) -> [Account] {
        let providers = Set(here.map(\.provider))
        return remote.filter { !providers.contains($0.provider) }
    }

    init(accounts: [Account] = AccountStorage.load()) {
        local = accounts.map { account in
            var account = account
            if account.plan?.lowercased() == "unknown" { account.plan = nil }
            return account
        }
        self.accounts = local
    }

    func showRemote(_ remote: [Account]) {
        isRemote = true
        self.remote = remote
        let shown = Self.sorted(Self.shownRemote(remote, here: fetchedHere) + fetchedHere)
        if accounts != shown { accounts = shown }
    }

    func isFetchedHere(_ id: UUID) -> Bool {
        fetchedHere.contains { $0.id == id }
    }

    func showLocal() {
        isRemote = false
        accounts = local
    }

    func add(_ account: Account) {
        local = Self.sorted(local + [account])
        AccountStorage.save(local)
    }

    private static func sorted(_ accounts: [Account]) -> [Account] {
        let order = Provider.allCases
        return accounts.enumerated()
            .sorted { lhs, rhs in
                let left = order.firstIndex(of: lhs.element.provider) ?? 0
                let right = order.firstIndex(of: rhs.element.provider) ?? 0
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    func remove(_ id: UUID) {
        local.removeAll { $0.id == id }
        AccountStorage.save(local)
    }

    func updateIdentity(id: UUID, email: String?, plan: String?) {
        guard let index = local.firstIndex(where: { $0.id == id }) else { return }
        var account = local[index]
        account.email = email ?? account.email
        account.plan = plan ?? account.plan
        guard account != local[index] else { return }
        local[index] = account
        AccountStorage.save(local)
    }

    func hasSharedLogin(_ provider: Provider) -> Bool {
        local.contains { $0.provider == provider && $0.source == .cli }
    }

    func hasManagedAccount(_ provider: Provider, email: String) -> Bool {
        local.contains { $0.provider == provider && $0.source == .managed && $0.email?.caseInsensitiveCompare(email) == .orderedSame }
    }
}
