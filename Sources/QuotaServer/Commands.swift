import Foundation
import QuotaCore

enum Commands {
    static let defaultPort: UInt16 = 4310

    static func run(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            printUsage()
            return 1
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "serve": return await serve(rest)
        case "status": return await status()
        case "detect": return await detect()
        case "accounts": return listAccounts()
        case "link": return await link(rest)
        case "signin": return await signIn(rest)
        case "unlink": return await unlink(rest)
        case "pair": return pair()
        case "devices": return listDevices()
        case "revoke": return revoke(rest)
        case "help", "-h", "--help":
            printUsage()
            return 0
        default:
            printUsage()
            return 1
        }
    }

    private static func printUsage() {
        print("""
        quota-server: publishes the usage of the accounts linked on this Mac for the Quota iOS app.

        Usage:
          quota-server serve [--port N]   serve the API on localhost (PORT env or \(defaultPort))
          quota-server status             fetch and print the usage of the linked accounts
          quota-server detect             show the CLI logins found on this Mac
          quota-server accounts           list the linked accounts
          quota-server link <service>     link the CLI login of claude, codex, grok or ollama
          quota-server signin ollama      link another Ollama Cloud account (approve it in any browser)
          quota-server unlink <id>        unlink an account (id prefix from `accounts`)
          quota-server pair               create a single-use code to pair a device
          quota-server devices            list paired devices
          quota-server revoke <id>        revoke a paired device (id prefix from `devices`)
        """)
    }

    // MARK: Server

    private static func serve(_ arguments: [String]) async -> Int32 {
        let requested = value(of: "--port", in: arguments) ?? ProcessInfo.processInfo.environment["PORT"]
        guard let port = requested.map({ UInt16($0) }) ?? defaultPort else {
            log("invalid port \(requested ?? "")")
            return 1
        }
        let cache = UsageCache()
        let server: HTTPServer
        do {
            server = try HTTPServer(port: port, handler: Routes.handler(cache: cache, devices: .standard))
        } catch {
            log("cannot listen on port \(port): \(error)")
            return 1
        }
        server.start()
        log("listening on localhost:\(port) with \(AccountStorage.load().count) linked account(s)")
        while true {
            await cache.refresh()
            let payload = await cache.payload()
            let issues = payload.accounts.filter { $0.issue != nil }.count
            log("refreshed \(payload.accounts.count) account(s), \(issues) with issues")
            try? await Task.sleep(nanoseconds: UInt64(UsageCache.refreshInterval * 1_000_000_000))
        }
    }

    // MARK: Accounts

    private static func status() async -> Int32 {
        let accounts = AccountStorage.load()
        guard !accounts.isEmpty else {
            print("No linked accounts. Run `quota-server detect`, then `quota-server link <service>`.")
            return 0
        }
        let now = Date()
        for account in accounts {
            let title = [account.provider.displayName, account.email].compactMap { $0 }.joined(separator: " · ")
            do {
                let snapshot = try await UsageFetchers.fetch(account)
                print(snapshot.plan.map { "\(title) (\($0))" } ?? title)
                for window in snapshot.windows {
                    let reset = window.resetsAt.map { ", resets in \(Formatting.countdown(to: $0, from: now))" } ?? ""
                    print("  \(window.label): \(window.remainingPercent(at: now))% left\(reset)")
                }
            } catch let issue as ProviderIssue {
                print("\(title): \(issue.message)")
            } catch {
                print("\(title): \(ProviderIssue.network.message)")
            }
        }
        return 0
    }

    private static func detect() async -> Int32 {
        for provider in Provider.allCases {
            if let identity = await AccountLinker.detectCLILogin(provider) {
                let details = [identity.email, identity.plan].compactMap { $0 }.joined(separator: " · ")
                print("\(provider.rawValue): \(details.isEmpty ? "signed in" : details)")
            } else {
                print("\(provider.rawValue): not signed in")
            }
        }
        return 0
    }

    private static func listAccounts() -> Int32 {
        let accounts = AccountStorage.load()
        if accounts.isEmpty { print("No linked accounts.") }
        for account in accounts {
            let source = account.source == .cli ? "\(account.provider.cliName) login" : "linked by Quota"
            print("\(shortID(account.id))  \(account.provider.displayName)  \(account.email ?? "-")  (\(source))")
        }
        return 0
    }

    private static func link(_ arguments: [String]) async -> Int32 {
        guard let provider = arguments.first.flatMap(Provider.init(rawValue:)) else {
            print("Usage: quota-server link <claude|codex|grok|ollama>")
            return 1
        }
        if AccountStorage.load().contains(where: { $0.provider == provider && $0.source == .cli }) {
            print("The \(provider.cliName) login is already linked.")
            return 0
        }
        guard let identity = await AccountLinker.detectCLILogin(provider) else {
            print("No \(provider.cliName) login on this Mac. Sign in with the CLI first, then run this again.")
            return 1
        }
        let account = Account(provider: provider, source: .cli, email: identity.email, plan: identity.plan)
        save(adding: account)
        print("Linked \(provider.displayName) · \(identity.email ?? "account") (\(shortID(account.id)))")
        return 0
    }

    private static func signIn(_ arguments: [String]) async -> Int32 {
        guard arguments.first == Provider.ollama.rawValue else {
            print("Only Ollama Cloud can be signed in remotely. For the other services, sign in with their CLI on this Mac, then run `quota-server link <service>`.")
            return 1
        }
        let id = UUID()
        print("Waiting for approval…")
        do {
            let identity = try await AccountLinker.signIn(.ollama, accountID: id) { url in
                print("Open this link in any browser and approve the device:\n\(url.absoluteString)")
            }
            save(adding: Account(id: id, provider: .ollama, source: .managed, email: identity.email, plan: identity.plan))
            print("Linked Ollama Cloud · \(identity.email ?? "account") (\(shortID(id)))")
            return 0
        } catch let error as LinkError {
            print(error.message)
        } catch {
            print("Ollama Cloud sign-in was not completed.")
        }
        return 1
    }

    private static func unlink(_ arguments: [String]) async -> Int32 {
        guard let prefix = arguments.first?.lowercased(), !prefix.isEmpty else {
            print("Usage: quota-server unlink <id>")
            return 1
        }
        var accounts = AccountStorage.load()
        let matches = accounts.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        guard matches.count == 1, let account = matches.first else {
            print(matches.isEmpty ? "No linked account with id \(prefix)." : "More than one account matches \(prefix).")
            return 1
        }
        accounts.removeAll { $0.id == account.id }
        AccountStorage.save(accounts)
        await AccountLinker.unlink(account)
        print("Unlinked \(account.provider.displayName) · \(account.email ?? "account")")
        return 0
    }

    // MARK: Devices

    private static func pair() -> Int32 {
        do {
            let pairing = try DeviceStore.standard.createPairingCode()
            let code = pairing.code
            let grouped = "\(code.prefix(4)) \(code.suffix(4))"
            print("Pairing code: \(grouped)\nValid for 10 minutes, single use. Enter it in the Quota iOS app.")
            return 0
        } catch {
            print("Could not create a pairing code: \(error)")
            return 1
        }
    }

    private static func listDevices() -> Int32 {
        let devices = DeviceStore.standard.devices()
        if devices.isEmpty { print("No paired devices.") }
        let formatter = ISO8601DateFormatter()
        for device in devices {
            let seen = device.lastSeenAt.map { formatter.string(from: $0) } ?? "never"
            print("\(shortID(device.id))  \(device.name)  paired \(formatter.string(from: device.createdAt))  last seen \(seen)")
        }
        return 0
    }

    private static func revoke(_ arguments: [String]) -> Int32 {
        guard let prefix = arguments.first, !prefix.isEmpty else {
            print("Usage: quota-server revoke <id>")
            return 1
        }
        guard let device = try? DeviceStore.standard.revoke(idPrefix: prefix) else {
            print("No single paired device matches \(prefix).")
            return 1
        }
        print("Revoked \(device.name)")
        return 0
    }

    // MARK: Helpers

    private static func save(adding account: Account) {
        let order = Provider.allCases
        let accounts = (AccountStorage.load() + [account]).enumerated()
            .sorted { lhs, rhs in
                let left = order.firstIndex(of: lhs.element.provider) ?? 0
                let right = order.firstIndex(of: rhs.element.provider) ?? 0
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
        AccountStorage.save(accounts)
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    private static func value(of option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func log(_ message: String) {
        print("[\(ISO8601DateFormatter().string(from: Date()))] \(message)")
    }
}
