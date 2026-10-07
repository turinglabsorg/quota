import CryptoKit
import Foundation

// Ollama Cloud authenticates a device with an Ed25519 key (`~/.ollama/id_ed25519`) that `ollama signin`
// links to an account. Requests to ollama.com carry `Authorization: <public key>:<signature>`, where the
// signature covers `<METHOD>,<path>?ts=<unix seconds>` and the same `ts` goes in the query
// (ollama/ollama: api/client.go, auth/auth.go). Quota signs exactly like that, so it never needs a
// password or an API key: an extra account is a new key that the user links in the browser.
public struct OllamaKey: Equatable, Sendable {
    public let seed: Data
    public let publicKey: Data

    public init?(seed: Data) {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
        self.seed = Data(seed)
        publicKey = key.publicKey.rawRepresentation
    }

    var publicBlob: Data {
        OpenSSHKey.string(Data("ssh-ed25519".utf8)) + OpenSSHKey.string(publicKey)
    }

    /// The `ssh-ed25519 AAAA…` line Ollama shows and links to accounts.
    public var authorizedKey: String {
        "ssh-ed25519 \(publicBlob.base64EncodedString())"
    }

    /// The key as ollama.com addresses it in URLs.
    var encoded: String {
        Data(authorizedKey.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func authorization(method: String, path: String, timestamp: String) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let signature = try key.signature(for: Data("\(method),\(path)?ts=\(timestamp)".utf8))
        return "\(publicBlob.base64EncodedString()):\(signature.base64EncodedString())"
    }
}

public enum OllamaParser {
    /// `GET /api/balance` (ollama/ollama docs/api/balance.mdx). Current plans report the included monthly
    /// allowance in USD (`balance_usd` left of `allowance_usd`, resetting at `period.until`); legacy plans
    /// report `session` and `weekly` windows with `remaining_percent` (0–100) and `resets_at`.
    public static func usage(from data: Data) throws -> [UsageWindow] {
        let root = fields(try JSON.object(data))
        guard let included = JSON.dict(root["included"]).map(fields) else { throw ProviderIssue.invalidResponse }
        var windows: [UsageWindow] = []
        for (key, kind) in [("session", UsageWindow.Kind.session), ("weekly", .weekly)] {
            guard let window = JSON.dict(included[key]).map(fields),
                  let remaining = JSON.number(window["remaining_percent"]), (0...100).contains(remaining)
            else { continue }
            windows.append(UsageWindow(kind: kind, usedPercent: 100 - remaining, resetsAt: Timestamp.date(window["resets_at"])))
        }
        if let allowance = JSON.number(included["allowance_usd"]), allowance > 0,
           let balance = JSON.number(included["balance_usd"]) {
            let period = JSON.dict(included["period"]).map(fields)
            windows.append(UsageWindow(kind: .monthly, usedPercent: (allowance - balance) * 100 / allowance, resetsAt: Timestamp.date(period?["until"])))
        }
        return windows
    }

    /// nil for a key that is not linked: ollama.com then answers with an empty user.
    public static func identity(from data: Data) -> AccountIdentity? {
        guard let root = try? JSON.object(data) else { return nil }
        let user = fields(root)
        guard let email = JSON.string(user["email"]) ?? JSON.string(user["name"]) else { return nil }
        return AccountIdentity(email: email, plan: JSON.string(user["plan"]).map(Formatting.capitalized))
    }

    // ollama.com answers with Go field names (`Email`, `Plan`); like Go's decoder, ignore case.
    private static func fields(_ object: [String: Any]) -> [String: Any] {
        Dictionary(object.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}

enum OllamaCloud {
    static let keyPath = ".ollama/id_ed25519"
    private static let baseURL = URL(string: "https://ollama.com")!

    static func keyFile(for account: Account) -> URL {
        (account.home ?? LocalFiles.home).appendingPathComponent(keyPath)
    }

    static func readKey(at url: URL) -> OllamaKey? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), let seed = OpenSSHKey.seed(from: text) else { return nil }
        return OllamaKey(seed: seed)
    }

    static func createKey(at url: URL) throws -> OllamaKey {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let key = OllamaKey(seed: Curve25519.Signing.PrivateKey().rawRepresentation),
              FileManager.default.createFile(atPath: url.path, contents: Data(OpenSSHKey.text(for: key).utf8), attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        return key
    }

    // The name `ollama signin` gives the device (Go's os.Hostname); ProcessInfo.hostName may wait on DNS.
    static var deviceName: String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "Mac" }
        return String(cString: buffer)
    }

    // Same link `ollama signin` opens: ollama.com asks the user to sign in and links this key.
    static func connectURL(for key: OllamaKey, deviceName: String) -> URL {
        var components = URLComponents(string: "https://ollama.com/connect")!
        components.queryItems = [URLQueryItem(name: "name", value: deviceName), URLQueryItem(name: "key", value: key.encoded)]
        return components.url!
    }

