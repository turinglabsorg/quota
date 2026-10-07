import Foundation
import Testing
@testable import QuotaCore
@testable import QuotaServer

private func temporaryStore() -> DeviceStore {
    DeviceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("quota-tests-\(UUID().uuidString)"))
}

private func request(_ method: String, _ path: String, headers: [String: String] = [:], body: String = "") -> HTTPRequest {
    HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
}

@Suite struct DeviceStoreTests {
    @Test func pairsWithASingleUseCode() throws {
        let store = temporaryStore()
        let pairing = try store.createPairingCode()
        #expect(pairing.code.count == 8 && pairing.code.allSatisfy(\.isNumber))
        let token = try store.redeem(code: pairing.code, deviceName: "iPhone")
        #expect(store.authorize(token: token)?.name == "iPhone")
        #expect(store.authorize(token: "not-a-token") == nil)
        #expect(throws: DeviceStore.PairingError.noPendingCode) { try store.redeem(code: pairing.code, deviceName: "Again") }
        let file = try String(contentsOf: store.directory.appendingPathComponent("devices.json"), encoding: .utf8)
        #expect(!file.contains(token) && !file.contains(pairing.code))
        let mode = try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent("devices.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func burnsTheCodeAfterFiveWrongAttempts() throws {
        let store = temporaryStore()
        let pairing = try store.createPairingCode()
        let wrong = pairing.code == "00000000" ? "11111111" : "00000000"
        for _ in 0..<DeviceStore.codeAttempts {
            #expect(throws: DeviceStore.PairingError.invalidCode) { try store.redeem(code: wrong, deviceName: "x") }
        }
        #expect(throws: DeviceStore.PairingError.noPendingCode) { try store.redeem(code: pairing.code, deviceName: "x") }
    }

    @Test func rejectsExpiredCodes() throws {
        let store = temporaryStore()
        let now = Date()
        let pairing = try store.createPairingCode(now: now)
        #expect(throws: DeviceStore.PairingError.expired) {
            try store.redeem(code: pairing.code, deviceName: "x", now: now.addingTimeInterval(DeviceStore.codeLifetime + 1))
        }
    }

    @Test func revokesDevices() throws {
        let store = temporaryStore()
        let token = try store.redeem(code: store.createPairingCode().code, deviceName: "iPad")
        let device = try #require(store.devices().first)
        #expect(try store.revoke(idPrefix: String(device.id.uuidString.prefix(8)))?.name == "iPad")
        #expect(store.authorize(token: token) == nil)
    }
}

@Suite struct HTTPParserTests {
    @Test func parsesRequestsOnceComplete() throws {
        let raw = "POST /v1/pair?x=1 HTTP/1.1\r\nHost: quota\r\nContent-Type: application/json\r\nContent-Length: 17\r\n\r\n{\"code\":\"123456\"}"
        let full = Data(raw.utf8)
        #expect(try HTTPParser.parse(full.prefix(30)) == nil)
        #expect(try HTTPParser.parse(full.dropLast(3)) == nil)
        let parsed = try #require(try HTTPParser.parse(full))
        #expect(parsed.method == "POST")
        #expect(parsed.path == "/v1/pair")
        #expect(parsed.headers["content-type"] == "application/json")
        #expect(String(decoding: parsed.body, as: UTF8.self) == "{\"code\":\"123456\"}")
    }

    @Test func rejectsMalformedAndOversizedRequests() {
        #expect(throws: HTTPParser.Failure.malformed) { try HTTPParser.parse(Data("GARBAGE\r\n\r\n".utf8)) }
        #expect(throws: HTTPParser.Failure.tooLarge) { try HTTPParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) }
        #expect(throws: HTTPParser.Failure.tooLarge) { try HTTPParser.parse(Data(String(repeating: "a", count: HTTPParser.maxHeadBytes + 1).utf8)) }
    }

    @Test func readsBearerTokens() {
        #expect(request("GET", "/", headers: ["authorization": "Bearer abc"]).bearerToken == "abc")
        #expect(request("GET", "/", headers: ["authorization": "Basic abc"]).bearerToken == nil)
        #expect(request("GET", "/").bearerToken == nil)
    }
}

@Suite struct RoutesTests {
    private let account = Account(provider: .claude, source: .cli, email: "me@example.com", plan: "Team")

    private func handler(store: DeviceStore) -> HTTPServer.Handler {
        let account = account
        let cache = UsageCache(loadAccounts: { [account] }, fetch: { _ in
            ProviderSnapshot(provider: .claude, plan: "Team", account: "me@example.com", windows: [
                UsageWindow(kind: .session, usedPercent: 30, resetsAt: Date(timeIntervalSince1970: 1_800_000_000)),
            ])
        })
        return Routes.handler(cache: cache, devices: store)
    }

    @Test func servesUsageOnlyToPairedDevices() async throws {
        let store = temporaryStore()
        let handle = handler(store: store)
        #expect(await handle(request("GET", "/health")).status == 200)
        #expect(await handle(request("GET", "/v1/usage")).status == 401)
        #expect(await handle(request("GET", "/v1/usage", headers: ["authorization": "Bearer nope"])).status == 401)
        #expect(await handle(request("GET", "/nope")).status == 404)

        let code = try store.createPairingCode().code
        #expect(await handle(request("POST", "/v1/pair", body: #"{"code":"00000000x"}"#)).status == 401)
        let paired = await handle(request("POST", "/v1/pair", body: "{\"code\":\"\(code)\",\"name\":\"My iPhone\"}"))
        #expect(paired.status == 200)
        let token = try #require((try JSONSerialization.jsonObject(with: paired.body) as? [String: String])?["token"])

        _ = await handle(request("GET", "/v1/usage", headers: ["authorization": "Bearer \(token)"]))
        try await Task.sleep(nanoseconds: 200_000_000)
        let usage = await handle(request("GET", "/v1/usage", headers: ["authorization": "Bearer \(token)"]))
        #expect(usage.status == 200)
        let payload = try UsagePayload.decode(usage.body)
        #expect(payload.version == 1)
        #expect(payload.accounts.map(\.email) == ["me@example.com"])
        #expect(payload.accounts.first?.usageWindows == [UsageWindow(kind: .session, usedPercent: 30, resetsAt: Date(timeIntervalSince1970: 1_800_000_000))])
        #expect(!String(decoding: usage.body, as: UTF8.self).contains(token))
    }
}
