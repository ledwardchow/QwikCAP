import Foundation

struct HTTPRequest {
    let method: String
    let url: String
    let version: String
    let headers: [String: String]
    let body: Data?

    var host: String? {
        // Try to get from headers first
        if let hostHeader = headers["Host"] ?? headers["host"] {
            return hostHeader.split(separator: ":").first.map(String.init)
        }

        // Try to parse from URL
        if url.hasPrefix("http://") || url.hasPrefix("https://") {
            if let urlObj = URL(string: url) {
                return urlObj.host
            }
        }

        return nil
    }

    var port: Int? {
        // Try to get from Host header
        if let hostHeader = headers["Host"] ?? headers["host"] {
            let parts = hostHeader.split(separator: ":")
            if parts.count > 1, let port = Int(parts[1]) {
                return port
            }
        }

        // Try to parse from URL
        if let urlObj = URL(string: url) {
            if let port = urlObj.port {
                return port
            }
        }

        // Default based on scheme
        if url.hasPrefix("https://") {
            return 443
        }

        return 80
    }
}

struct HTTPResponse {
    let version: String
    let statusCode: Int
    let statusMessage: String
    let headers: [String: String]
    let body: Data?

    var contentLength: Int? {
        if let lengthStr = headers["Content-Length"] ?? headers["content-length"] {
            return Int(lengthStr)
        }
        return nil
    }

    var isChunked: Bool {
        let encoding = headers["Transfer-Encoding"] ?? headers["transfer-encoding"] ?? ""
        return encoding.lowercased().contains("chunked")
    }
}

class HTTPParser {
    // MARK: - Request Parsing

    func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = string.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        // Parse request line
        let requestLine = lines[0].split(separator: " ", maxSplits: 2)
        guard requestLine.count >= 2 else { return nil }

        let method = String(requestLine[0])
        let url = String(requestLine[1])
        let version = requestLine.count > 2 ? String(requestLine[2]) : "HTTP/1.1"

        // Parse headers
        var headers: [String: String] = [:]
        var headerEndIndex = 1

        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty {
                headerEndIndex = i
                break
            }

            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Parse body
        var body: Data? = nil
        if headerEndIndex + 1 < lines.count {
            let bodyLines = lines[(headerEndIndex + 1)...].joined(separator: "\r\n")
            body = bodyLines.data(using: .utf8)
        }

        // Alternative: find body by \r\n\r\n
        if body == nil || body?.isEmpty == true {
            if let range = data.range(of: Data("\r\n\r\n".utf8)) {
                let bodyStart = range.upperBound
                if bodyStart < data.count {
                    body = data[bodyStart...]
                }
            }
        }

        return HTTPRequest(method: method, url: url, version: version, headers: headers, body: body)
    }

    // MARK: - Response Parsing

    func parseResponse(_ data: Data) -> HTTPResponse? {
        guard let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = string.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        // Parse status line
        let statusLine = lines[0].split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2 else { return nil }

        let version = String(statusLine[0])
        guard let statusCode = Int(statusLine[1]) else { return nil }
        let statusMessage = statusLine.count > 2 ? String(statusLine[2]) : ""

        // Parse headers
        var headers: [String: String] = [:]
        var headerEndIndex = 1

        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty {
                headerEndIndex = i
                break
            }

            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Parse body
        var body: Data? = nil
        if let range = data.range(of: Data("\r\n\r\n".utf8)) {
            let bodyStart = range.upperBound
            if bodyStart < data.count {
                body = data[bodyStart...]
            }
        }

        return HTTPResponse(version: version, statusCode: statusCode, statusMessage: statusMessage, headers: headers, body: body)
    }

    // MARK: - Request Building

    func rebuildRequest(_ request: HTTPRequest, forDirectConnection: Bool) -> Data {
        var lines: [String] = []

        // Build request line
        var path = request.url
        if forDirectConnection && (path.hasPrefix("http://") || path.hasPrefix("https://")) {
            // Convert absolute URL to relative path
            if let url = URL(string: path) {
                path = url.path
                if path.isEmpty { path = "/" }
                if let query = url.query {
                    path += "?\(query)"
                }
            }
        }

        lines.append("\(request.method) \(path) \(request.version)")

        // Add headers
        for (key, value) in request.headers {
            lines.append("\(key): \(value)")
        }

        lines.append("")  // Empty line before body

        var result = lines.joined(separator: "\r\n")
        result += "\r\n"

        var data = result.data(using: .utf8) ?? Data()

        // Add body if present
        if let body = request.body {
            data.append(body)
        }

        return data
    }

    func buildRequest(method: String, url: String, headers: [String: String], body: Data?) -> Data {
        var lines: [String] = []

        lines.append("\(method) \(url) HTTP/1.1")

        for (key, value) in headers {
            lines.append("\(key): \(value)")
        }

        lines.append("")

        var result = lines.joined(separator: "\r\n")
        result += "\r\n"

        var data = result.data(using: .utf8) ?? Data()

        if let body = body {
            data.append(body)
        }

        return data
    }

    // MARK: - Response Building

    func buildResponse(statusCode: Int, statusMessage: String, headers: [String: String], body: Data?) -> Data {
        var lines: [String] = []

        lines.append("HTTP/1.1 \(statusCode) \(statusMessage)")

        for (key, value) in headers {
            lines.append("\(key): \(value)")
        }

        lines.append("")

        var result = lines.joined(separator: "\r\n")
        result += "\r\n"

        var data = result.data(using: .utf8) ?? Data()

        if let body = body {
            data.append(body)
        }

        return data
    }
}
