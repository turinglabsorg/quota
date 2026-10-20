import Foundation

enum LocalFiles {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}

enum HTTP {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    static func get(_ url: URL, headers: [String: String], retryAfter: RetryAfter? = nil, logBody: Bool = true) async throws -> Data {
        try await send(method: "GET", url: url, headers: headers, retryAfter: retryAfter, logBody: logBody)
    }

    static func send(method: String, url: URL, headers: [String: String], retryAfter: RetryAfter? = nil, logBody: Bool = true) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try await send(request, logBody: logBody, retryAfter: retryAfter)
    }

    static func postForm(_ url: URL, fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        return try await send(request)
    }

    /// `logBody` stays false when the response carries a credential, such as the Muse Code key mint.
    /// `retryAfter` receives the `Retry-After` delta, in seconds, when the server answers 429.
    static func postJSON(_ url: URL, body: Data, headers: [String: String], logBody: Bool = true, retryAfter: RetryAfter? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        var headers = headers
        if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try await send(request, logBody: logBody, retryAfter: retryAfter)
    }

    private static func send(_ request: URLRequest, logBody: Bool = true, retryAfter: RetryAfter? = nil) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderIssue.network
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let debug = ProcessInfo.processInfo.environment["QUOTA_DEBUG"]
        if !logBody, debug != nil {
            FileHandle.standardError.write(Data("[\(request.url?.host ?? "")\(request.url?.path ?? "")] HTTP \(status)\n".utf8))
        }
        if logBody, let debug, debug == "verbose" || !(200..<300).contains(status) {
            let body = String(decoding: data.prefix(debug == "verbose" ? 262_144 : 300), as: UTF8.self)
            FileHandle.standardError.write(Data("[\(request.url?.host ?? "")] HTTP \(status) body=\(body)\n".utf8))
        }
        switch status {
        case 200..<300: return data
        case 429:
            retryAfter?.seconds = RetryAfter.parse(http?.value(forHTTPHeaderField: "Retry-After"))
            throw ProviderIssue.rateLimited
        default: throw ProviderIssue.http(status)
        }
    }
}

/// Filled in when a call receives HTTP 429. Shared by the request and its caller.
final class RetryAfter: @unchecked Sendable {
    var seconds: TimeInterval?

    static func parse(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header else { return nil }
        if let seconds = TimeInterval(header), seconds.isFinite, seconds > 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header), date > now else { return nil }
        return date.timeIntervalSince(now)
    }
}

enum LoginURL {
    static func first(in text: String) -> URL? {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        guard let range = plain.range(of: #"https://[^\s\u{1B}\u{07}"'<>]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(plain[range]))
    }
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
