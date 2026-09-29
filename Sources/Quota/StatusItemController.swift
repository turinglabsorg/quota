import AppKit
import Combine
import QuotaCore
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let store: UsageStore
    private let accounts: AccountStore
    private let settings: AppSettings
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let labelView = PassthroughHostingView(rootView: StatusLabelView(items: []))
    private var cancellables = Set<AnyCancellable>()
    private var clockTimer: Timer?

    init(store: UsageStore, accounts: AccountStore, settings: AppSettings, linker: LinkController) {
        self.store = store
        self.accounts = accounts
        self.settings = settings
        super.init()
        configureButton()
        configurePopover(linker: linker)
        linker.onLinked = { [weak self] in self?.showPopover() }
        Publishers.Merge3(store.objectWillChange, accounts.objectWillChange, settings.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateLabel() } }
            .store(in: &cancellables)
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLabel() }
        }
        updateLabel()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.setAccessibilityLabel("Quota")
        labelView.autoresizingMask = [.height]
        button.addSubview(labelView)
    }

    private func configurePopover(linker: LinkController) {
        popover.behavior = .transient
        popover.animates = true
        let controller = NSHostingController(rootView: PopoverView(store: store, accounts: accounts, settings: settings, linker: linker, router: PopoverRouter(linker: linker)))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
    }

    private func updateLabel() {
        let now = Date()
        labelView.rootView = StatusLabelView(items: StatusLabelItem.items(accounts: accounts.accounts, entries: store.entries, displayMode: settings.displayMode, now: now))
        let width = ceil(labelView.fittingSize.width)
        statusItem.length = width
        let height = statusItem.button.map { $0.bounds.height > 0 ? $0.bounds.height : NSStatusBar.system.thickness } ?? NSStatusBar.system.thickness
        labelView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        statusItem.button?.toolTip = tooltip(now: now)
    }

    private func tooltip(now: Date) -> String {
        let lines = accounts.accounts.map { account -> String in
            let name = [account.provider.displayName, account.email].compactMap { $0 }.joined(separator: " · ")
            guard let entry = store.entries[account.id] else { return String(localized: "\(name): updating") }
            guard let window = entry.snapshot?.tightestWindow(at: now) else {
                return "\(name): \(entry.issue?.message ?? String(localized: "no data"))"
            }
            return "\(name): \(window.remainingPercent(at: now))% \(AppSettings.DisplayMode.remaining.suffix) (\(window.label))"
        }
        return lines.isEmpty ? String(localized: "Quota: no linked accounts") : lines.joined(separator: "\n")
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        store.refreshIfStale()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
