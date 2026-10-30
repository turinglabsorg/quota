import Foundation
import QuotaCore

@MainActor
final class AccountStore: ObservableObject {
    /// The accounts on screen: the ones linked on this Mac, or the server's while one is connected.
    @Published private(set) var accounts: [Account]
    @Published private(set) var isRemote = false
    private var local: [Account] {
        didSet { if !isRemote { accounts = local } }
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
        if accounts != remote { accounts = remote }
    }

    func showLocal() {
        isRemote = false
        accounts = local
    }

    func add(_ account: Account) {
        let order = Provider.allCases
        local = (local + [account]).enumerated()
            .sorted { lhs, rhs in
                let left = order.firstIndex(of: lhs.element.provider) ?? 0
                let right = order.firstIndex(of: rhs.element.provider) ?? 0
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
        AccountStorage.save(local)
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
