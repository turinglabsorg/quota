import Foundation

public enum UsageFetchers {
    public static func fetch(_ account: Account) async throws -> ProviderSnapshot {
        switch account.provider {
        case .claude: try await ClaudeFetcher(account: account).fetch()
        case .codex: try await CodexFetcher(account: account).fetch()
        case .grok: try await GrokFetcher(account: account).fetch()
        case .ollama: try await OllamaFetcher(account: account).fetch()
        }
    }
}

public struct LinkError: Error, Equatable, Sendable {
    public let message: String

    init(_ message: String) {
        self.message = message
    }
}

public enum AccountLinker {
    private static let loginTimeout: TimeInterval = 600

    public static func detectCLILogin(_ provider: Provider) async -> AccountIdentity? {
        switch provider {
        case .claude:
            guard let executable = await CLI.locate(.claude),
                  let status = try? await CommandRunner.run(executable, ["auth", "status", "--json"], environment: ["CLAUDE_CONFIG_DIR": nil], timeout: 30)
            else { return nil }
            return ClaudeParser.identity(fromStatus: Data(status.stdout.utf8))
        case .codex:
            guard let executable = await CLI.locate(.codex),
                  let response = try? await CodexRPC.call(executable, home: nil, methods: [CodexFetcher.accountMethod]),
                  let data = response.results[CodexFetcher.accountMethod]
            else { return nil }
            return CodexParser.identity(from: data)
        case .grok:
            let placeholder = Account(provider: .grok, source: .cli, email: nil, plan: nil)
            guard let credentials = GrokFetcher.credentials(home: GrokFetcher.home(for: placeholder)) else { return nil }
            return AccountIdentity(email: credentials.email, plan: nil)
        case .ollama:
            let placeholder = Account(provider: .ollama, source: .cli, email: nil, plan: nil)
            guard let key = OllamaCloud.readKey(at: OllamaCloud.keyFile(for: placeholder)) else { return nil }
            return try? await OllamaCloud.whoami(key)
        }
    }

    public static func signIn(_ provider: Provider, accountID: UUID, onLoginURL: @escaping @Sendable (URL) -> Void) async throws -> AccountIdentity {
        let home = AccountPaths.home(provider: provider, id: accountID)
        let onOutput: @Sendable (String) -> Void = { text in
            if let url = LoginURL.first(in: text) { onLoginURL(url) }
        }
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            switch provider {
            case .claude: return try await signInClaude(executable: requireCLI(provider), home: home, onOutput: onOutput)
            case .codex: return try await signInCodex(executable: requireCLI(provider), home: home, onOutput: onOutput)
            case .grok: return try await signInGrok(executable: requireCLI(provider), home: home, onOutput: onOutput)
            case .ollama: return try await signInOllama(home: home, onLoginURL: onLoginURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: home)
            if error is CancellationError { throw error }
            if let error = error as? LinkError { throw error }
            if case CommandError.timedOut = error { throw LinkError(String(localized: "Timed out: sign-in was not completed.")) }
            throw LinkError(String(localized: "\(provider.displayName) sign-in was not completed."))
        }
    }

    public static func unlink(_ account: Account) async {
        guard let home = account.home else { return }
        switch account.provider {
        case .claude:
            await Keychain.delete(service: ManagedClaudeCredentials(home: home).service)
        case .codex:
            if let executable = await CLI.locate(.codex) {
                _ = try? await CommandRunner.run(executable, ["logout"], environment: ["CODEX_HOME": home.path], timeout: 30)
            }
        case .grok:
            if let executable = await CLI.locate(.grok) {
                _ = try? await CommandRunner.run(executable, ["logout"], environment: ["GROK_HOME": home.path], timeout: 30)
            }
        case .ollama:
            if let key = OllamaCloud.readKey(at: home.appending(path: OllamaCloud.keyPath)) {
                await OllamaCloud.disconnect(key)
            }
        }
        try? FileManager.default.removeItem(at: home)
    }

    // Ollama Cloud links a key in the browser; the other services sign in through their CLI.
    private static func requireCLI(_ provider: Provider) async throws -> URL {
        guard let executable = await CLI.locate(provider) else {
            throw LinkError(String(localized: "`\(provider.executableName)` CLI not found: install it and try again."))
        }
        return executable
    }

