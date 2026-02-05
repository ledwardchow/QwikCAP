import Foundation
import SQLite3
import os.log

class TrafficRecorder {
    private let log = OSLog(subsystem: "com.qwikcap.tunnel", category: "TrafficRecorder")

    private let appGroupID = "group.com.qwikcap.app"
    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.qwikcap.recorder.db")

    init() {
        openDatabase()
    }

    deinit {
        closeDatabase()
    }

    // MARK: - Database Setup

    private func openDatabase() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            os_log("Failed to get app group container URL", log: log, type: .error)
            return
        }

        let dbPath = containerURL.appendingPathComponent("traffic.db").path

        dbQueue.sync {
            if sqlite3_open(dbPath, &db) != SQLITE_OK {
                os_log("Failed to open database at %{public}@", log: log, type: .error, dbPath)
                return
            }

            createTables()
            os_log("Traffic database opened at %{public}@", log: log, type: .info, dbPath)
        }
    }

    private func createTables() {
        let createTableSQL = """
            CREATE TABLE IF NOT EXISTS traffic (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                method TEXT NOT NULL,
                url TEXT NOT NULL,
                host TEXT NOT NULL,
                path TEXT NOT NULL,
                scheme TEXT NOT NULL,
                status_code INTEGER,
                request_headers TEXT,
                request_body BLOB,
                response_headers TEXT,
                response_body BLOB,
                response_content_type TEXT,
                duration REAL,
                error TEXT,
                connection_id TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_timestamp ON traffic(timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_host ON traffic(host);
            """

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, createTableSQL, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                os_log("Failed to create tables: %{public}s", log: log, type: .error, errMsg)
                sqlite3_free(errMsg)
            }
        }
    }

    private func closeDatabase() {
        dbQueue.sync {
            if let db = db {
                sqlite3_close(db)
            }
            db = nil
        }
    }

    // MARK: - Recording

    func recordTraffic(_ entry: TrafficEntryData) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

            let insertSQL = """
                INSERT OR REPLACE INTO traffic (
                    id, timestamp, method, url, host, path, scheme,
                    status_code, request_headers, request_body,
                    response_headers, response_body, response_content_type,
                    duration, error, connection_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
                os_log("Failed to prepare insert statement", log: self.log, type: .error)
                return
            }

            defer { sqlite3_finalize(statement) }

            // Bind parameters
            let idString = entry.id.uuidString
            sqlite3_bind_text(statement, 1, idString, -1, nil)
            sqlite3_bind_double(statement, 2, entry.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(statement, 3, entry.method, -1, nil)
            sqlite3_bind_text(statement, 4, entry.url, -1, nil)
            sqlite3_bind_text(statement, 5, entry.host, -1, nil)
            sqlite3_bind_text(statement, 6, entry.path, -1, nil)
            sqlite3_bind_text(statement, 7, entry.scheme, -1, nil)

            if let statusCode = entry.statusCode {
                sqlite3_bind_int(statement, 8, Int32(statusCode))
            } else {
                sqlite3_bind_null(statement, 8)
            }

            // Serialize headers as JSON
            if let headersData = try? JSONEncoder().encode(entry.requestHeaders),
               let headersString = String(data: headersData, encoding: .utf8) {
                sqlite3_bind_text(statement, 9, headersString, -1, nil)
            } else {
                sqlite3_bind_null(statement, 9)
            }

            // Request body
            if let body = entry.requestBody {
                body.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, 10, bytes.baseAddress, Int32(body.count), nil)
                }
            } else {
                sqlite3_bind_null(statement, 10)
            }

            // Response headers
            if let responseHeaders = entry.responseHeaders,
               let headersData = try? JSONEncoder().encode(responseHeaders),
               let headersString = String(data: headersData, encoding: .utf8) {
                sqlite3_bind_text(statement, 11, headersString, -1, nil)
            } else {
                sqlite3_bind_null(statement, 11)
            }

            // Response body
            if let body = entry.responseBody {
                body.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, 12, bytes.baseAddress, Int32(body.count), nil)
                }
            } else {
                sqlite3_bind_null(statement, 12)
            }

            // Content type
            let contentType = entry.responseHeaders?["Content-Type"] ?? entry.responseHeaders?["content-type"]
            if let contentType = contentType {
                sqlite3_bind_text(statement, 13, contentType, -1, nil)
            } else {
                sqlite3_bind_null(statement, 13)
            }

            // Duration
            if let duration = entry.duration {
                sqlite3_bind_double(statement, 14, duration)
            } else {
                sqlite3_bind_null(statement, 14)
            }

            // Error
            if let error = entry.error {
                sqlite3_bind_text(statement, 15, error, -1, nil)
            } else {
                sqlite3_bind_null(statement, 15)
            }

            // Connection ID
            let connectionIdString = entry.connectionId.uuidString
            sqlite3_bind_text(statement, 16, connectionIdString, -1, nil)

            // Execute
            if sqlite3_step(statement) != SQLITE_DONE {
                os_log("Failed to insert traffic entry", log: self.log, type: .error)
            } else {
                os_log("Recorded traffic: %{public}@ %{public}@", log: self.log, type: .debug, entry.method, entry.url)

                // Post notification
                self.postNotification()
            }

            // Cleanup old entries (keep last 1000)
            self.cleanupOldEntries()
        }
    }

    // MARK: - Notification

    private func postNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.qwikcap.traffic.new" as CFString),
            nil,
            nil,
            true
        )
    }

    // MARK: - Cleanup

    private func cleanupOldEntries() {
        guard let db = db else { return }

        let deleteSQL = """
            DELETE FROM traffic WHERE id NOT IN (
                SELECT id FROM traffic ORDER BY timestamp DESC LIMIT 1000
            )
            """

        sqlite3_exec(db, deleteSQL, nil, nil, nil)
    }

    func clearAllTraffic() {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            sqlite3_exec(db, "DELETE FROM traffic", nil, nil, nil)
            os_log("Cleared all traffic entries", log: self.log, type: .info)
        }
    }
}
