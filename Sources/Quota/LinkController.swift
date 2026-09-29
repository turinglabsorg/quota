import Foundation
import QuotaCore

@MainActor
final class LinkController: ObservableObject {
    enum SignInState: Equatable {
        case idle
        case waiting(URL?)
        case failed(String)
    }

    @Published private(set) var sharedLogins: [Provider: AccountIdentity]
    @Published private(set) var isDetecting = false
    @Published private(set) var signInStates: [Provider: SignInState]
    @Published private(set) var lastLinkedID: UUID?

    var onLinked: (() -> Void)?

    private let accounts: AccountStore
    private var tasks: [Provider: Task<Void, Never>] = [:]

    init(accounts: AccountStore, sharedLogins: [Provider: AccountIdentity] = [:], signInStates: [Provider: SignInState] = [:]) {
        self.accounts = accounts
        self.sharedLogins = sharedLogins
        self.signInStates = signInStates
    }

    func state(for provider: Provider) -> SignInState {
        signInStates[provider] ?? .idle
    }

    func detectSharedLogins() {
        guard !isDetecting else { return }
        isDetecting = true
        Task {
            var found: [Provider: AccountIdentity] = [:]
            await withTaskGroup(of: (Provider, AccountIdentity?).self) { group in
                for provider in Provider.allCases {
                    group.addTask { (provider, await AccountLinker.detectCLILogin(provider)) }
                }
                for await (provider, identity) in group {
                    if let identity { found[provider] = identity }
                }
            }
            sharedLogins = found
            isDetecting = false
        }
    }

    func linkSharedLogin(_ provider: Provider) {
        guard !accounts.hasSharedLogin(provider) else { return }
        let identity = sharedLogins[provider]
        let account = Account(provider: provider, source: .cli, email: identity?.email, plan: identity?.plan)
        accounts.add(account)
        lastLinkedID = account.id
    }

    func startSignIn(_ provider: Provider) {
        tasks[provider]?.cancel()
        signInStates[provider] = .waiting(nil)
        let id = UUID()
        tasks[provider] = Task { [weak self] in
            do {
                let identity = try await AccountLinker.signIn(provider, accountID: id) { [weak self] url in
                    Task { @MainActor in self?.showLoginURL(url, for: provider) }
                }
                await self?.finishSignIn(provider, account: Account(id: id, provider: provider, source: .managed, email: identity.email, plan: identity.plan))
            } catch is CancellationError {
                self?.signInStates[provider] = .idle
            } catch let error as LinkError {
                self?.signInStates[provider] = .failed(error.message)
            } catch {
                self?.signInStates[provider] = .failed(String(localized: "\(provider.displayName) sign-in was not completed."))
            }
            self?.tasks[provider] = nil
        }
    }

    func cancelSignIn(_ provider: Provider) {
        tasks[provider]?.cancel()
    }

    func unlink(_ account: Account) {
        accounts.remove(account.id)
        Task { await AccountLinker.unlink(account) }
    }

    private func showLoginURL(_ url: URL, for provider: Provider) {
        guard case .waiting(nil) = state(for: provider) else { return }
        signInStates[provider] = .waiting(url)
    }

    private func finishSignIn(_ provider: Provider, account: Account) async {
        if let email = account.email, accounts.hasManagedAccount(provider, email: email) {
            await AccountLinker.unlink(account)
            signInStates[provider] = .failed(String(localized: "\(email) is already linked."))
            return
        }
        accounts.add(account)
        signInStates[provider] = .idle
        lastLinkedID = account.id
        onLinked?()
    }
}
