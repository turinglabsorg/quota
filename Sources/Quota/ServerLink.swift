import AppKit
import QuotaCore

/// Whether this Mac reads usage from a `quota-server` instead of the providers, plus the pairing form.
@MainActor
final class ServerLink: ObservableObject {
    @Published private(set) var serverURL: URL?
    @Published private(set) var isPairing = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var address: String
    @Published var code = "" {
        didSet {
            let digits = String(code.filter(\.isNumber).prefix(8))
            if digits != code { code = digits }
        }
    }

    init(serverURL: URL? = ServerConnection.serverURL) {
        self.serverURL = serverURL
        address = serverURL?.absoluteString ?? ""
    }

    var isConnected: Bool { serverURL != nil }
    var host: String? { serverURL?.host }
    var canPair: Bool { !isPairing && code.count == 8 && !address.isEmpty }

    func pair() {
        guard canPair else { return }
        guard let url = ServerConnection.address(from: address) else {
            error = ServerConnection.Failure.invalidAddress.message
            return
        }
        isPairing = true
        error = nil
        let code = code
        Task {
            defer { isPairing = false }
            do {
                try await ServerConnection.pair(server: url, code: code, deviceName: Host.current().localizedName ?? "Mac")
                self.code = ""
                address = url.absoluteString
                notice = nil
                serverURL = url
            } catch let failure as ServerConnection.Failure {
                error = failure.message
            } catch {
                self.error = ServerConnection.Failure.network.message
            }
        }
    }

    func disconnect() {
        serverURL = nil
        error = nil
        Task { await ServerConnection.unpair() }
    }

    /// The server answered 401: this Mac was revoked, so it goes back to its own accounts.
    func revoked() {
        disconnect()
        notice = ServerConnection.Failure.unauthorized.message
    }
}
