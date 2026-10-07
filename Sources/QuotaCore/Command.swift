import Foundation

struct CommandResult: Sendable {
    var status: Int32
    var stdout: String
}

enum CommandError: Error {
    case timedOut
}

enum CommandRunner {
    static func run(
        _ executable: URL,
        _ arguments: [String],
        environment overrides: [String: String?] = [:],
        timeout: TimeInterval,
        keepStdinOpen: Bool = false,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        let job = CommandJob(
            executable: executable,
            arguments: arguments,
            environment: environment(overrides, executable: executable),
            keepStdinOpen: keepStdinOpen,
            onOutput: onOutput
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            job.cancel()
        }
    }

    private static func environment(_ overrides: [String: String?], executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extra = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        environment["PATH"] = (current + extra.filter { !current.contains($0) }).joined(separator: ":")
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }
}

private final class CommandJob: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private let keepStdinOpen: Bool
    private let onOutput: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var stdout = Data()
    private var openStreams = 2
    private var exitStatus: Int32?
    private var cancelled = false
    private var continuation: CheckedContinuation<CommandResult, Error>?

    init(executable: URL, arguments: [String], environment: [String: String], keepStdinOpen: Bool, onOutput: (@Sendable (String) -> Void)?) {
        self.keepStdinOpen = keepStdinOpen
        self.onOutput = onOutput
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start(timeout: TimeInterval, continuation: CheckedContinuation<CommandResult, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        process.terminationHandler = { [self] process in
            lock.locked { exitStatus = process.terminationStatus }
            completeIfDrained()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                let status = lock.locked { exitStatus }
                if let status { finish(.success(status)) }
            }
        }
        do {
            try process.run()
        } catch {
            finish(.failure(error))
            return
        }
        if !keepStdinOpen {
            try? stdinPipe.fileHandleForWriting.close()
        }
        drain(stdoutPipe, keep: true)
        drain(stderrPipe, keep: false)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            finish(.failure(CommandError.timedOut))
        }
    }

    func cancel() {
        lock.locked { cancelled = true }
        finish(.failure(CancellationError()))
    }

    private func drain(_ pipe: Pipe, keep: Bool) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                if keep { lock.locked { stdout.append(chunk) } }
                onOutput?(String(decoding: chunk, as: UTF8.self))
            }
            lock.locked { openStreams -= 1 }
            completeIfDrained()
        }
    }

    private func completeIfDrained() {
        let status: Int32? = lock.locked { openStreams == 0 ? exitStatus : nil }
        if let status { finish(.success(status)) }
    }

    private func finish(_ result: Result<Int32, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let output = String(decoding: stdout, as: UTF8.self)
        lock.unlock()

        if case .failure = result, process.isRunning {
            process.terminate()
        }
        try? stdinPipe.fileHandleForWriting.close()
        continuation.resume(with: result.map { CommandResult(status: $0, stdout: output) })
    }
}

enum CLI {
    private static let cache = ExecutableCache()

    static func locate(_ provider: Provider) async -> URL? {
        let name = provider.executableName
        if let cached = cache.get(name), FileManager.default.isExecutableFile(atPath: cached.path) {
            return cached
        }
        let home = LocalFiles.home.path
        let directories = [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
            "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.claude/local",
        ]
        var found = directories.map { "\($0)/\(name)" }
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
        if found == nil {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            if let result = try? await CommandRunner.run(URL(fileURLWithPath: shell), ["-lc", "command -v \(name)"], timeout: 10),
               result.status == 0,
               let path = result.stdout.split(separator: "\n").last.map({ String($0).trimmingCharacters(in: .whitespaces) }),
               FileManager.default.isExecutableFile(atPath: path) {
                found = URL(fileURLWithPath: path)
            }
        }
        if let found { cache.set(name, found) }
        return found
    }
}

private final class ExecutableCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: URL] = [:]

    func get(_ key: String) -> URL? { lock.locked { values[key] } }
    func set(_ key: String, _ value: URL) { lock.locked { values[key] = value } }
}
