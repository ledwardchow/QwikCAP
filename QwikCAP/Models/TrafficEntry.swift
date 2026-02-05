import Foundation

struct TrafficEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let method: String
    let url: String
    let host: String
    let path: String
    let scheme: String
    var statusCode: Int?
    let requestHeaders: [String: String]
    let requestBody: Data?
    var responseHeaders: [String: String]?
    var responseBody: Data?
    var duration: TimeInterval?
    var error: String?
    let connectionId: UUID

    // MARK: - Computed Properties

    var isComplete: Bool { statusCode != nil || error != nil }
    var isError: Bool { error != nil || (statusCode ?? 0) >= 400 }
    var contentType: String? { responseHeaders?["Content-Type"] ?? responseHeaders?["content-type"] }
    var requestSize: Int { requestBody?.count ?? 0 }
    var responseSize: Int { responseBody?.count ?? 0 }

    var methodColor: String {
        switch method.uppercased() {
        case "GET": return "blue"
        case "POST": return "green"
        case "PUT": return "orange"
        case "DELETE": return "red"
        case "PATCH": return "purple"
        default: return "gray"
        }
    }

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        method: String,
        url: String,
        host: String,
        path: String,
        scheme: String,
        statusCode: Int? = nil,
        requestHeaders: [String: String],
        requestBody: Data? = nil,
        responseHeaders: [String: String]? = nil,
        responseBody: Data? = nil,
        duration: TimeInterval? = nil,
        error: String? = nil,
        connectionId: UUID = UUID()
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.url = url
        self.host = host
        self.path = path
        self.scheme = scheme
        self.statusCode = statusCode
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.duration = duration
        self.error = error
        self.connectionId = connectionId
    }
}

// MARK: - Traffic Filter

enum TrafficFilter: String, CaseIterable {
    case all = "All"
    case api = "API"
    case images = "Images"
    case documents = "Docs"
    case errors = "Errors"

    func matches(_ entry: TrafficEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .api:
            let contentType = entry.contentType?.lowercased() ?? ""
            return contentType.contains("json") || contentType.contains("xml")
        case .images:
            let contentType = entry.contentType?.lowercased() ?? ""
            return contentType.contains("image")
        case .documents:
            let contentType = entry.contentType?.lowercased() ?? ""
            return contentType.contains("html") || contentType.contains("text") || contentType.contains("css") || contentType.contains("javascript")
        case .errors:
            return entry.isError
        }
    }
}

// MARK: - Formatting Helpers

extension TrafficEntry {
    static func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        } else {
            return String(format: "%.2fs", duration)
        }
    }

    static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }
}
