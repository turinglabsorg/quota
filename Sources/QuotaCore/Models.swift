import Foundation

public enum Provider: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude
    case codex
    case grok

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        }
    }

    public var cliName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok"
        }
    }

    var executableName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .grok: "grok"
        }
    }
}

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        case cli
        case managed
    }

    public let id: UUID
    public let provider: Provider
    public let source: Source
    public var email: String?
    public var plan: String?

    public init(id: UUID = UUID(), provider: Provider, source: Source, email: String?, plan: String?) {
        self.id = id
        self.provider = provider
        self.source = source
        self.email = email
        self.plan = plan
    }

    public var home: URL? {
        source == .managed ? AccountPaths.home(provider: provider, id: id) : nil
    }

    public var sourceLabel: String {
        switch source {
        case .cli: String(localized: "\(provider.cliName) login")
        case .managed: String(localized: "linked by Quota")
        }
    }
}

public struct AccountIdentity: Equatable, Sendable {
    public var email: String?
    public var plan: String?

    public init(email: String?, plan: String?) {
        self.email = email
        self.plan = plan
    }
}

public enum AccountPaths {
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Quota/Accounts")
    }

    public static func home(provider: Provider, id: UUID) -> URL {
        root.appending(path: provider.rawValue).appending(path: id.uuidString)
    }
}

public struct UsageWindow: Identifiable, Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case session
        case weekly
        case weeklyModel(String)
        case monthly
        case custom(minutes: Int)
    }

    public var kind: Kind
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(kind: Kind, usedPercent: Double, resetsAt: Date?) {
        self.kind = kind
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
    }

    public var id: String { label }

    public var label: String {
        switch kind {
        case .session: String(localized: "5-hour session")
        case .weekly: String(localized: "Weekly")
        case .weeklyModel(let model): String(localized: "Weekly · \(model)")
        case .monthly: String(localized: "Monthly")
        case .custom(let minutes): String(localized: "\(Formatting.duration(minutes: minutes)) window")
        }
    }

    public func hasReset(at now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    public func usedPercent(at now: Date) -> Int {
        hasReset(at: now) ? 0 : Int(usedPercent.rounded())
    }

    public func remainingPercent(at now: Date) -> Int {
        100 - usedPercent(at: now)
    }
}

public struct ProviderSnapshot: Equatable, Sendable {
    public var provider: Provider
    public var plan: String?
    public var account: String?
    public var windows: [UsageWindow]
    public var fetchedAt: Date

    public init(provider: Provider, plan: String?, account: String? = nil, windows: [UsageWindow], fetchedAt: Date = Date()) {
        self.provider = provider
        self.plan = plan
        self.account = account
        self.windows = windows
        self.fetchedAt = fetchedAt
    }

    public func tightestWindow(at now: Date) -> UsageWindow? {
        let accountWide = windows.filter {
            if case .weeklyModel = $0.kind { return false }
            return true
        }
        return (accountWide.isEmpty ? windows : accountWide)
            .min { $0.remainingPercent(at: now) < $1.remainingPercent(at: now) }
    }
}

public enum ProviderIssue: Error, Equatable, Sendable {
    case signedOut(String)
    case sessionExpired(String)
    case noQuota(String)
    case rateLimited
    case http(Int)
    case network
    case invalidResponse

    public var message: String {
        switch self {
        case .signedOut(let message), .sessionExpired(let message), .noQuota(let message):
            message
        case .rateLimited:
            String(localized: "Too many requests: retrying on the next refresh.")
        case .http(let status):
            String(localized: "Server error (HTTP \(status)).")
        case .network:
            String(localized: "Network unreachable.")
        case .invalidResponse:
            String(localized: "Unrecognized response.")
        }
    }

    public var keepsLastSnapshot: Bool {
        switch self {
        case .signedOut, .noQuota: false
        default: true
        }
    }
}

public enum UsageLevel: Sendable {
    case normal
    case warning
    case critical

    public init(remainingPercent: Int) {
        switch remainingPercent {
        case ...5: self = .critical
        case ...20: self = .warning
        default: self = .normal
        }
    }
}
