import Foundation
import QuotaCore

enum CLIReport {
    static func run() async {
        var accounts = Storage.loadAccounts()
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
    }
}
