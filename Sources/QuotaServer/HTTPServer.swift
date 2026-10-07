import Foundation
import Network

struct HTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    var bearerToken: String? {
        guard let value = headers["authorization"], value.lowercased().hasPrefix("bearer ") else { return nil }
        let token = value.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}

struct HTTPResponse {
    var status: Int
    var contentType = "application/json"
    var body: Data

    static func json(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: data)
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return HTTPResponse(status: status, body: body)
    }

    static func text(_ text: String) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    var serialized: Data {
        let head = [
            "HTTP/1.1 \(status) \(Self.reason(status))",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
        ].joined(separator: "\r\n")
        return Data((head + "\r\n\r\n").utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 410: "Gone"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        default: "Error"
        }
    }
}

enum HTTPParser {
    enum Failure: Error, Equatable {
        case malformed
        case tooLarge
    }

    static let maxHeadBytes = 16_384
    static let maxBodyBytes = 16_384

    /// The request once `buffer` holds its full head and body, nil while more bytes are needed.
    static func parse(_ buffer: Data) throws -> HTTPRequest? {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > maxHeadBytes { throw Failure.tooLarge }
            return nil
        }
        var lines = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw Failure.malformed }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformed }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { throw Failure.malformed }
        guard length <= maxBodyBytes else { throw Failure.tooLarge }
        let bodyStart = headEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return nil }

        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return HTTPRequest(method: String(requestLine[0]), path: path, headers: headers, body: buffer.subdata(in: bodyStart..<bodyStart + length))
    }
}

/// A small HTTP/1.1 server bound to the loopback interface: `grog serve` (or an SSH tunnel) exposes it.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let queue = DispatchQueue(label: "quota.http")

    init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw HTTPParser.Failure.malformed }
        listener = try NWListener(using: parameters, on: endpointPort)
        listener.newConnectionHandler = { [queue] connection in
            HTTPConnection(connection: connection, queue: queue, handler: handler).start()
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                FileHandle.standardError.write(Data("quota-server: listener failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    func start() {
        listener.start(queue: queue)
    }
}

private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private var buffer = Data()

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping HTTPServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 20) { [connection] in connection.cancel() }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            do {
                if let request = try HTTPParser.parse(buffer) {
                    Task { [self] in self.send(await self.handler(request)) }
                    return
                }
            } catch HTTPParser.Failure.tooLarge {
                send(.error(413, "Request too large"))
                return
            } catch {
                send(.error(400, "Bad request"))
                return
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                receive()
            }
        }
    }

    private func send(_ response: HTTPResponse) {
        connection.send(content: response.serialized, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }
}
