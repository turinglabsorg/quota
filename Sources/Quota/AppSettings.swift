import Foundation
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    enum DisplayMode: String, CaseIterable, Identifiable {
        case remaining
        case used

        var id: String { rawValue }

        var title: String {
            switch self {
            case .remaining: String(localized: "Percentage left")
            case .used: String(localized: "Percentage used")
            }
        }

        var suffix: String {
            switch self {
            case .remaining: String(localized: "left")
            case .used: String(localized: "used")
            }
        }

        func value(remaining: Int) -> Int {
            self == .remaining ? remaining : 100 - remaining
        }
    }

    @Published var displayMode: DisplayMode {
        didSet { Storage.defaults.set(displayMode.rawValue, forKey: Keys.displayMode) }
    }
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var loginItemError: String?

    init() {
        displayMode = DisplayMode(rawValue: Storage.defaults.string(forKey: Keys.displayMode) ?? "") ?? .remaining
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = String(localized: "Couldn't update launch at login: move Quota to the Applications folder and try again.")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private enum Keys {
        static let displayMode = "displayMode"
    }
}
