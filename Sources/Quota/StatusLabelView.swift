import QuotaCore
import SwiftUI

struct StatusLabelItem: Identifiable, Equatable {
    struct Value: Equatable {
        let percent: Int
        let level: UsageLevel
    }

    let id: UUID
    let provider: Provider
    let values: [Value]
    let isStale: Bool

    /// The glyph takes the color of the tighter value.
    var level: UsageLevel {
        values.map(\.level).max { $0.severity < $1.severity } ?? .normal
    }

    static func items(accounts: [Account], entries: [UUID: UsageStore.Entry], displayMode: AppSettings.DisplayMode, now: Date) -> [StatusLabelItem] {
        accounts.compactMap { account in
            guard let entry = entries[account.id], let windows = entry.snapshot?.menuBarWindows(at: now), !windows.isEmpty else { return nil }
            return StatusLabelItem(
                id: account.id,
                provider: account.provider,
                values: windows.map { window in
                    let remaining = window.remainingPercent(at: now)
                    return Value(percent: displayMode.value(remaining: remaining), level: UsageLevel(remainingPercent: remaining))
                },
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
                        .foregroundStyle(item.level.menuBarColor)
                    if item.values.count > 1 {
                        // Session above, weekly below, drawn closer than their line boxes to leave room around them.
                        VStack(alignment: .leading, spacing: -2.5) {
                            ForEach(Array(item.values.enumerated()), id: \.offset) { _, value in
                                Text(verbatim: "\(value.percent)%")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(value.level.menuBarColor)
                            }
                        }
                    } else if let value = item.values.first {
                        Text(verbatim: "\(value.percent)%")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(value.level.menuBarColor)
                    }
                }
                .opacity(item.isStale ? 0.55 : 1)
            }
        }
        .padding(.horizontal, 7)
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
    }
}

extension UsageLevel {
    var severity: Int {
        switch self {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }

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
