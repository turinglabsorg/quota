import CryptoKit
import Foundation

/// Paired devices and the pending pairing code. Tokens and codes are stored only as SHA-256 hashes,
/// in a mode-600 file guarded by an exclusive lock so the server and the CLI commands can share it.
struct DeviceStore {
    struct Device: Codable, Equatable {
        var id: UUID
        var name: String
        var tokenHash: String
        var createdAt: Date
        var lastSeenAt: Date?
    }

    struct Pairing: Codable, Equatable {
        var codeHash: String
        var expiresAt: Date
        var attemptsLeft: Int
    }

    struct State: Codable, Equatable {
        var devices: [Device] = []
        var pairing: Pairing?
    }

    enum PairingError: Error, Equatable {
        case noPendingCode
        case expired
        case invalidCode
    }

    static let codeLifetime: TimeInterval = 10 * 60
    static let codeAttempts = 5

    let directory: URL

    static var standard: DeviceStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DeviceStore(directory: support.appendingPathComponent("Quota/Server"))
    }

    private var stateFile: URL { directory.appendingPathComponent("devices.json") }
    private var lockFile: URL { directory.appendingPathComponent("devices.lock") }

    /// A new 8-digit, single-use pairing code. It replaces any pending code.
    func createPairingCode(now: Date = Date()) throws -> (code: String, expiresAt: Date) {
        let code = String(format: "%08u", UInt32.random(in: 0..<100_000_000))
        let expiresAt = now.addingTimeInterval(Self.codeLifetime)
        try withState { state in
            state.pairing = Pairing(codeHash: Self.hash(code), expiresAt: expiresAt, attemptsLeft: Self.codeAttempts)
        }
        return (code, expiresAt)
    }

    /// Trades a valid pairing code for a new device token. Wrong codes burn attempts.
    func redeem(code: String, deviceName: String, now: Date = Date()) throws -> String {
        try withState { state in
            guard var pairing = state.pairing else { throw PairingError.noPendingCode }
            guard pairing.expiresAt > now else {
                state.pairing = nil
                throw PairingError.expired
            }
            guard Self.hash(code.trimmingCharacters(in: .whitespaces)) == pairing.codeHash else {
                pairing.attemptsLeft -= 1
                state.pairing = pairing.attemptsLeft > 0 ? pairing : nil
                throw PairingError.invalidCode
            }
            state.pairing = nil
            let token = Self.newToken()
            let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            state.devices.append(Device(id: UUID(), name: name.isEmpty ? "Device" : String(name.prefix(64)), tokenHash: Self.hash(token), createdAt: now, lastSeenAt: now))
            return token
        }
    }

    /// The device that owns `token`, recording when it was last seen.
    func authorize(token: String, now: Date = Date()) -> Device? {
        let tokenHash = Self.hash(token)
        return try? withState { state in
            guard let index = state.devices.firstIndex(where: { $0.tokenHash == tokenHash }) else { return nil }
            if state.devices[index].lastSeenAt.map({ now.timeIntervalSince($0) > 60 }) ?? true {
                state.devices[index].lastSeenAt = now
            }
            return state.devices[index]
        }
    }

    func devices() -> [Device] {
        (try? withState { $0.devices }) ?? []
    }

    func revoke(idPrefix: String) throws -> Device? {
        try withState { state in
            let matches = state.devices.filter { $0.id.uuidString.lowercased().hasPrefix(idPrefix.lowercased()) }
            guard matches.count == 1, let device = matches.first else { return nil }
            state.devices.removeAll { $0.id == device.id }
            return device
        }
    }

    private func withState<T>(_ body: (inout State) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(descriptor) }
        flock(descriptor, LOCK_EX)
        defer { flock(descriptor, LOCK_UN) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var state = (try? Data(contentsOf: stateFile)).flatMap { try? decoder.decode(State.self, from: $0) } ?? State()
        let original = state
        // Failed attempts still change the state (a burned or expired code), so save before rethrowing.
        let outcome = Result { try body(&state) }
        if state != original {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: stateFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
        }
        return try outcome.get()
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
