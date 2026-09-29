import Foundation
import QuotaCore

enum Storage {
    static let defaults = UserDefaults(suiteName: "com.turinglabs.quota.shared") ?? .standard
    static let accountsKey = "accounts"

    static func loadAccounts() -> [Account] {
        guard let data = defaults.data(forKey: accountsKey) else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    static func saveAccounts(_ accounts: [Account]) {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: accountsKey)
    }
}

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account]

    init(accounts: [Account] = Storage.loadAccounts()) {
        self.accounts = accounts
    }

    func add(_ account: Account) {
        let order = Provider.allCases
        accounts = (accounts + [account]).enumerated()
            .sorted { lhs, rhs in
                let left = order.firstIndex(of: lhs.element.provider) ?? 0
                let right = order.firstIndex(of: rhs.element.provider) ?? 0
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
        Storage.saveAccounts(accounts)
    }

    func remove(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        Storage.saveAccounts(accounts)
    }

    func updateIdentity(id: UUID, email: String?, plan: String?) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var account = accounts[index]
        account.email = email ?? account.email
        account.plan = plan ?? account.plan
        guard account != accounts[index] else { return }
        accounts[index] = account
        Storage.saveAccounts(accounts)
    }

    func hasSharedLogin(_ provider: Provider) -> Bool {
        accounts.contains { $0.provider == provider && $0.source == .cli }
    }

    func hasManagedAccount(_ provider: Provider, email: String) -> Bool {
        accounts.contains { $0.provider == provider && $0.source == .managed && $0.email?.caseInsensitiveCompare(email) == .orderedSame }
    }
}
