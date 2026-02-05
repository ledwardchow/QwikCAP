import Foundation
import Combine
import SQLite3

class TrafficStore: ObservableObject {
    static let shared = TrafficStore()

    @Published var entries: [TrafficEntry] = []
    @Published var isLoading: Bool = false
    @Published var totalCount: Int = 0

    private let appGroupID = "group.com.qwikcap.app"
    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.qwikcap.trafficstore.db")
    private var notificationObserver: AnyObject?
    private var refreshTimer: Timer?

    private init() {
        openDatabase()
        observeNotifications()
        loadEntries()
        startAutoRefresh()
    }

    deinit {
        stopAutoRefresh()
        removeNotificationObserver()
        closeDatabase()
    }

    // MARK: - Public Methods

    func loadEntries(filter: TrafficFilter = .all, searchText: String = "", limit: Int = 200) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

            var entries: [TrafficEntry] = []
            var query = "SELECT * FROM traffic"
            var conditions: [String] = []

            // Apply search filter
            if !searchText.isEmpty {
                conditions.append("(url LIKE '%\(searchText)%' OR host LIKE '%\(searchText)%')")
            }

            // Apply type filter
            switch filter {
            case .all:
                break
            case .errors:
                conditions.append("(status_code >= 400 OR error IS NOT NULL)")
            case .api:
                conditions.append("(response_content_type LIKE '%json%' OR response_content_type LIKE '%xml%')")
            case .images:
                conditions.append("response_content_type LIKE '%image%'")
            case .documents:
                conditions.append("(response_content_type LIKE '%html%' OR response_content_type LIKE '%text%' OR response_content_type LIKE '%css%' OR response_content_type LIKE '%javascript%')")
            }

            if !conditions.isEmpty {
                query += " WHERE " + conditions.joined(separator: " AND ")
            }

            query += " ORDER BY timestamp DESC LIMIT \(limit)"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
                return
            }

            defer { sqlite3_finalize(statement) }

            while sqlite3_step(statement) == SQLITE_ROW {
                if let entry = self.parseRow(statement) {
                    entries.append(entry)
                }
            }

            // Get total count
            var countStatement: OpaquePointer?
            let countQuery = "SELECT COUNT(*) FROM traffic"
            var count = 0
            if sqlite3_prepare_v2(db, countQuery, -1, &countStatement, nil) == SQLITE_OK {
                if sqlite3_step(countStatement) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(countStatement, 0))
                }
                sqlite3_finalize(countStatement)
            }

            DispatchQueue.main.async {
                self.entries = entries
                self.totalCount = count
                self.isLoading = false
            }
        }
    }

    func getEntry(id: UUID) -> TrafficEntry? {
        var entry: TrafficEntry?

        dbQueue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }

            let query = "SELECT * FROM traffic WHERE id = ?"
            var statement: OpaquePointer?

            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
                return
            }

            defer { sqlite3_finalize(statement) }

            let idString = id.uuidString
            sqlite3_bind_text(statement, 1, idString, -1, nil)

            if sqlite3_step(statement) == SQLITE_ROW {
                entry = self.parseRow(statement)
            }
        }

        return entry
    }

    func clearAllTraffic() {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

            sqlite3_exec(db, "DELETE FROM traffic", nil, nil, nil)

            DispatchQueue.main.async {
                self.entries = []
                self.totalCount = 0
            }
        }
    }

    func refresh() {
        loadEntries()
    }

    // MARK: - Database Setup

    private func openDatabase() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            print("Failed to get app group container URL")
            return
        }

        let dbPath = containerURL.appendingPathComponent("traffic.db").path

        dbQueue.sync {
            if sqlite3_open(dbPath, &db) != SQLITE_OK {
                print("Failed to open database at \(dbPath)")
                return
            }

            createTables()
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

        sqlite3_exec(db, createTableSQL, nil, nil, nil)
    }

    private func closeDatabase() {
        dbQueue.sync {
            if let db = db {
                sqlite3_close(db)
            }
            db = nil
        }
    }

    // MARK: - Notification Observation

    private func observeNotifications() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()

        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let store = Unmanaged<TrafficStore>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    store.loadEntries()
                }
            },
            "com.qwikcap.traffic.new" as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func removeNotificationObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, nil, nil)
    }

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.loadEntries()
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Row Parsing

    private func parseRow(_ statement: OpaquePointer?) -> TrafficEntry? {
        guard let statement = statement else { return nil }

        let id = UUID(uuidString: String(cString: sqlite3_column_text(statement, 0))) ?? UUID()
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        let method = String(cString: sqlite3_column_text(statement, 2))
        let url = String(cString: sqlite3_column_text(statement, 3))
        let host = String(cString: sqlite3_column_text(statement, 4))
        let path = String(cString: sqlite3_column_text(statement, 5))
        let scheme = String(cString: sqlite3_column_text(statement, 6))

        let statusCode: Int?
        if sqlite3_column_type(statement, 7) != SQLITE_NULL {
            statusCode = Int(sqlite3_column_int(statement, 7))
        } else {
            statusCode = nil
        }

        let requestHeaders: [String: String]
        if let headersText = sqlite3_column_text(statement, 8) {
            let headersString = String(cString: headersText)
            if let data = headersString.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String: String].self, from: data) {
                requestHeaders = parsed
            } else {
                requestHeaders = [:]
            }
        } else {
            requestHeaders = [:]
        }

        var requestBody: Data?
        if sqlite3_column_type(statement, 9) != SQLITE_NULL {
            let bytes = sqlite3_column_blob(statement, 9)
            let length = sqlite3_column_bytes(statement, 9)
            if let bytes = bytes, length > 0 {
                requestBody = Data(bytes: bytes, count: Int(length))
            }
        }

        let responseHeaders: [String: String]?
        if let headersText = sqlite3_column_text(statement, 10) {
            let headersString = String(cString: headersText)
            if let data = headersString.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String: String].self, from: data) {
                responseHeaders = parsed
            } else {
                responseHeaders = nil
            }
        } else {
            responseHeaders = nil
        }

        var responseBody: Data?
        if sqlite3_column_type(statement, 11) != SQLITE_NULL {
            let bytes = sqlite3_column_blob(statement, 11)
            let length = sqlite3_column_bytes(statement, 11)
            if let bytes = bytes, length > 0 {
                responseBody = Data(bytes: bytes, count: Int(length))
            }
        }

        let duration: TimeInterval?
        if sqlite3_column_type(statement, 13) != SQLITE_NULL {
            duration = sqlite3_column_double(statement, 13)
        } else {
            duration = nil
        }

        let error: String?
        if sqlite3_column_type(statement, 14) != SQLITE_NULL {
            error = String(cString: sqlite3_column_text(statement, 14))
        } else {
            error = nil
        }

        let connectionId = UUID(uuidString: String(cString: sqlite3_column_text(statement, 15))) ?? UUID()

        return TrafficEntry(
            id: id,
            timestamp: timestamp,
            method: method,
            url: url,
            host: host,
            path: path,
            scheme: scheme,
            statusCode: statusCode,
            requestHeaders: requestHeaders,
            requestBody: requestBody,
            responseHeaders: responseHeaders,
            responseBody: responseBody,
            duration: duration,
            error: error,
            connectionId: connectionId
        )
    }
}
