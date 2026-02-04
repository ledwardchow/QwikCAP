import Foundation

enum TrafficProtocol: String, Codable, CaseIterable {
    case http = "http"
    case https = "https"
    case websocket = "ws"
    case websocketSecure = "wss"

    var displayName: String {
        switch self {
        case .http: return "HTTP"
        case .https: return "HTTPS"
        case .websocket: return "WS"
        case .websocketSecure: return "WSS"
        }
    }

    var isSecure: Bool {
        self == .https || self == .websocketSecure
    }

    var defaultPort: Int {
        switch self {
        case .http, .websocket: return 80
        case .https, .websocketSecure: return 443
        }
    }
}

struct TrafficEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let `protocol`: TrafficProtocol
    let method: String
    let host: String
    let port: Int
    let path: String
    let requestHeaders: [String: String]
    let requestBody: String?
    let statusCode: Int?
    let responseHeaders: [String: String]
    let responseBody: String?
    let duration: Double?
    let connectionId: String
    let isWebSocketFrame: Bool
    let webSocketOpcode: WebSocketOpcode?
    let webSocketDirection: WebSocketDirection?
    let error: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        protocol: TrafficProtocol,
        method: String,
        host: String,
        port: Int,
        path: String,
        requestHeaders: [String: String] = [:],
        requestBody: String? = nil,
        statusCode: Int? = nil,
        responseHeaders: [String: String] = [:],
        responseBody: String? = nil,
        duration: Double? = nil,
        connectionId: String = UUID().uuidString,
        isWebSocketFrame: Bool = false,
        webSocketOpcode: WebSocketOpcode? = nil,
        webSocketDirection: WebSocketDirection? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.protocol = `protocol`
        self.method = method
        self.host = host
        self.port = port
        self.path = path
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.duration = duration
        self.connectionId = connectionId
        self.isWebSocketFrame = isWebSocketFrame
        self.webSocketOpcode = webSocketOpcode
        self.webSocketDirection = webSocketDirection
        self.error = error
    }

    var fullURL: String {
        var url = "\(`protocol`.rawValue)://\(host)"
        if port != `protocol`.defaultPort {
            url += ":\(port)"
        }
        url += path
        return url
    }

    var displayStatus: String {
        if let code = statusCode {
            return "\(code)"
        } else if isWebSocketFrame {
            return webSocketOpcode?.displayName ?? "WS"
        } else if error != nil {
            return "ERR"
        }
        return "-"
    }

    var statusColor: StatusColor {
        if let error = error, !error.isEmpty {
            return .error
        }
        guard let code = statusCode else {
            return .neutral
        }
        switch code {
        case 200..<300: return .success
        case 300..<400: return .redirect
        case 400..<500: return .clientError
        case 500..<600: return .serverError
        default: return .neutral
        }
    }

    enum StatusColor: String, Codable {
        case success
        case redirect
        case clientError
        case serverError
        case error
        case neutral
    }
}

enum WebSocketOpcode: Int, Codable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA

    var displayName: String {
        switch self {
        case .continuation: return "CONT"
        case .text: return "TEXT"
        case .binary: return "BIN"
        case .close: return "CLOSE"
        case .ping: return "PING"
        case .pong: return "PONG"
        }
    }
}

enum WebSocketDirection: String, Codable {
    case incoming = "incoming"
    case outgoing = "outgoing"

    var symbol: String {
        switch self {
        case .incoming: return "←"
        case .outgoing: return "→"
        }
    }
}

// MARK: - Traffic Entry Builder

class TrafficEntryBuilder {
    private var entry: TrafficEntry

    init(protocol: TrafficProtocol, method: String, host: String, port: Int, path: String) {
        entry = TrafficEntry(
            protocol: `protocol`,
            method: method,
            host: host,
            port: port,
            path: path
        )
    }

    func withRequestHeaders(_ headers: [String: String]) -> TrafficEntryBuilder {
        entry = TrafficEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            protocol: entry.protocol,
            method: entry.method,
            host: entry.host,
            port: entry.port,
            path: entry.path,
            requestHeaders: headers,
            requestBody: entry.requestBody,
            statusCode: entry.statusCode,
            responseHeaders: entry.responseHeaders,
            responseBody: entry.responseBody,
            duration: entry.duration,
            connectionId: entry.connectionId,
            isWebSocketFrame: entry.isWebSocketFrame,
            webSocketOpcode: entry.webSocketOpcode,
            webSocketDirection: entry.webSocketDirection,
            error: entry.error
        )
        return self
    }

    func withRequestBody(_ body: String?) -> TrafficEntryBuilder {
        entry = TrafficEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            protocol: entry.protocol,
            method: entry.method,
            host: entry.host,
            port: entry.port,
            path: entry.path,
            requestHeaders: entry.requestHeaders,
            requestBody: body,
            statusCode: entry.statusCode,
            responseHeaders: entry.responseHeaders,
            responseBody: entry.responseBody,
            duration: entry.duration,
            connectionId: entry.connectionId,
            isWebSocketFrame: entry.isWebSocketFrame,
            webSocketOpcode: entry.webSocketOpcode,
            webSocketDirection: entry.webSocketDirection,
            error: entry.error
        )
        return self
    }

    func withResponse(statusCode: Int, headers: [String: String], body: String?) -> TrafficEntryBuilder {
        entry = TrafficEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            protocol: entry.protocol,
            method: entry.method,
            host: entry.host,
            port: entry.port,
            path: entry.path,
            requestHeaders: entry.requestHeaders,
            requestBody: entry.requestBody,
            statusCode: statusCode,
            responseHeaders: headers,
            responseBody: body,
            duration: entry.duration,
            connectionId: entry.connectionId,
            isWebSocketFrame: entry.isWebSocketFrame,
            webSocketOpcode: entry.webSocketOpcode,
            webSocketDirection: entry.webSocketDirection,
            error: entry.error
        )
        return self
    }

    func withDuration(_ duration: Double) -> TrafficEntryBuilder {
        entry = TrafficEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            protocol: entry.protocol,
            method: entry.method,
            host: entry.host,
            port: entry.port,
            path: entry.path,
            requestHeaders: entry.requestHeaders,
            requestBody: entry.requestBody,
            statusCode: entry.statusCode,
            responseHeaders: entry.responseHeaders,
            responseBody: entry.responseBody,
            duration: duration,
            connectionId: entry.connectionId,
            isWebSocketFrame: entry.isWebSocketFrame,
            webSocketOpcode: entry.webSocketOpcode,
            webSocketDirection: entry.webSocketDirection,
            error: entry.error
        )
        return self
    }

    func withError(_ error: String) -> TrafficEntryBuilder {
        entry = TrafficEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            protocol: entry.protocol,
            method: entry.method,
            host: entry.host,
            port: entry.port,
            path: entry.path,
            requestHeaders: entry.requestHeaders,
            requestBody: entry.requestBody,
            statusCode: entry.statusCode,
            responseHeaders: entry.responseHeaders,
            responseBody: entry.responseBody,
            duration: entry.duration,
            connectionId: entry.connectionId,
            isWebSocketFrame: entry.isWebSocketFrame,
            webSocketOpcode: entry.webSocketOpcode,
            webSocketDirection: entry.webSocketDirection,
            error: error
        )
        return self
    }

    func build() -> TrafficEntry {
        return entry
    }
}