    // Like `ollama signin`: a new device key, linked on ollama.com to the account the user signs in to.
    private static func signInOllama(home: URL, onLoginURL: @escaping @Sendable (URL) -> Void) async throws -> AccountIdentity {
        let key = try OllamaCloud.createKey(at: home.appending(path: OllamaCloud.keyPath))
        let url = OllamaCloud.connectURL(for: key, deviceName: ProcessInfo.processInfo.hostName)
        onLoginURL(url)
        _ = try? await CommandRunner.run(URL(filePath: "/usr/bin/open"), [url.absoluteString], timeout: 10)
        let deadline = Date().addingTimeInterval(loginTimeout)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(3))
            if let identity = try? await OllamaCloud.whoami(key) {
                return identity
            }
        }
        throw CommandError.timedOut
    }

    private static func signInCodex(executable: URL, home: URL, onOutput: @escaping @Sendable (String) -> Void) async throws -> AccountIdentity {
        let login = try await CommandRunner.run(executable, ["login"], environment: ["CODEX_HOME": home.path], timeout: loginTimeout, onOutput: onOutput)
        guard login.status == 0 else { throw LinkError(String(localized: "\(Provider.codex.displayName) sign-in was not completed.")) }
        let response = try await CodexRPC.call(executable, home: home, methods: [CodexFetcher.accountMethod])
        guard let data = response.results[CodexFetcher.accountMethod], let identity = CodexParser.identity(from: data) else {
            throw LinkError(String(localized: "Codex did not return the linked account."))
        }
        return identity
    }

    private static func signInGrok(executable: URL, home: URL, onOutput: @escaping @Sendable (String) -> Void) async throws -> AccountIdentity {
        // Grok's login expects a terminal; `script` provides a pseudo-terminal.
        let login = try await CommandRunner.run(
            URL(filePath: "/usr/bin/script"),
            ["-q", "/dev/null", executable.path, "login", "--oauth"],
            environment: ["GROK_HOME": home.path],
            timeout: loginTimeout,
            keepStdinOpen: true,
            onOutput: onOutput
        )
        guard login.status == 0, let credentials = GrokFetcher.credentials(home: home) else {
            throw LinkError(String(localized: "\(Provider.grok.displayName) sign-in was not completed."))
        }
        return AccountIdentity(email: credentials.email, plan: nil)
    }

    // Claude Code may also write the shared Keychain item during an isolated login;
    // the shared login is snapshotted and restored so Claude Code keeps its own account.
    private static func signInClaude(executable: URL, home: URL, onOutput: @escaping @Sendable (String) -> Void) async throws -> AccountIdentity {
        let environment: [String: String?] = ["CLAUDE_CONFIG_DIR": home.path]
        let store = ManagedClaudeCredentials(home: home)
        let sharedBefore = await Keychain.read(service: Keychain.claudeService)
        var sharedAfter: Data?
        do {
            let login = try await CommandRunner.run(executable, ["auth", "login", "--claudeai"], environment: environment, timeout: loginTimeout, keepStdinOpen: true, onOutput: onOutput)
            sharedAfter = await Keychain.read(service: Keychain.claudeService)
            guard login.status == 0 else { throw LinkError(String(localized: "\(Provider.claude.displayName) sign-in was not completed.")) }

            if await store.read() == nil, let sharedAfter, sharedAfter != sharedBefore {
                await Keychain.write(service: store.service, data: sharedAfter)
            }
            guard await store.read() != nil else { throw LinkError(String(localized: "Claude did not save the account credentials.")) }

            let status = try await CommandRunner.run(executable, ["auth", "status", "--json"], environment: environment, timeout: 60)
            guard let identity = ClaudeParser.identity(fromStatus: Data(status.stdout.utf8)) else {
                throw LinkError(String(localized: "Claude did not return the linked account."))
            }
            await restoreSharedClaudeLogin(before: sharedBefore, after: sharedAfter)
            return identity
        } catch {
            if sharedAfter == nil { sharedAfter = await Keychain.read(service: Keychain.claudeService) }
            await restoreSharedClaudeLogin(before: sharedBefore, after: sharedAfter)
            await Keychain.delete(service: store.service)
            throw error
        }
    }

    private static func restoreSharedClaudeLogin(before: Data?, after: Data?) async {
        guard before != after else { return }
        if let before {
            await Keychain.write(service: Keychain.claudeService, data: before)
        } else {
            await Keychain.delete(service: Keychain.claudeService)
        }
    }
}
