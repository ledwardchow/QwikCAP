import Foundation
import os.log

class ConnectionManager {
    private let log = OSLog(subsystem: "com.qwikcap.tunnel", category: "ConnectionManager")

    private let appGroupID: String
    private var activeConnections: [String: ConnectionInfo] = [:]
    private let connectionsLock = NSLock()

    private var httpCount: Int = 0
    private var httpsCount: Int = 0
    private var wsCount: Int = 0
    private var totalBytes: Int = 0

    private let logFileURL: URL?

    init(appGroupID: String) {
        self.appGroupID = appGroupID

        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            logFileURL = containerURL.appendingPathComponent("traffic_log.json")

            // Ensure file exists
            if !FileManager.default.fileExists(atPath: logFileURL!.path) {
                try? "[]".data(using: .utf8)?.write(to: logFileURL!)
            }
        } else {
            logFileURL = nil
        }
    }

    // MARK: - Request Logging

    func logRequest(
        connectionId: String,
        method: String,
        host: String,
        port: Int,
        path: String,
        headers: [String: String],
        body: String?,
        isHTTPS: Bool
    ) {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }

        let info = ConnectionInfo(
            id: connectionId,
            timestamp: Date(),
            method: method,
            host: host,
            port: port,
            path: path,
            requestHeaders: headers,
            requestBody: body,
            isHTTPS: isHTTPS
        )

        activeConnections[connectionId] = info

        // Update stats
        if isHTTPS {
            httpsCount += 1
        } else {
            httpCount += 1
        }

        os_log("Request: %{public}@ %{public}@%{public}@", log: log, type: .debug, method, host, path)
    }

    func logResponse(
        connectionId: String,
        statusCode: Int,
        headers: [String: String],
        body: String?
    ) {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }

        guard var info = activeConnections[connectionId] else {
            os_log("Response for unknown connection: %{public}@", log: log, type: .debug, connectionId)
            return
        }

        info.statusCode = statusCode
        info.responseHeaders = headers
        info.responseBody = body
        info.duration = Date().timeIntervalSince(info.timestamp)

        activeConnections[connectionId] = info

        // Save to log file
        saveEntry(info)

        os_log("Response: %{public}d for %{public}@", log: log, type: .debug, statusCode, connectionId)
    }

    func logWebSocketFrame(
        connectionId: String,
        host: String,
        port: Int,
        path: String,
        opcode: Int,
        direction: String,
        payload: String?,
        isSecure: Bool
    ) {
        connectionsLock.lock()
        wsCount += 1
        connectionsLock.unlock()

        let entry = TrafficLogEntry(
            id: UUID().uuidString,
            timestamp: Date(),
            protocolType: isSecure ? "wss" : "ws",
            method: direction == "outgoing" ? "SEND" : "RECV",
            host: host,
            port: port,
            path: path,
            requestHeaders: [:],
            requestBody: payload,
            statusCode: nil,
            responseHeaders: [:],
            responseBody: nil,
            duration: nil,
            connectionId: connectionId,
            isWebSocketFrame: true,
            webSocketOpcode: opcode,
            webSocketDirection: direction,
            error: nil
        )

        saveLogEntry(entry)
    }

    func logError(connectionId: String, error: String) {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }

        if var info = activeConnections[connectionId] {
            info.error = error
            activeConnections[connectionId] = info
            saveEntry(info)
        }
    }

    // MARK: - Connection Lifecycle

    func closeConnection(_ connectionId: String) {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }

        activeConnections.removeValue(forKey: connectionId)
    }

    func closeAllConnections() {
        connectionsLock.lock()
        defer { connectionsLock.unlock()  }

        activeConnections.removeAll()
    }

    // MARK: - Statistics

    func getStatistics() -> [String: Int] {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }

        return [
            "http": httpCount,
            "https": httpsCount,
            "websocket": wsCount,
            "totalBytes": totalBytes,
            "activeConnections": activeConnections.count
        ]
    }

    func clearStatistics() {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }

        httpCount = 0
        httpsCount = 0
        wsCount = 0
        totalBytes = 0
    }

    // MARK: - Persistence

    private func saveEntry(_ info: ConnectionInfo) {
        let entry = TrafficLogEntry(
            id: info.id,
            timestamp: info.timestamp,
            protocolType: info.isHTTPS ? "https" : "http",
            method: info.method,
            host: info.host,
            port: info.port,
            path: info.path,
            requestHeaders: info.requestHeaders,
            requestBody: info.requestBody,
            statusCode: info.statusCode,
            responseHeaders: info.responseHeaders ?? [:],
            responseBody: info.responseBody,
            duration: info.duration,
            connectionId: info.id,
            isWebSocketFrame: false,
            webSocketOpcode: nil,
            webSocketDirection: nil,
            error: info.error
        )

        saveLogEntry(entry)
    }

    private func saveLogEntry(_ entry: TrafficLogEntry) {
        guard let url = logFileURL else { return }

        DispatchQueue.global(qos: .utility).async {
            do {
                var entries: [TrafficLogEntry] = []

                if let data = try? Data(contentsOf: url),
                   let existing = try? JSONDecoder().decode([TrafficLogEntry].self, from: data) {
                    entries = existing
                }

                entries.append(entry)

                // Keep only last 1000 entries
                if entries.count > 1000 {
                    entries = Array(entries.suffix(1000))
                }

                let data = try JSONEncoder().encode(entries)
                try data.write(to: url, options: .atomic)
            } catch {
                os_log("Failed to save log entry: %{public}@", type: .error, error.localizedDescription)
            }
        }
    }
}

// MARK: - Connection Info

struct ConnectionInfo {
    let id: String
    let timestamp: Date
    let method: String
    let host: String
    let port: Int
    let path: String
    let requestHeaders: [String: String]
    let requestBody: String?
    let isHTTPS: Bool

    var statusCode: Int?
    var responseHeaders: [String: String]?
    var responseBody: String?
    var duration: TimeInterval?
    var error: String?
}

// MARK: - Log Entry (matches main app's TrafficEntry)

struct TrafficLogEntry: Codable {
    let id: String
    let timestamp: Date
    let protocolType: String
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
    let webSocketOpcode: Int?
    let webSocketDirection: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, method, host, port, path
        case requestHeaders, requestBody, statusCode
        case responseHeaders, responseBody, duration
        case connectionId, isWebSocketFrame
        case webSocketOpcode, webSocketDirection, error
        case protocolType = "protocol"
    }
}
