import CryptoKit
import Foundation

// Uses /usr/bin/security, the same tool Claude Code uses, so items it created are readable without extra prompts.
enum Keychain {
    static let claudeService = "Claude Code-credentials"
    private static let security = URL(filePath: "/usr/bin/security")

    static var accountName: String {
        let user = NSUserName()
        return user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil ? user : "claude-code-user"
    }

    static func scopedClaudeService(configDirectory: URL) -> String {
        let digest = SHA256.hash(data: Data(configDirectory.path.precomposedStringWithCanonicalMapping.utf8))
        return "\(claudeService)-\(digest.prefix(4).map { String(format: "%02x", $0) }.joined())"
    }

    static func read(service: String) async -> Data? {
        let attempts = [
            ["find-generic-password", "-a", accountName, "-s", service, "-w"],
            ["find-generic-password", "-s", service, "-w"],
        ]
        for arguments in attempts {
            guard let result = try? await CommandRunner.run(security, arguments, timeout: 60), result.status == 0 else { continue }
            let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return decode(text) }
        }
        return nil
    }

    @discardableResult
    static func write(service: String, data: Data) async -> Bool {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let result = try? await CommandRunner.run(security, ["add-generic-password", "-U", "-a", accountName, "-s", service, "-X", hex], timeout: 60)
        return result?.status == 0
    }

    static func delete(service: String) async {
        _ = try? await CommandRunner.run(security, ["delete-generic-password", "-a", accountName, "-s", service], timeout: 60)
    }

    private static func decode(_ text: String) -> Data {
        let isHex = text.count.isMultiple(of: 2) && text.allSatisfy(\.isHexDigit)
        guard isHex else { return Data(text.utf8) }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return Data(text.utf8) }
            bytes.append(byte)
            index = next
        }
        return (try? JSONSerialization.jsonObject(with: bytes)) == nil ? Data(text.utf8) : bytes
    }
}
