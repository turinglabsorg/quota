import AppKit
import QuotaCore
import SwiftUI

// Renders the UI with sample data so the design can be checked without touching real accounts.
@MainActor
enum PreviewRenderer {
    private static let claude = Account(provider: .claude, source: .cli, email: "name@example.com", plan: "Team")
    private static let codex = Account(provider: .codex, source: .managed, email: "name@example.com", plan: "Plus")
    private static let grok = Account(provider: .grok, source: .managed, email: "name@example.com", plan: nil)
    private static let ollama = Account(provider: .ollama, source: .managed, email: "name@example.com", plan: "Max")

    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let settings = AppSettings()
        let accounts = [claude, codex, grok, ollama]
        let variants: [(name: String, accounts: [Account], entries: [UUID: UsageStore.Entry])] = [
            ("healthy", accounts, healthyEntries(now: now)),
            ("issues", accounts, issueEntries(now: now)),
            ("empty", [], [:]),
        ]
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let background = scheme == .dark ? Color(white: 0.16) : Color(white: 0.95)
            for variant in variants {
                let items = StatusLabelItem.items(accounts: variant.accounts, entries: variant.entries, displayMode: settings.displayMode, now: now)
                write(
                    StatusLabelView(items: items).frame(height: 24).background(background).environment(\.colorScheme, scheme),
                    to: directory.appending(path: "menubar-\(variant.name)-\(suffix).png")
                )
                write(
                    UsagePanel(
                        accounts: variant.accounts,
                        entries: variant.entries,
                        lastRefresh: now.addingTimeInterval(-120),
                        isRefreshing: false,
                        now: now,
                        settings: settings,
                        onRefresh: {},
                        onAddAccount: {},
                        onUnlink: { _ in }
                    )
                    .background(background)
                    .environment(\.colorScheme, scheme),
                    to: directory.appending(path: "panel-\(variant.name)-\(suffix).png")
                )
            }
            write(
                ReadmeHero(
                    items: StatusLabelItem.items(accounts: accounts, entries: healthyEntries(now: now), displayMode: settings.displayMode, now: now),
                    panel: UsagePanel(
                        accounts: accounts,
                        entries: healthyEntries(now: now),
                        lastRefresh: now.addingTimeInterval(-120),
                        isRefreshing: false,
                        now: now,
                        settings: settings,
                        onRefresh: {},
                        onAddAccount: {},
                        onUnlink: { _ in }
                    ),
                    scheme: scheme
                )
                .environment(\.colorScheme, scheme)
                .environment(\.isStaticPreview, true),
                to: directory.appending(path: "readme-\(suffix).png")
            )
            let store = AccountStore(accounts: [claude])
            let linker = LinkController(
                accounts: store,
                sharedLogins: [
                    .claude: AccountIdentity(email: "name@example.com", plan: "Team"),
                    .codex: AccountIdentity(email: "other@example.com", plan: "Free"),
                    .ollama: AccountIdentity(email: "name@example.com", plan: "Max"),
                ],
                signInStates: [.codex: .waiting(URL(string: "https://auth.openai.com/oauth/authorize")), .grok: .failed(String(localized: "\(Provider.grok.displayName) sign-in was not completed."))]
            )
            write(
                AddAccountPanel(linker: linker, accounts: store, onBack: {}).background(background).environment(\.colorScheme, scheme),
                to: directory.appending(path: "add-account-\(suffix).png")
            )
        }
    }

    private static func healthyEntries(now: Date) -> [UUID: UsageStore.Entry] {
        [
            claude.id: UsageStore.Entry(snapshot: ProviderSnapshot(provider: .claude, plan: "Team", account: claude.email, windows: [
                UsageWindow(kind: .session, usedPercent: 28, resetsAt: now.addingTimeInterval(2 * 3_600 + 640)),
                UsageWindow(kind: .weekly, usedPercent: 64, resetsAt: now.addingTimeInterval(3 * 86_400 + 4 * 3_600)),
                UsageWindow(kind: .weeklyModel("Fable"), usedPercent: 83, resetsAt: now.addingTimeInterval(3 * 86_400 + 4 * 3_600)),
            ])),
            codex.id: UsageStore.Entry(snapshot: ProviderSnapshot(provider: .codex, plan: "Plus", account: codex.email, windows: [
                UsageWindow(kind: .session, usedPercent: 12, resetsAt: now.addingTimeInterval(4 * 3_600 + 90)),
                UsageWindow(kind: .weekly, usedPercent: 37, resetsAt: now.addingTimeInterval(5 * 86_400 + 13 * 3_600)),
            ])),
            grok.id: UsageStore.Entry(snapshot: ProviderSnapshot(provider: .grok, plan: "SuperGrok", account: grok.email, windows: [
                UsageWindow(kind: .weekly, usedPercent: 96, resetsAt: now.addingTimeInterval(3 * 86_400 + 9 * 3_600)),
            ])),
            ollama.id: UsageStore.Entry(snapshot: ProviderSnapshot(provider: .ollama, plan: "Max", account: ollama.email, windows: [
                UsageWindow(kind: .monthly, usedPercent: 43, resetsAt: nil),
            ])),
        ]
    }

    private static func issueEntries(now: Date) -> [UUID: UsageStore.Entry] {
        var entries = healthyEntries(now: now)
        entries[claude.id]?.issue = .sessionExpired(String(localized: "The Claude Code session expired and could not be renewed automatically. Run `claude` in a terminal."))
        entries[claude.id]?.snapshot?.fetchedAt = now.addingTimeInterval(-900)
        entries[codex.id] = UsageStore.Entry(snapshot: nil, issue: .sessionExpired(String(localized: "Codex session expired: relink the account.")))
        entries[grok.id] = UsageStore.Entry(snapshot: nil, issue: .network)
        return entries
    }

    private static func write<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }
}

private struct ReadmeHero: View {
    let items: [StatusLabelItem]
    let panel: UsagePanel
    let scheme: ColorScheme

    private var isDark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 14) {
                Spacer()
                StatusLabelView(items: items)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.1)))
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text(verbatim: "9:41")
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(isDark ? Color.black.opacity(0.35) : Color.white.opacity(0.55))
            panel
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isDark ? Color(white: 0.17) : Color(white: 0.97))
                        .shadow(color: .black.opacity(isDark ? 0.5 : 0.18), radius: 24, y: 10)
                )
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08)))
                .padding(.trailing, 40)
        }
        .padding(.bottom, 48)
        .frame(width: 720)
        .background(
            LinearGradient(
                colors: isDark
                    ? [Color(red: 0.13, green: 0.12, blue: 0.2), Color(red: 0.24, green: 0.14, blue: 0.16)]
                    : [Color(red: 0.86, green: 0.89, blue: 0.97), Color(red: 0.98, green: 0.88, blue: 0.83)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}
