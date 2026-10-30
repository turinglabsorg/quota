import Foundation
import QuotaCore

enum CLIReport {
    static func run() async {
        if let server = ServerConnection.serverURL {
            await runFromServer(server)
            return
        }
        var accounts = AccountStorage.load()
        if accounts.isEmpty {
            print("No accounts linked in Quota: showing the CLI logins found on this Mac.\n")
            for provider in Provider.allCases {
                if let identity = await AccountLinker.detectCLILogin(provider) {
                    accounts.append(Account(provider: provider, source: .cli, email: identity.email, plan: identity.plan))
                }
            }
        }
        let now = Date()
        for account in accounts {
            let title = [account.provider.displayName, account.email, account.sourceLabel].compactMap { $0 }.joined(separator: " · ")
            do {
                let snapshot = try await UsageFetchers.fetch(account)
                print(snapshot.plan.map { "\(title) (\($0))" } ?? title)
                for line in snapshot.reportLines(at: now) {
                    print(line)
                }
                if let issue = snapshot.issue { print("  \(issue.message)") }
            } catch let issue as ProviderIssue {
                print("\(title): \(issue.message)")
            } catch {
                print("\(title): \(ProviderIssue.network.message)")
            }
        }
    }

    private static func runFromServer(_ server: URL) async {
        let payload: UsagePayload
        do {
            payload = try await ServerConnection.fetchUsage()
        } catch let failure as ServerConnection.Failure {
            print("\(server.host ?? server.absoluteString): \(failure.message)")
            return
        } catch {
            print("\(server.host ?? server.absoluteString): \(ServerConnection.Failure.network.message)")
            return
        }
        let now = Date()
        let updated = payload.refreshedAt.map { Formatting.relative($0, from: now) } ?? "-"
        print("Quota server \(server.host ?? server.absoluteString), updated \(updated)\n")
        for usage in payload.accounts {
            let account = usage.account
            let title = [account.provider.displayName, account.email, account.sourceLabel].compactMap { $0 }.joined(separator: " · ")
            print(account.plan.map { "\(title) (\($0))" } ?? title)
            for line in usage.snapshot?.reportLines(at: now) ?? [] {
                print(line)
            }
            if let issue = usage.issue { print("  \(issue.message)") }
        }
    }

    /// `--pair <address> <code>`: pairs this Mac with a quota-server, like the Quota server page.
    static func pair(address: String, code: String) async -> Int32 {
        guard let server = ServerConnection.address(from: address) else {
            print(ServerConnection.Failure.invalidAddress.message)
            return 1
        }
        do {
            try await ServerConnection.pair(server: server, code: code, deviceName: Host.current().localizedName ?? "Mac")
            print("Paired with \(server.absoluteString).")
            return 0
        } catch let failure as ServerConnection.Failure {
            print(failure.message)
        } catch {
            print(ServerConnection.Failure.network.message)
        }
        return 1
    }
}
