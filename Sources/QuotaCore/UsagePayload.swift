import Foundation

/// The JSON `quota-server` publishes at `GET /v1/usage` and the iOS app and widgets read (version 1).
/// It carries usage only: never tokens or other credentials.
public struct UsagePayload: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var generatedAt: Date
    public var refreshedAt: Date?
    public var accounts: [AccountUsage]

    public init(generatedAt: Date, refreshedAt: Date?, accounts: [AccountUsage]) {
        version = Self.currentVersion
        self.generatedAt = generatedAt
        self.refreshedAt = refreshedAt
        self.accounts = accounts
    }

    public static func encode(_ payload: UsagePayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    public static func decode(_ data: Data) throws -> UsagePayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UsagePayload.self, from: data)
    }
}

public struct AccountUsage: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var provider: Provider
    public var source: Account.Source
    public var email: String?
    public var plan: String?
    public var fetchedAt: Date?
    public var windows: [WindowUsage]
    public var issue: IssueUsage?

    public init(account: Account, snapshot: ProviderSnapshot?, issue: ProviderIssue?) {
        id = account.id
        provider = account.provider
        source = account.source
        email = snapshot?.account ?? account.email
        plan = snapshot?.plan ?? account.plan
        fetchedAt = snapshot?.fetchedAt
        windows = snapshot?.windows.map(WindowUsage.init) ?? []
        self.issue = issue.map(IssueUsage.init)
    }

    /// The windows this client understands; unknown kinds from a newer server are skipped.
    public var usageWindows: [UsageWindow] {
        windows.compactMap(\.window)
    }

    public var snapshot: ProviderSnapshot? {
        guard let fetchedAt else { return nil }
        return ProviderSnapshot(provider: provider, plan: plan, account: email, windows: usageWindows, fetchedAt: fetchedAt)
    }
}

public struct WindowUsage: Codable, Equatable, Sendable {
    public var kind: String
    public var model: String?
    public var minutes: Int?
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(_ window: UsageWindow) {
        switch window.kind {
        case .session: kind = "session"
        case .weekly: kind = "weekly"
        case .weeklyModel(let name):
            kind = "weeklyModel"
            model = name
        case .monthly: kind = "monthly"
        case .custom(let length):
            kind = "custom"
            minutes = length
        }
        usedPercent = window.usedPercent
        resetsAt = window.resetsAt
    }

    public var window: UsageWindow? {
        let windowKind: UsageWindow.Kind
        switch kind {
        case "session": windowKind = .session
        case "weekly": windowKind = .weekly
        case "weeklyModel":
            guard let model else { return nil }
            windowKind = .weeklyModel(model)
        case "monthly": windowKind = .monthly
        case "custom":
            guard let minutes else { return nil }
            windowKind = .custom(minutes: minutes)
        default: return nil
        }
        return UsageWindow(kind: windowKind, usedPercent: usedPercent, resetsAt: resetsAt)
    }
}

public struct IssueUsage: Codable, Equatable, Sendable {
    public var kind: String
    public var message: String

    public init(_ issue: ProviderIssue) {
        kind = issue.kind
        message = issue.message
    }
}

extension ProviderIssue {
    public var kind: String {
        switch self {
        case .signedOut: "signedOut"
        case .sessionExpired: "sessionExpired"
        case .noQuota: "noQuota"
        case .rateLimited: "rateLimited"
        case .http: "http"
        case .network: "network"
        case .invalidResponse: "invalidResponse"
        }
    }
}
