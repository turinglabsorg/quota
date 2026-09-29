import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let accounts = AccountStore()
    private lazy var store = UsageStore(accounts: accounts)
    private lazy var linker = LinkController(accounts: accounts)
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController(store: store, accounts: accounts, settings: settings, linker: linker)
        store.start()
        if accounts.accounts.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.statusController?.showPopover()
            }
        }
    }
}