    static func signedRequest(_ key: OllamaKey, method: String, path: String) async throws -> Data {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let authorization = try key.authorization(method: method, path: path, timestamp: timestamp)
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "ts", value: timestamp)]
        return try await HTTP.send(method: method, url: components.url!, headers: [
            "Authorization": authorization,
            "Accept": "application/json",
            "Content-Type": "application/json",
        ])
    }

    /// The account this key is linked to, or nil while it is not linked.
    static func whoami(_ key: OllamaKey) async throws -> AccountIdentity? {
        do {
            let data = try await signedRequest(key, method: "POST", path: "/api/me")
            return OllamaParser.identity(from: data)
        } catch ProviderIssue.http(let status) where status == 401 || status == 403 {
            return nil
        }
    }

    /// Unlinks the key from its account, like `ollama signout`.
    static func disconnect(_ key: OllamaKey) async {
        _ = try? await signedRequest(key, method: "DELETE", path: "/api/user/keys/\(key.encoded)")
    }
}

struct OllamaFetcher {
    let account: Account

    func fetch() async throws -> ProviderSnapshot {
        guard let key = OllamaCloud.readKey(at: OllamaCloud.keyFile(for: account)) else { throw signedOut }
        let data: Data
        do {
            data = try await OllamaCloud.signedRequest(key, method: "GET", path: "/api/balance")
        } catch ProviderIssue.http(let status) where status == 401 || status == 403 {
            throw signedOut
        }
        let windows = try OllamaParser.usage(from: data)
        guard !windows.isEmpty else {
            throw ProviderIssue.noQuota(String(localized: "This account has no subscription limits."))
        }
        // The plan name is a nicety: the meters stay even when this second call fails.
        let identity = try? await OllamaCloud.whoami(key)
        return ProviderSnapshot(provider: .ollama, plan: identity?.plan ?? account.plan, account: identity?.email ?? account.email, windows: windows)
    }

    private var signedOut: ProviderIssue {
        account.home == nil
            ? .signedOut(String(localized: "Not signed in to Ollama Cloud. Run `ollama signin`."))
            : .sessionExpired(String(localized: "Ollama Cloud session expired: relink the account."))
    }
}

// OpenSSH private key files ("openssh-key-v1"), the format Ollama and ssh-keygen use for id_ed25519.
enum OpenSSHKey {
    private static let magic = Data("openssh-key-v1\0".utf8)
    private static let keyType = Data("ssh-ed25519".utf8)
    private static let none = Data("none".utf8)
    private static let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let end = "-----END OPENSSH PRIVATE KEY-----"

    static func string(_ value: Data) -> Data {
        uint32(UInt32(value.count)) + value
    }

    /// The Ed25519 seed of an unencrypted OpenSSH private key.
    static func seed(from text: String) -> Data? {
        guard let start = text.range(of: begin),
              let stop = text.range(of: end, range: start.upperBound..<text.endIndex),
              let data = Data(base64Encoded: String(text[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace })),
              data.starts(with: magic)
        else { return nil }
        var reader = Reader(data: data, offset: magic.count)
        guard reader.string() == none, reader.string() == none, reader.string() != nil, reader.uint32() == 1,
              reader.string() != nil, let section = reader.string()
        else { return nil }
        var inner = Reader(data: section, offset: 0)
        guard let check = inner.uint32(), inner.uint32() == check, inner.string() == keyType,
              let publicKey = inner.string(), publicKey.count == 32,
              let secret = inner.string(), secret.count == 64
        else { return nil }
        return Data(secret.prefix(32))
    }

    /// Encodes the key the way `ssh-keygen -t ed25519 -N ''` does.
    static func text(for key: OllamaKey) -> String {
        let check = uint32(UInt32.random(in: .min ... .max))
        var section = check + check + string(keyType) + string(key.publicKey) + string(key.seed + key.publicKey) + string(Data())
        section += Data((0..<((8 - section.count % 8) % 8)).map { UInt8($0 + 1) })
        let data = magic + string(none) + string(none) + string(Data()) + uint32(1) + string(key.publicBlob) + string(section)
        return "\(begin)\n\(data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))\n\(end)\n"
    }

    private static func uint32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private struct Reader {
        let data: Data
        var offset: Int

        mutating func uint32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let start = data.startIndex + offset
            offset += 4
            return data[start..<start + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func string() -> Data? {
            guard let length = uint32().map(Int.init), offset + length <= data.count else { return nil }
            let start = data.startIndex + offset
            offset += length
            return data.subdata(in: start..<start + length)
        }
    }
}
