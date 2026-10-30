import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let accounts = AccountStore()
    private let server = ServerLink()
    private lazy var store = UsageStore(accounts: accounts, server: server)
    private lazy var linker = LinkController(accounts: accounts)
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController(store: store, accounts: accounts, settings: settings, server: server, linker: linker)
        store.start()
        if accounts.accounts.isEmpty && !server.isConnected {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.statusController?.showPopover()
            }
        }
    }
}
