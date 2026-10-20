import Combine
import QuotaCore
import SwiftUI

@MainActor
final class TokenActivityStore: ObservableObject {
    @Published var history = TokenHistory()
    @Published var isLoading = false
    @Published var provider: Provider?
    @Published var selectedDay: Date?
    private var loadedAt: Date?
    private var loadedAccounts: [Account] = []

    func load(accounts: [Account]) {
        guard !isLoading else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 300, loadedAccounts == accounts { return }
        isLoading = true
        Task {
            let result = await Task.detached(priority: .utility) { TokenHistory.load(accounts: accounts) }.value
            history = result
            if let provider, !result.availableProviders.contains(provider) { self.provider = nil }
            selectedDay = Calendar.current.startOfDay(for: Date())
            loadedAt = Date()
            loadedAccounts = accounts
            isLoading = false
        }
    }
}

struct TokenActivityView: View {
    @ObservedObject var store: TokenActivityStore
    let onBack: () -> Void
    @Environment(\.isStaticPreview) private var isStaticPreview

    private var days: [TokenActivityDay] { store.history.days }
    private var total: TokenAmounts { days.reduce(TokenAmounts()) { $0 + $1.amounts(provider: store.provider) } }
    private var activeAmounts: [Int] { days.map { $0.amounts(provider: store.provider).total }.filter { $0 > 0 }.sorted() }
    private var selected: TokenActivityDay? { days.first { $0.date == store.selectedDay } }
    private var color: Color { store.provider == .claude ? .orange : .green }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button(action: onBack) { Image(systemName: "chevron.left").frame(width: 16, height: 22) }
                    .buttonStyle(.plain)
                    .help("Back")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Token activity").font(.system(size: 13, weight: .semibold))
                    Text("Last 12 weeks · this Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Formatting.formatTokens(total.total)).font(.system(size: 27, weight: .semibold)).monospacedDigit()
                    Text("tokens processed").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if isStaticPreview {
                    filterLabel
                } else {
                    Menu {
                        Button("All providers") { store.provider = nil }
                        Divider()
                        ForEach(store.history.availableProviders) { provider in
                            Button(provider.displayName) { store.provider = provider }
                        }
                    } label: { filterLabel }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            if store.isLoading, days.isEmpty {
                Text("Reading local token history…").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 40)
            } else if store.history.availableProviders.isEmpty {
                Text("No token history found in the local session logs.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 24)
            } else {
                heatmap
                HStack(spacing: 4) {
                    Text("Less")
                    ForEach(0..<5) { index in RoundedRectangle(cornerRadius: 2).fill(shade(level: index)).frame(width: 9, height: 9) }
                    Text("More")
                    Spacer()
                    Text("Select a day")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                Divider()
                details
            }
            Text("Local CLI sessions only. Totals include cached input; reasoning is included in output. Web and other-device usage is not included.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Ollama Cloud is not included in token history.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.history.unreadableFiles > 0 {
                Text("Some session files could not be read.").font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var filterLabel: some View {
        HStack(spacing: 4) {
            Text(store.provider?.displayName ?? String(localized: "All providers")).font(.system(size: 11))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
    }

    private var heatmap: some View {
        HStack(alignment: .top, spacing: 5) {
            VStack(spacing: 4) {
                Text(verbatim: " ").frame(height: 12)
                ForEach(0..<7) { day in
                    Text(verbatim: day.isMultiple(of: 2) ? weekday(day) : " ")
                        .font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 23, height: 17, alignment: .leading)
                }
            }
            ForEach(0..<12) { week in
                VStack(spacing: 4) {
                    Text(verbatim: monthLabel(week)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7).frame(width: 17, height: 12)
                    ForEach(0..<7) { day in
                        let offset = week * 7 + day
                        if days.indices.contains(offset) {
                            let item = days[offset]
                            let future = item.date > Date()
                            Button { store.selectedDay = item.date } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(shade(level: level(item.amounts(provider: store.provider).total)))
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(store.selectedDay == item.date ? Color.primary : Color.clear, lineWidth: 1.5))
                                    .frame(width: 17, height: 17)
                                    .opacity(future ? 0.2 : 1)
                            }
                            .buttonStyle(.plain)
                            .disabled(future)
                            .help("\(item.date.formatted(date: .abbreviated, time: .omitted)): \(Formatting.formatTokens(item.amounts(provider: store.provider).total)) \(String(localized: "tokens"))")
                            .accessibilityLabel("\(item.date.formatted(date: .abbreviated, time: .omitted)), \(item.amounts(provider: store.provider).total) \(String(localized: "tokens"))")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var details: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(verbatim: selected.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(verbatim: "\(Formatting.formatTokens(selected.amounts(provider: store.provider).total)) \(String(localized: "tokens"))")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
                ForEach(store.history.availableProviders.filter { store.provider == nil || store.provider == $0 }) { provider in
                    let amounts = selected.providers[provider] ?? TokenAmounts()
                    HStack {
                        ProviderGlyph(provider: provider).frame(width: 11, height: 11)
                        Text(provider.displayName)
                        Spacer()
                        Text(verbatim: Formatting.formatTokens(amounts.total)).monospacedDigit()
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                let amounts = selected.amounts(provider: store.provider)
                Text(String(localized: "Input \(Formatting.formatTokens(amounts.input)) · output \(Formatting.formatTokens(amounts.output)) · cached \(Formatting.formatTokens(amounts.cached))"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func level(_ tokens: Int) -> Int {
        let active = activeAmounts
        guard tokens > 0, !active.isEmpty else { return 0 }
        let rank = active.lastIndex(of: tokens) ?? 0
        return min(4, 1 + rank * 4 / active.count)
    }

    private func shade(level: Int) -> Color {
        level == 0 ? Color.primary.opacity(0.06) : color.opacity([0, 0.25, 0.45, 0.7, 1][level])
    }

    private func weekday(_ day: Int) -> String {
        let formatter = DateFormatter()
        return formatter.veryShortStandaloneWeekdaySymbols[(day + 1) % 7]
    }

    private func monthLabel(_ week: Int) -> String {
        let offset = week * 7
        guard days.indices.contains(offset) else { return "" }
        let calendar = Calendar.current
        let date = days[offset].date
        if week > 0, calendar.component(.month, from: date) == calendar.component(.month, from: days[offset - 7].date) { return "" }
        return date.formatted(.dateTime.month(.abbreviated))
    }
}
