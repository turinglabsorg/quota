import Foundation

/// A `quota-server` this Mac reads usage from, like the iOS app, instead of calling the providers itself.
/// The address lives in the shared defaults and the device token in the Keychain.
public enum ServerConnection {
    public enum Failure: Error, Equatable, Sendable {
        case invalidAddress
        case notPaired
        case invalidCode
        case expiredCode
        case unauthorized
        case server(Int)
        case network
        case invalidResponse
        case keychain

        public var message: String {
            switch self {
            case .invalidAddress: String(localized: "Enter the address of your Quota server.")
            case .notPaired: String(localized: "Pair this device with your Quota server.")
            case .invalidCode: String(localized: "That pairing code is not valid.")
            case .expiredCode: String(localized: "That pairing code expired. Create a new one.")
            case .unauthorized: String(localized: "This device is no longer paired. Pair it again.")
            case .server(let status): String(localized: "Server error (HTTP \(status)).")
            case .network: String(localized: "Can't reach the Quota server.")
            case .invalidResponse: String(localized: "Unrecognized response.")
            case .keychain: String(localized: "Couldn't save the pairing on this device.")
            }
        }
    }

    private static let urlKey = "serverURL"
    private static let tokenService = "com.turinglabs.quota.server"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    public static var serverURL: URL? {
        AccountStorage.defaults.string(forKey: urlKey).flatMap(URL.init(string:))
    }

    /// `quota.example.com` → `https://quota.example.com`; nil when the text is not an http(s) address.
    public static func address(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://\(text)" }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    public static func pair(server: URL, code: String, deviceName: String) async throws {
        let token = try await requestToken(server: server, code: code, deviceName: deviceName)
        guard await Keychain.write(service: tokenService, data: Data(token.utf8)) else { throw Failure.keychain }
        AccountStorage.defaults.set(server.absoluteString, forKey: urlKey)
    }

    public static func fetchUsage() async throws -> UsagePayload {
        guard let server = serverURL else { throw Failure.notPaired }
        guard let data = await Keychain.read(service: tokenService), let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw Failure.notPaired
        }
        let payload = try await fetchUsage(server: server, token: token)
        if let data = try? UsagePayload.encode(payload) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        }
        return payload
    }

    /// The last payload read from the server (usage only), shown at launch until the next fetch.
    public static func cachedUsage() -> UsagePayload? {
        guard serverURL != nil, let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? UsagePayload.decode(data)
    }

    public static func unpair() async {
        AccountStorage.defaults.removeObject(forKey: urlKey)
        try? FileManager.default.removeItem(at: cacheURL)
        await Keychain.delete(service: tokenService)
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quota/RemoteUsage/usage.json")
    }

    static func requestToken(server: URL, code: String, deviceName: String) async throws -> String {
        var request = URLRequest(url: server.appendingPathComponent("v1/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code.filter(\.isNumber), "name": deviceName])
        let (data, status) = try await send(request)
        switch status {
        case 200:
            guard let token = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["token"], !token.isEmpty else {
                throw Failure.invalidResponse
            }
            return token
        case 401: throw Failure.invalidCode
        case 410: throw Failure.expiredCode
        default: throw Failure.server(status)
        }
    }

    static func fetchUsage(server: URL, token: String) async throws -> UsagePayload {
        var request = URLRequest(url: server.appendingPathComponent("v1/usage"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await send(request)
        switch status {
        case 200:
            guard let payload = try? UsagePayload.decode(data) else { throw Failure.invalidResponse }
            return payload
        case 401: throw Failure.unauthorized
        default: throw Failure.server(status)
        }
    }

    private static func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw Failure.network
        }
    }
}
