import Foundation

/// Linked accounts (no secrets), shared by the menu bar app and `quota-server` on the same Mac.
public enum AccountStorage {
    public static let defaults = UserDefaults(suiteName: "com.turinglabs.quota.shared") ?? .standard
    private static let key = "accounts"

    public static func load() -> [Account] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    public static func save(_ accounts: [Account]) {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: key)
    }
}
