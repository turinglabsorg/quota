import CryptoKit
import Darwin
import Foundation

/// App, server and CLI share one polling budget, including after a relaunch.
struct ClaudeUsageGate {
    static let interval: TimeInterval = 5 * 60
    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Quota/ClaudeUsage")) {
        self.directory = directory
    }

    struct State: Codable {
        var snapshot: AccountUsage?
        var attempts = 0
        var notBefore: Date?
    }

    func fetch(
        account: Account,
        now: @escaping @Sendable () -> Date = { Date() },
        operation: (RetryAfter) async throws -> ProviderSnapshot
    ) async throws -> ProviderSnapshot {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = account.home?.path ?? "shared:\(account.email?.lowercased() ?? "claude")"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent("\(key).json")
        let descriptor = open(directory.appendingPathComponent("\(key).lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw ProviderIssue.network }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw ProviderIssue.network }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()

        var state = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        if let notBefore = state.notBefore, notBefore > now() {
            debug("cooldown active; no HTTP request")
            throw ProviderIssue.retryLater(notBefore)
        }
        if let snapshot = state.snapshot?.snapshot,
           now().timeIntervalSince(snapshot.fetchedAt) >= 0,
           now().timeIntervalSince(snapshot.fetchedAt) < Self.interval {
            debug("using cached usage; no HTTP request")
            return snapshot
        }

        let retryAfter = RetryAfter()
        do {
            let snapshot = try await operation(retryAfter)
            state = State(snapshot: AccountUsage(account: account, snapshot: snapshot, issue: nil))
            try save(state, to: file)
            return snapshot
        } catch ProviderIssue.rateLimited {
            let notBefore = now().addingTimeInterval(Self.delay(attempt: state.attempts, retryAfter: retryAfter.seconds))
            state.notBefore = notBefore
            state.attempts = min(state.attempts + 1, 6)
            try save(state, to: file)
            throw ProviderIssue.retryLater(notBefore)
        }
    }

    static func delay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let fallback = TimeInterval([30, 60, 120, 240, 480, 720][min(max(attempt, 0), 5)] * 60)
        guard let retryAfter, retryAfter.isFinite, retryAfter > 0 else { return fallback }
        return max(fallback, retryAfter)
    }

    private func save(_ state: State, to file: URL) throws {
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["QUOTA_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data("[Claude usage] \(message)\n".utf8))
    }
}
