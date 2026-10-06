import AppKit
import Combine
import QuotaCore
import SwiftUI

@MainActor
final class PopoverRouter: ObservableObject {
    enum Page {
        case usage
        case addAccount
    }

    @Published var page: Page = .usage
    private var cancellable: AnyCancellable?

    init(linker: LinkController) {
        cancellable = linker.$lastLinkedID
            .dropFirst()
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.page = .usage } }
    }
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var accounts: AccountStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var linker: LinkController
    @ObservedObject var router: PopoverRouter

    var body: some View {
        switch router.page {
        case .usage:
            TimelineView(.periodic(from: .now, by: 30)) { context in
                UsagePanel(
                    accounts: accounts.accounts,
                    entries: store.entries,
                    lastRefresh: store.lastRefresh,
                    isRefreshing: store.isRefreshing,
                    now: context.date,
                    settings: settings,
                    onRefresh: store.refresh,
                    onAddAccount: { router.page = .addAccount },
                    onUnlink: linker.unlink
                )
            }
        case .addAccount:
            AddAccountPanel(linker: linker, accounts: accounts, onBack: { router.page = .usage })
        }
    }
}

struct UsagePanel: View {
    let accounts: [Account]
    let entries: [UUID: UsageStore.Entry]
    let lastRefresh: Date?
    let isRefreshing: Bool
    let now: Date
    @ObservedObject var settings: AppSettings
    let onRefresh: () -> Void
    let onAddAccount: () -> Void
    let onUnlink: (Account) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            VStack(spacing: 8) {
                if accounts.isEmpty {
                    emptyState
                }
                ForEach(accounts) { account in
                    AccountCard(account: account, entry: entries[account.id], now: now, displayMode: settings.displayMode, onUnlink: onUnlink)
                }
                if let error = settings.loginItemError {
                    IssueLine(icon: "exclamationmark.triangle.fill", tint: .orange, text: error)
                        .padding(.horizontal, 6)
                }
            }
            .padding(.horizontal, 10)
            if !accounts.isEmpty {
                Button(action: onAddAccount) {
                    Label("Add account", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            Spacer().frame(height: 12)
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quota")
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onRefresh) {
                ZStack {
                    if isRefreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isRefreshing || accounts.isEmpty)
            .help("Refresh now")
            SettingsMenu(settings: settings, onAddAccount: onAddAccount)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No linked accounts")
                .font(.system(size: 13, weight: .semibold))
            Text("Choose which Claude, Codex, Grok and Ollama Cloud accounts to monitor.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add account", action: onAddAccount)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var subtitle: String {
        if accounts.isEmpty { return String(localized: "No accounts") }
        if isRefreshing { return String(localized: "Updating…") }
        guard let lastRefresh else { return String(localized: "Waiting for data…") }
        return String(localized: "Updated \(Formatting.relative(lastRefresh, from: now))")
    }
}

private struct SettingsMenu: View {
    @ObservedObject var settings: AppSettings
    let onAddAccount: () -> Void

    @Environment(\.isStaticPreview) private var isStaticPreview

    var body: some View {
        if isStaticPreview {
            Image(systemName: "gearshape").foregroundStyle(.secondary)
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            Picker("Show", selection: $settings.displayMode) {
                ForEach(AppSettings.DisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Add account…", action: onAddAccount)
            Toggle("Launch at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.setLaunchAtLogin($0) }
            ))
            Divider()
            Button("Quit Quota") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Settings")
    }
}

private struct AccountCard: View {
    let account: Account
    let entry: UsageStore.Entry?
    let now: Date
    let displayMode: AppSettings.DisplayMode
    let onUnlink: (Account) -> Void
    @Environment(\.isStaticPreview) private var isStaticPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 7) {
                ProviderGlyph(provider: account.provider)
                    .frame(width: 13, height: 13)
                    .foregroundStyle(account.provider.accent)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.provider.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(entry?.snapshot?.account ?? account.email ?? account.sourceLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if let plan = entry?.snapshot?.plan ?? account.plan {
                    PlanBadge(plan: plan)
                }
                if isStaticPreview {
                    Image(systemName: "ellipsis")
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.secondary)
                } else {
                    Menu {
                        Text(account.source == .cli ? String(localized: "Uses the \(account.provider.cliName) login") : String(localized: "Linked by Quota"))
                        Divider()
                        Button("Unlink account", role: .destructive) { onUnlink(account) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 16, height: 16)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                }
            }
            if let snapshot = entry?.snapshot {
                ForEach(snapshot.windows) { window in
                    WindowRow(window: window, now: now, displayMode: displayMode)
                }
            }
            if let issue = entry?.issue {
                issueLine(issue)
            } else if entry == nil {
                Text("Loading…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func issueLine(_ issue: ProviderIssue) -> some View {
        let text = entry?.snapshot.map { String(localized: "Data from \(Formatting.relative($0.fetchedAt, from: now)). \(issue.message)") } ?? issue.message
        switch issue {
        case .signedOut:
            return IssueLine(icon: "person.crop.circle.badge.questionmark", tint: .secondary, text: text)
        case .noQuota:
            return IssueLine(icon: "infinity", tint: .secondary, text: text)
        case .sessionExpired:
            return IssueLine(icon: "key.fill", tint: .orange, text: text)
        default:
            return IssueLine(icon: "exclamationmark.triangle.fill", tint: .orange, text: text)
        }
    }
}

struct AddAccountPanel: View {
    @ObservedObject var linker: LinkController
    @ObservedObject var accounts: AccountStore
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back")
                Text("Add account")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)
            VStack(spacing: 8) {
                ForEach(Provider.allCases) { provider in
                    ProviderLinkCard(provider: provider, linker: linker, accounts: accounts)
                }
            }
            .padding(.horizontal, 10)
            Text("Sign-in happens in your browser, on the service's official page: Quota never sees your password. Each new account stays separate from your CLI logins.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
        .frame(width: 320)
        .onAppear { linker.detectSharedLogins() }
    }
}

private struct ProviderLinkCard: View {
    let provider: Provider
    @ObservedObject var linker: LinkController
    @ObservedObject var accounts: AccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                ProviderGlyph(provider: provider)
                    .frame(width: 13, height: 13)
                    .foregroundStyle(provider.accent)
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
            }
            sharedLoginRow
            signInRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private var sharedLoginRow: some View {
        if let identity = linker.sharedLogins[provider] {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Current \(provider.cliName) login")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text([identity.email ?? String(localized: "Active account"), identity.plan].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if accounts.hasSharedLogin(provider) {
                    Label("Linked", systemImage: "checkmark")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Link") { linker.linkSharedLogin(provider) }
                        .controlSize(.small)
                }
            }
        } else if linker.isDetecting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                Text("Looking for the \(provider.cliName) login…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No \(provider.cliName) login on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var signInRow: some View {
        switch linker.state(for: provider) {
        case .idle:
            Button {
                linker.startSignIn(provider)
            } label: {
                Label("Sign in to another account…", systemImage: "person.badge.plus")
            }
            .controlSize(.small)
        case .waiting(let url):
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish signing in in your browser…")
                        .font(.system(size: 12))
                    if let url {
                        Link("Open the sign-in page", destination: url)
                            .font(.system(size: 11))
                    }
                }
                Spacer(minLength: 8)
                Button("Cancel") { linker.cancelSignIn(provider) }
                    .controlSize(.small)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                IssueLine(icon: "exclamationmark.triangle.fill", tint: .orange, text: message)
                Button("Try again") { linker.startSignIn(provider) }
                    .controlSize(.small)
            }
        }
    }
}

private struct PlanBadge: View {
    let plan: String

