import Foundation

struct ParsedHTTPRequest {
    let method: String
    let uri: String
    let httpVersion: String
    let headers: [String: String]
    let body: Data?

    var host: String {
        if let hostHeader = headers["Host"] {
            return hostHeader.split(separator: ":").first.map(String.init) ?? hostHeader
        }
        if let url = URL(string: uri) {
            return url.host ?? ""
        }
        return ""
    }

    var port: Int {
        if let hostHeader = headers["Host"],
           let portPart = hostHeader.split(separator: ":").last,
           let port = Int(portPart) {
            return port
        }
        if let url = URL(string: uri) {
            return url.port ?? (uri.hasPrefix("https") ? 443 : 80)
        }
        return 80
    }

    var path: String {
        if let url = URL(string: uri) {
            var path = url.path
            if path.isEmpty { path = "/" }
            if let query = url.query {
                path += "?\(query)"
            }
            return path
        }
        return uri
    }

    var isConnectMethod: Bool {
        method.uppercased() == "CONNECT"
    }

    var isWebSocketUpgrade: Bool {
        headers["Upgrade"]?.lowercased() == "websocket" ||
        headers["upgrade"]?.lowercased() == "websocket"
    }
}

struct ParsedHTTPResponse {
    let httpVersion: String
    let statusCode: Int
    let statusMessage: String
    let headers: [String: String]
    let body: Data?

    var contentLength: Int? {
        if let value = headers["Content-Length"] ?? headers["content-length"] {
            return Int(value)
        }
        return nil
    }

    var isChunkedEncoding: Bool {
        let encoding = headers["Transfer-Encoding"] ?? headers["transfer-encoding"] ?? ""
        return encoding.lowercased().contains("chunked")
    }

    var contentType: String? {
        headers["Content-Type"] ?? headers["content-type"]
    }

    var isWebSocketAccept: Bool {
        statusCode == 101 &&
        (headers["Upgrade"]?.lowercased() == "websocket" ||
         headers["upgrade"]?.lowercased() == "websocket")
    }
}

class HTTPParser {

    // MARK: - Request Parsing

    static func parseRequest(_ data: Data) -> ParsedHTTPRequest? {
        guard let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return nil
        }

        // Split headers and body
        let parts = string.components(separatedBy: "\r\n\r\n")
        guard !parts.isEmpty else { return nil }

        let headerSection = parts[0]
        let lines = headerSection.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        // Parse request line
        let requestLine = lines[0]
        let requestParts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }

        let method = String(requestParts[0])
        let uri = String(requestParts[1])
        let httpVersion = requestParts.count > 2 ? String(requestParts[2]) : "HTTP/1.1"

        // Parse headers
        var headers: [String: String] = [:]
        for i in 1..<lines.count {
            let line = lines[i]
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Extract body
        var body: Data? = nil
        if parts.count > 1 {
            let bodyString = parts[1...].joined(separator: "\r\n\r\n")
            if !bodyString.isEmpty {
                body = bodyString.data(using: .utf8)
            }
        }

        return ParsedHTTPRequest(
            method: method,
            uri: uri,
            httpVersion: httpVersion,
            headers: headers,
            body: body
        )
    }

    // MARK: - Response Parsing

    static func parseResponse(_ data: Data) -> ParsedHTTPResponse? {
        guard let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return nil
        }

        // Split headers and body
        let parts = string.components(separatedBy: "\r\n\r\n")
        guard !parts.isEmpty else { return nil }

        let headerSection = parts[0]
        let lines = headerSection.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        // Parse status line
        let statusLine = lines[0]
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2 else { return nil }

        let httpVersion = String(statusParts[0])
        guard let statusCode = Int(statusParts[1]) else { return nil }
        let statusMessage = statusParts.count > 2 ? String(statusParts[2]) : ""

        // Parse headers
        var headers: [String: String] = [:]
        for i in 1..<lines.count {
            let line = lines[i]
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Extract body
        var body: Data? = nil
        if parts.count > 1 {
            let bodyString = parts[1...].joined(separator: "\r\n\r\n")
            if !bodyString.isEmpty {
                body = bodyString.data(using: .utf8)
            }
        }

        return ParsedHTTPResponse(
            httpVersion: httpVersion,
            statusCode: statusCode,
            statusMessage: statusMessage,
            headers: headers,
            body: body
        )
    }

    // MARK: - Utilities

    static func buildRequest(
        method: String,
        path: String,
        host: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) -> Data {
        var request = "\(method) \(path) HTTP/1.1\r\n"
        request += "Host: \(host)\r\n"

        for (key, value) in headers {
            if key.lowercased() != "host" {
                request += "\(key): \(value)\r\n"
            }
        }

        if let body = body {
            request += "Content-Length: \(body.count)\r\n"
        }

        request += "\r\n"

        var data = request.data(using: .utf8) ?? Data()
        if let body = body {
            data.append(body)
        }

        return data
    }

    static func buildResponse(
        statusCode: Int,
        statusMessage: String? = nil,
        headers: [String: String] = [:],
        body: Data? = nil
    ) -> Data {
        let message = statusMessage ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
        var response = "HTTP/1.1 \(statusCode) \(message)\r\n"

        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }

        if let body = body {
            response += "Content-Length: \(body.count)\r\n"
        }

        response += "\r\n"

        var data = response.data(using: .utf8) ?? Data()
        if let body = body {
            data.append(body)
        }

        return data
    }

    // MARK: - Header Extraction

    static func extractHeadersEndIndex(_ data: Data) -> Int? {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let range = data.range(of: separator) else { return nil }
        return range.upperBound
    }

    static func extractContentLength(_ data: Data) -> Int? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        let lines = string.components(separatedBy: "\r\n")

        for line in lines {
            let lowercased = line.lowercased()
            if lowercased.hasPrefix("content-length:") {
                let value = String(line.dropFirst("content-length:".count)).trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }

        return nil
    }

    static func isChunkedEncoding(_ data: Data) -> Bool {
        guard let string = String(data: data, encoding: .utf8) else { return false }
        let lowercased = string.lowercased()
        return lowercased.contains("transfer-encoding:") && lowercased.contains("chunked")
    }
}
