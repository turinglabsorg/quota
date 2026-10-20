import Foundation

public enum Provider: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude
    case codex
    case grok
    case ollama
    case musecode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        case .ollama: "Ollama Cloud"
        case .musecode: "Muse Code"
        }
    }

    public var cliName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok"
        case .ollama: "Ollama"
        case .musecode: "Muse"
        }
    }

    var executableName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .grok: "grok"
        case .ollama: "ollama"
        case .musecode: "muse"
        }
    }

    /// Muse Code is the local `muse login` only. Quota does not start a second device login.
    public var supportsAnotherAccount: Bool { self != .musecode }
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
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Quota/Accounts")
    }

    public static func home(provider: Provider, id: UUID) -> URL {
        root.appendingPathComponent(provider.rawValue).appendingPathComponent(id.uuidString)
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

/// Token totals over a period, for a provider that also reports usage beside its quota windows.
public struct TokenUsage: Equatable, Identifiable, Sendable {
    public var period: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedTokens: Int
    public var cacheWriteTokens: Int
    public var reasoningTokens: Int
    public var sessions: Int
    public var steps: Int
    public var resetsAt: Date?

    public init(period: String, inputTokens: Int, outputTokens: Int, cachedTokens: Int, cacheWriteTokens: Int, reasoningTokens: Int, sessions: Int, steps: Int, resetsAt: Date?) {
        self.period = period
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.sessions = sessions
        self.steps = steps
        self.resetsAt = resetsAt
    }

    public var id: String { period }

    /// `inputTokens` already includes the cached share, and reasoning is part of `outputTokens`.
    public var totalTokens: Int { inputTokens + outputTokens }

    public var label: String {
        period == "today" ? String(localized: "Today") : String(localized: "Last 7 days")
    }

    public func hasReset(at now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    public var breakdown: String {
        String(localized: "in \(Formatting.formatTokens(inputTokens)) · out \(Formatting.formatTokens(outputTokens)) · cache \(Formatting.formatTokens(cachedTokens)) · reasoning \(Formatting.formatTokens(reasoningTokens)) · \(sessions) sessions · \(steps) steps")
    }
}

/// One ChatGPT rate-limit reset Codex has granted and not yet used.
public struct ResetCredit: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var expiresAt: Date?

    public init(id: String, title: String, expiresAt: Date?) {
        self.id = id
        self.title = title
        self.expiresAt = expiresAt
    }

    /// Codex sends "Full reset" (sometimes with the windows it covers). Other titles stay as written.
    public var label: String {
        let lowered = title.lowercased()
        if lowered == "full reset" { return String(localized: "Full reset") }
        if lowered.hasPrefix("full reset") { return String(localized: "Full reset") + title.dropFirst("Full reset".count) }
        return title
    }
}

/// Banked ChatGPT resets. `availableCount` is the total Codex reports; `credits` are the ones with an expiry.
public struct ResetCredits: Equatable, Sendable {
    public var availableCount: Int
    public var credits: [ResetCredit]

    public init(availableCount: Int, credits: [ResetCredit]) {
        self.availableCount = availableCount
        self.credits = credits
    }

    public var count: Int { max(availableCount, credits.count) }
    public var isEmpty: Bool { count <= 0 }
}

public struct ProviderSnapshot: Equatable, Sendable {
    public var provider: Provider
    public var plan: String?
    public var account: String?
    public var windows: [UsageWindow]
    public var tokenUsage: [TokenUsage]
    public var resetCredits: ResetCredits?
    public var fetchedAt: Date
    public var issue: ProviderIssue?

    public init(provider: Provider, plan: String?, account: String? = nil, windows: [UsageWindow], tokenUsage: [TokenUsage] = [], resetCredits: ResetCredits? = nil, fetchedAt: Date = Date(), issue: ProviderIssue? = nil) {
        self.provider = provider
        self.plan = plan
        self.account = account
        self.windows = windows
        self.tokenUsage = tokenUsage
        self.resetCredits = resetCredits
        self.fetchedAt = fetchedAt
        self.issue = issue
    }

    /// The menu bar shows the 5-hour session above the longer window (weekly or monthly) when an
    /// account reports both, otherwise the tightest account-wide window.
    public func menuBarWindows(at now: Date) -> [UsageWindow] {
        let session = windows.first { $0.kind == .session }
        let longer = windows.first { $0.kind == .weekly } ?? windows.first { $0.kind == .monthly }
        if let session, let longer { return [session, longer] }
        return tightestWindow(at: now).map { [$0] } ?? []
    }

    public func reportLines(at now: Date) -> [String] {
        var lines: [String] = []
        for usage in tokenUsage {
            let reset = usage.resetsAt.map { ", resets in \(Formatting.countdown(to: $0, from: now))" } ?? ""
            lines.append("  \(usage.label): \(Formatting.formatTokens(usage.totalTokens)) \(String(localized: "tokens"))\(reset)")
            lines.append("    \(usage.breakdown)")
        }
        for window in windows {
            let reset = window.resetsAt.map { ", resets in \(Formatting.countdown(to: $0, from: now))" } ?? ""
            lines.append("  \(window.label): \(window.remainingPercent(at: now))% left\(reset)")
        }
        if let resetCredits, !resetCredits.isEmpty {
            lines.append("  \(String(localized: "Resets")): \(String(localized: "\(resetCredits.count) available"))")
            for credit in resetCredits.credits {
                let expiry = credit.expiresAt.map { ", \(String(localized: "expires in \(Formatting.countdown(to: $0, from: now))"))" } ?? ""
                lines.append("    \(credit.label)\(expiry)")
            }
        }
        return lines
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
    case retryLater(Date)
    case usageUnavailable(String)
    case http(Int)
    case network
    case invalidResponse

    public var message: String {
        switch self {
        case .signedOut(let message), .sessionExpired(let message), .noQuota(let message), .usageUnavailable(let message):
            message
        case .rateLimited:
            String(localized: "Too many requests: retrying later.")
        case .retryLater(let date):
            String(localized: "Too many requests: next attempt in \(Formatting.countdown(to: date, from: Date())).")
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
