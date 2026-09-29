import QuotaCore
import SwiftUI

struct StatusLabelItem: Identifiable, Equatable {
    let id: UUID
    let provider: Provider
    let percent: Int
    let level: UsageLevel
    let isStale: Bool

    static func items(accounts: [Account], entries: [UUID: UsageStore.Entry], displayMode: AppSettings.DisplayMode, now: Date) -> [StatusLabelItem] {
        accounts.compactMap { account in
            guard let entry = entries[account.id], let window = entry.snapshot?.tightestWindow(at: now) else { return nil }
            let remaining = window.remainingPercent(at: now)
            return StatusLabelItem(
                id: account.id,
                provider: account.provider,
                percent: displayMode.value(remaining: remaining),
                level: UsageLevel(remainingPercent: remaining),
                isStale: entry.issue != nil
            )
        }
    }
}

struct StatusLabelView: View {
    let items: [StatusLabelItem]

    var body: some View {
        HStack(spacing: 9) {
            if items.isEmpty {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 13, weight: .medium))
            }
            ForEach(items) { item in
                HStack(spacing: 3) {
                    ProviderGlyph(provider: item.provider)
                        .frame(width: 11, height: 11)
                    Text(verbatim: "\(item.percent)%")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(item.level.menuBarColor)
                .opacity(item.isStale ? 0.55 : 1)
            }
        }
        .padding(.horizontal, 7)
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
    }
}

extension UsageLevel {
    var menuBarColor: Color {
        switch self {
        case .normal: .primary
        case .warning: .orange
        case .critical: .red
        }
    }

    var barColor: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}
