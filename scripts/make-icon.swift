import AppKit
import SwiftUI

struct Ring: View {
    let diameter: CGFloat
    let fraction: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 64)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 64, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

struct Icon: View {
    // iOS masks the icon itself, so its artwork fills the square edge to edge.
    let fullBleed: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: fullBleed ? 0 : 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.16, green: 0.155, blue: 0.15), Color(red: 0.07, green: 0.068, blue: 0.065)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: fullBleed ? 1024 : 824, height: fullBleed ? 1024 : 824)
            Ring(diameter: 600, fraction: 0.72, color: Color(red: 0.851, green: 0.467, blue: 0.341))
            Ring(diameter: 440, fraction: 0.88, color: Color(red: 0.93, green: 0.92, blue: 0.9))
            Ring(diameter: 280, fraction: 0.4, color: Color(red: 0.6, green: 0.59, blue: 0.57))
        }
        .frame(width: 1024, height: 1024)
    }
}

let output = URL(filePath: CommandLine.arguments[1])
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon(fullBleed: CommandLine.arguments.contains("--ios")))
    renderer.scale = 1
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { fatalError("Icon render failed") }
    try! png.write(to: output)
}
