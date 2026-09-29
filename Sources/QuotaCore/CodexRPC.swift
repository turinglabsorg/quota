import Foundation

// Talks to the Codex CLI app-server over JSON-RPC, so Codex refreshes its own session.
enum CodexRPC {
    struct Response: Sendable {
        var results: [String: Data] = [:]
        var errors: [String: String] = [:]
    }

    static let arguments = ["-c", "approval_policy=never", "-c", "features.plugins=false", "-s", "read-only", "-a", "never", "app-server"]

    static func call(_ executable: URL, home: URL?, methods: [String], timeout: TimeInterval = 30) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            CodexRPCSession(executable: executable, home: home, methods: methods, continuation: continuation).start(timeout: timeout)
        }
    }

    static func issue(forErrorMessage message: String) -> ProviderIssue {
        let lowered = message.lowercased()
        if lowered.contains("not logged in") || lowered.contains("no account") || lowered.contains("api key") {
            return .signedOut(String(localized: "This Codex account is not signed in with ChatGPT."))
        }
        if ["auth", "login", "sign in", "token", "401", "unauthorized"].contains(where: lowered.contains) {
            return .sessionExpired(String(localized: "Codex session expired: relink the account."))
        }
        return .invalidResponse
    }
}

private final class CodexRPCSession: @unchecked Sendable {
    private let executable: URL
    private let home: URL?
    private let methods: [String]
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var response = CodexRPC.Response()
    private var continuation: CheckedContinuation<CodexRPC.Response, Error>?

    init(executable: URL, home: URL?, methods: [String], continuation: CheckedContinuation<CodexRPC.Response, Error>) {
        self.executable = executable
        self.home = home
        self.methods = methods
        self.continuation = continuation
    }

    func start(timeout: TimeInterval) {
        process.executableURL = executable
        process.arguments = CodexRPC.arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = environment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [self] _ in finish(.failure(ProviderIssue.invalidResponse)) }
        output.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                finish(.failure(ProviderIssue.invalidResponse))
            } else {
                consume(chunk)
            }
        }
        do {
            try process.run()
        } catch {
            finish(.failure(ProviderIssue.invalidResponse))
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
            finish(.failure(ProviderIssue.network))
        }
        send(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["clientInfo": ["name": "quota", "version": "1.0.0"]]])
    }

    private func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extra = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let current = environment["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        environment["PATH"] = (current + extra.filter { !current.contains($0) }).joined(separator: ":")
        if let home { environment["CODEX_HOME"] = home.path }
        return environment
    }

    private func consume(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<newline]))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()

        for line in lines {
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = JSON.number(message["id"]).map(Int.init)
            else { continue }
            if id == 0 {
                send(["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()])
                for (index, method) in methods.enumerated() {
                    send(["jsonrpc": "2.0", "id": index + 1, "method": method, "params": [String: Any]()])
                }
                continue
            }
            guard methods.indices.contains(id - 1) else { continue }
            let method = methods[id - 1]
            lock.withLock {
                if let error = JSON.dict(message["error"]) {
                    response.errors[method] = JSON.string(error["message"]) ?? "error"
                } else if let result = message["result"], let data = try? JSONSerialization.data(withJSONObject: result) {
                    response.results[method] = data
                }
            }
            let done = lock.withLock { response.results.count + response.errors.count == methods.count }
            if done {
                finish(.success(lock.withLock { response }))
            }
        }
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        do {
            try input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
        } catch {
            finish(.failure(ProviderIssue.invalidResponse))
        }
    }

    private func finish(_ result: Result<CodexRPC.Response, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        continuation.resume(with: result)
    }
}