    var body: some View {
        Text(plan)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

private struct WindowRow: View {
    let window: UsageWindow
    let now: Date
    let displayMode: AppSettings.DisplayMode

    var body: some View {
        let remaining = window.remainingPercent(at: now)
        let value = displayMode.value(remaining: remaining)
        let level = UsageLevel(remainingPercent: remaining)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.label)
                    .font(.system(size: 12))
                Spacer(minLength: 8)
                Text(verbatim: "\(value)%")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(level == .normal ? Color.primary : level.barColor)
                Text(displayMode.suffix)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            UsageBar(fraction: Double(value) / 100, color: level.barColor)
            if let resetsAt = window.resetsAt {
                Text(window.hasReset(at: now) ? String(localized: "Reset, updating") : String(localized: "Resets in \(Formatting.countdown(to: resetsAt, from: now))"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(Formatting.absolute(resetsAt))
            }
        }
    }
}

private struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(color)
                    .frame(width: fraction > 0 ? max(5, proxy.size.width * fraction) : 0)
            }
        }
        .frame(height: 5)
    }
}

struct IssueLine: View {
    let icon: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(LocalizedStringKey(text))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StaticPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    // Replaces AppKit-backed menus with their labels so ImageRenderer can draw them.
    var isStaticPreview: Bool {
        get { self[StaticPreviewKey.self] }
        set { self[StaticPreviewKey.self] = newValue }
    }
}
