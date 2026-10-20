import Foundation

public enum Formatting {
    public static var locale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    public static func countdown(to date: Date, from now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return String(localized: "now") }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            return hours > 0 ? String(localized: "\(days)d \(hours)h") : String(localized: "\(days)d")
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(minutes, 1))m"
    }

    public static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM HH:mm")
        return formatter.string(from: date)
    }

    public static func relative(_ date: Date, from now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return String(localized: "now")
        case ..<3_600: return String(localized: "\(seconds / 60) min ago")
        case ..<86_400: return String(localized: "\(seconds / 3_600) h ago")
        default:
            let days = seconds / 86_400
            let hours = (seconds % 86_400) / 3_600
            return hours > 0 ? String(localized: "\(days)d \(hours)h ago") : String(localized: "\(days)d ago")
        }
    }

    /// Compact token counts: 950, 45.2k, 1.25M, 2.5B.
    public static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 { return trimmed(Double(count) / 1_000_000_000, decimals: 2) + "B" }
        if count >= 1_000_000 { return trimmed(Double(count) / 1_000_000, decimals: 2) + "M" }
        if count >= 1_000 { return trimmed(Double(count) / 1_000, decimals: 1) + "k" }
        return String(count)
    }

    private static func trimmed(_ value: Double, decimals: Int) -> String {
        let text = String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
        if text.contains(".") {
            return text.replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        }
        return text
    }

    public static func duration(minutes: Int) -> String {
        if minutes % 1_440 == 0 { return String(localized: "\(minutes / 1_440) d") }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes) min"
    }

    static func capitalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        return first.uppercased() + trimmed.dropFirst()
    }
}
