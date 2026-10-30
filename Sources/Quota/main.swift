import AppKit
import QuotaCore

let arguments = CommandLine.arguments
signal(SIGPIPE, SIG_IGN)

if arguments.contains("--print-activity") {
    Task.detached {
        let history = TokenHistory.load(accounts: AccountStorage.load())
        print("Local token activity, last 12 weeks")
        for provider in history.availableProviders {
            let total = history.days.reduce(TokenAmounts()) { $0 + $1.amounts(provider: provider) }
            print("\(provider.displayName): \(total.total) tokens (input \(total.input), output \(total.output), cached \(total.cached))")
        }
        print("Total: \(history.total.total) tokens; \(history.unreadableFiles) unreadable files")
        exit(0)
    }
    dispatchMain()
}

if let index = arguments.firstIndex(of: "--pair"), arguments.indices.contains(index + 2) {
    Task.detached {
        exit(await CLIReport.pair(address: arguments[index + 1], code: arguments[index + 2]))
    }
    dispatchMain()
}

if arguments.contains("--unpair") {
    Task.detached {
        await ServerConnection.unpair()
        print("This Mac reads its own accounts again.")
        exit(0)
    }
    dispatchMain()
}

if arguments.contains("--print") {
    Task.detached {
        await CLIReport.run()
        exit(0)
    }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if let index = arguments.firstIndex(of: "--render-activity"), arguments.indices.contains(index + 1) {
        PreviewRenderer.renderActivity(history: TokenHistory.load(accounts: AccountStorage.load()), to: URL(fileURLWithPath: arguments[index + 1]))
        exit(0)
    }
    if let index = arguments.firstIndex(of: "--render-preview"), arguments.indices.contains(index + 1) {
        PreviewRenderer.render(to: URL(filePath: arguments[index + 1]))
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
