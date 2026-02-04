import Foundation
import Combine

class TrafficLogger: ObservableObject {
    static let shared = TrafficLogger()

    @Published var entries: [TrafficEntry] = []
    @Published var httpCount: Int = 0
    @Published var httpsCount: Int = 0
    @Published var wsCount: Int = 0

    private let appGroupID = "group.com.qwikcap.app"
    private var fileMonitor: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.qwikcap.trafficlogger", qos: .utility)

    private init() {
        setupLogFileMonitor()
        loadExistingEntries()
    }

    // MARK: - Log File Management

    private var logFileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("traffic_log.json")
    }

    private func setupLogFileMonitor() {
        guard let url = logFileURL else { return }

        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: "[]".data(using: .utf8))
        }

        // Monitor file for changes
        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        fileMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: queue
        )

        fileMonitor?.setEventHandler { [weak self] in
            self?.loadExistingEntries()
        }

        fileMonitor?.setCancelHandler {
            close(fileDescriptor)
        }

        fileMonitor?.resume()
    }

    private func loadExistingEntries() {
        guard let url = logFileURL,
              let data = try? Data(contentsOf: url),
              let loadedEntries = try? JSONDecoder().decode([TrafficEntry].self, from: data) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.entries = loadedEntries.suffix(1000) // Keep last 1000 entries
            self?.updateCounts()
        }
    }

    private func updateCounts() {
        httpCount = entries.filter { $0.protocol == .http }.count
        httpsCount = entries.filter { $0.protocol == .https }.count
        wsCount = entries.filter { $0.protocol == .websocket }.count
    }

    // MARK: - Logging

    func logEntry(_ entry: TrafficEntry) {
        queue.async { [weak self] in
            guard let self = self,
                  let url = self.logFileURL else { return }

            var currentEntries = (try? JSONDecoder().decode([TrafficEntry].self, from: Data(contentsOf: url))) ?? []
            currentEntries.append(entry)

            // Keep only last 1000 entries
            if currentEntries.count > 1000 {
                currentEntries = Array(currentEntries.suffix(1000))
            }

            if let data = try? JSONEncoder().encode(currentEntries) {
                try? data.write(to: url)
            }
        }
    }

    func clearLog() {
        queue.async { [weak self] in
            guard let url = self?.logFileURL else { return }
            try? "[]".data(using: .utf8)?.write(to: url)

            DispatchQueue.main.async {
                self?.entries = []
                self?.updateCounts()
            }
        }
    }

    // MARK: - Filtering

    func filteredEntries(
        searchText: String = "",
        protocolFilter: TrafficProtocol? = nil,
        methodFilter: String? = nil,
        statusFilter: Int? = nil
    ) -> [TrafficEntry] {
        entries.filter { entry in
            // Search text filter
            let matchesSearch = searchText.isEmpty ||
                entry.host.localizedCaseInsensitiveContains(searchText) ||
                entry.path.localizedCaseInsensitiveContains(searchText) ||
                (entry.requestBody?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                (entry.responseBody?.localizedCaseInsensitiveContains(searchText) ?? false)

            // Protocol filter
            let matchesProtocol = protocolFilter == nil || entry.protocol == protocolFilter

            // Method filter
            let matchesMethod = methodFilter == nil || entry.method == methodFilter

            // Status filter
            let matchesStatus = statusFilter == nil || entry.statusCode == statusFilter

            return matchesSearch && matchesProtocol && matchesMethod && matchesStatus
        }
    }

    // MARK: - Export

    func exportAsHAR() -> Data? {
        let harEntries = entries.map { entry -> [String: Any] in
            var harEntry: [String: Any] = [
                "startedDateTime": ISO8601DateFormatter().string(from: entry.timestamp),
                "time": entry.duration ?? 0,
                "request": [
                    "method": entry.method,
                    "url": "\(entry.protocol.rawValue)://\(entry.host)\(entry.path)",
                    "httpVersion": "HTTP/1.1",
                    "cookies": [],
                    "headers": entry.requestHeaders.map { ["name": $0.key, "value": $0.value] },
                    "queryString": [],
                    "headersSize": -1,
                    "bodySize": entry.requestBody?.count ?? 0
                ],
                "response": [
                    "status": entry.statusCode ?? 0,
                    "statusText": HTTPURLResponse.localizedString(forStatusCode: entry.statusCode ?? 0),
                    "httpVersion": "HTTP/1.1",
                    "cookies": [],
                    "headers": entry.responseHeaders.map { ["name": $0.key, "value": $0.value] },
                    "content": [
                        "size": entry.responseBody?.count ?? 0,
                        "mimeType": entry.responseHeaders["Content-Type"] ?? "application/octet-stream",
                        "text": entry.responseBody ?? ""
                    ],
                    "redirectURL": "",
                    "headersSize": -1,
                    "bodySize": entry.responseBody?.count ?? 0
                ],
                "cache": [:],
                "timings": [
                    "send": 0,
                    "wait": entry.duration ?? 0,
                    "receive": 0
                ]
            ]
            return harEntry
        }

        let har: [String: Any] = [
            "log": [
                "version": "1.2",
                "creator": [
                    "name": "QwikCAP",
                    "version": "1.0"
                ],
                "entries": harEntries
            ]
        ]

        return try? JSONSerialization.data(withJSONObject: har, options: .prettyPrinted)
    }

    func exportForBurp() -> Data? {
        // Export in a format compatible with Burp Suite import
        var burpExport: [[String: Any]] = []

        for entry in entries {
            let request = buildRawHTTPRequest(entry)
            let response = buildRawHTTPResponse(entry)

            burpExport.append([
                "request": request.base64EncodedString(),
                "response": response.base64EncodedString(),
                "host": entry.host,
                "port": entry.port,
                "protocol": entry.protocol.rawValue,
                "time": ISO8601DateFormatter().string(from: entry.timestamp)
            ])
        }

        return try? JSONSerialization.data(withJSONObject: burpExport, options: .prettyPrinted)
    }

    private func buildRawHTTPRequest(_ entry: TrafficEntry) -> Data {
        var request = "\(entry.method) \(entry.path) HTTP/1.1\r\n"
        request += "Host: \(entry.host)\r\n"

        for (key, value) in entry.requestHeaders {
            request += "\(key): \(value)\r\n"
        }

        request += "\r\n"

        if let body = entry.requestBody {
            request += body
        }

        return request.data(using: .utf8) ?? Data()
    }

    private func buildRawHTTPResponse(_ entry: TrafficEntry) -> Data {
        var response = "HTTP/1.1 \(entry.statusCode ?? 0) \(HTTPURLResponse.localizedString(forStatusCode: entry.statusCode ?? 0))\r\n"

        for (key, value) in entry.responseHeaders {
            response += "\(key): \(value)\r\n"
        }

        response += "\r\n"

        if let body = entry.responseBody {
            response += body
        }

        return response.data(using: .utf8) ?? Data()
    }
}
