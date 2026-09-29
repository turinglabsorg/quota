import AppKit

let arguments = CommandLine.arguments
signal(SIGPIPE, SIG_IGN)

if arguments.contains("--print") {
    Task.detached {
        await CLIReport.run()
        exit(0)
    }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if let index = arguments.firstIndex(of: "--render-preview"), arguments.indices.contains(index + 1) {
        PreviewRenderer.render(to: URL(filePath: arguments[index + 1]))
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
