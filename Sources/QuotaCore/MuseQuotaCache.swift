import CryptoKit
import Darwin
import Foundation

enum MuseQuotaCache {
    static func file(email: String, name: String = "quota") -> URL {
        let key = SHA256.hash(data: Data(email.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        return AccountPaths.root.deletingLastPathComponent().appendingPathComponent("MuseUsage/\(key)-\(name).json")
    }

    static func read(email: String?) -> ProviderSnapshot? {
        guard let email, let data = try? Data(contentsOf: file(email: email)),
              let cached = try? JSONDecoder().decode(AccountUsage.self, from: data)
        else { return nil }
        return cached.snapshot
    }

    static func save(_ snapshot: ProviderSnapshot, account: Account) {
        guard !snapshot.windows.isEmpty, snapshot.issue == nil, let email = snapshot.account ?? account.email else { return }
        if let data = try? JSONEncoder().encode(AccountUsage(account: account, snapshot: snapshot, issue: nil)) {
            try? save(data, to: file(email: email))
        }
    }

    static func save(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

enum MuseIdleWake {
    /// Claim before sending so reopening the popover or restarting cannot duplicate an inference.
    static func run(file: URL, now: Date = Date(), operation: () async throws -> Void) async throws -> Bool {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw ProviderIssue.network }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        defer { flock(descriptor, LOCK_UN) }
        if let data = try? Data(contentsOf: file), let until = try? JSONDecoder().decode(Date.self, from: data), until > now { return false }
        try MuseQuotaCache.save(JSONEncoder().encode(now.addingTimeInterval(30 * 60)), to: file)
        try await operation()
        try MuseQuotaCache.save(JSONEncoder().encode(now.addingTimeInterval(5 * 3_600)), to: file)
        return true
    }

    static func request(from minted: Data) throws -> (url: URL, body: Data, headers: [String: String]) {
        let root = try JSON.object(minted)
        guard root["is_subs_active"] as? Bool == true,
              let key = JSON.string(root["api_key"]),
              let base = JSON.string(root["base_url"]), let url = URL(string: base),
              url.scheme == "https", url.host == "api.meta.ai", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil
        else { throw ProviderIssue.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "muse-spark-1.3",
            "input": "Reply OK.",
            "max_output_tokens": 16,
            "reasoning": ["effort": "minimal"],
            "store": false,
            "tools": [],
        ] as [String: Any])
        return (url.appendingPathComponent("responses"), body, [
            "Authorization": "Bearer \(key)", "x-api-version": "1.0.0", "User-Agent": "Quota",
        ])
    }
}
