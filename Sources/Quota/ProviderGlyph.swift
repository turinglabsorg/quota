#if canImport(QuotaCore)
import QuotaCore
#endif
import SwiftUI

struct ProviderGlyph: View {
    let provider: Provider

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let style = StrokeStyle(lineWidth: max(1.3, size * 0.15), lineCap: .round, lineJoin: .round)
            Group {
                switch provider {
                case .claude: ClaudeBurst().stroke(style: style)
                case .codex: CodexPrompt().stroke(style: style)
                case .grok: GrokMark().stroke(style: style)
                case .ollama: OllamaHead().stroke(style: style)
                }
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(provider.displayName)
    }
}

extension Provider {
    var accent: Color {
        switch self {
        case .claude: Color(red: 0.851, green: 0.467, blue: 0.341)
        case .codex, .grok, .ollama: .primary
        }
    }
}

private struct ClaudeBurst: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 * 0.92
        var path = Path()
        for index in 0..<10 {
            let angle = Double(index) * .pi / 5 - .pi / 2
            let outer = radius * (index.isMultiple(of: 2) ? 1 : 0.78)
            let inner = radius * 0.2
            path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        }
        return path
    }
}

private struct CodexPrompt: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: point(0.1, 0.2))
        path.addLine(to: point(0.46, 0.5))
        path.addLine(to: point(0.1, 0.8))
        path.move(to: point(0.58, 0.82))
        path.addLine(to: point(0.92, 0.82))
        return path
    }
}

private struct GrokMark: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let size = min(rect.width, rect.height)
        let radius = size * 0.34
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .degrees(-10), endAngle: .degrees(-80), clockwise: false)
        path.move(to: CGPoint(x: center.x - size * 0.44, y: center.y + size * 0.44))
        path.addLine(to: CGPoint(x: center.x + size * 0.44, y: center.y - size * 0.44))
        return path
    }
}

private struct OllamaHead: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: point(0.37, 0.4))
        path.addLine(to: point(0.29, 0.08))
        path.move(to: point(0.63, 0.4))
        path.addLine(to: point(0.71, 0.08))
        path.addRoundedRect(
            in: CGRect(origin: point(0.16, 0.4), size: CGSize(width: rect.width * 0.68, height: rect.height * 0.54)),
            cornerSize: CGSize(width: rect.width * 0.2, height: rect.height * 0.2)
        )
        // Very short strokes with round caps read as the eyes.
        for x in [0.39, 0.61] {
            path.move(to: point(x, 0.635))
            path.addLine(to: point(x, 0.645))
        }
        return path
    }
}
