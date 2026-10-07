import Foundation
import QuotaCore

enum Routes {
    static func handler(cache: UsageCache, devices: DeviceStore) -> HTTPServer.Handler {
        { request in
            switch (request.method, request.path) {
            case ("GET", "/health"):
                return .text("ok")
            case ("POST", "/v1/pair"):
                return pair(request, devices: devices)
            case ("GET", "/v1/usage"):
                guard let token = request.bearerToken, devices.authorize(token: token) != nil else {
                    return .error(401, "Unauthorized")
                }
                if await cache.isStale {
                    Task { await cache.refresh() }
                }
                guard let data = try? UsagePayload.encode(await cache.payload()) else {
                    return .error(500, "Could not encode usage")
                }
                return .json(data)
            default:
                return .error(404, "Not found")
            }
        }
    }

    private struct PairRequest: Decodable {
        var code: String
        var name: String?
    }

    private static func pair(_ request: HTTPRequest, devices: DeviceStore) -> HTTPResponse {
        guard let body = try? JSONDecoder().decode(PairRequest.self, from: request.body) else {
            return .error(400, "Expected {\"code\": \"…\", \"name\": \"…\"}")
        }
        do {
            let token = try devices.redeem(code: body.code, deviceName: body.name ?? "iPhone")
            let data = (try? JSONSerialization.data(withJSONObject: ["token": token])) ?? Data()
            return .json(data)
        } catch DeviceStore.PairingError.expired {
            return .error(410, "Pairing code expired")
        } catch {
            return .error(401, "Invalid pairing code")
        }
    }
}
