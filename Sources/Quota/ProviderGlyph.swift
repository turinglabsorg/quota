import QuotaCore
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
        case .codex, .grok: .primary
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
