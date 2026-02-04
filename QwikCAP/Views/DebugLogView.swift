import SwiftUI

struct DebugLogView: View {
    @State private var tunnelLog: String = "Loading..."
    @State private var trafficLog: String = "Loading..."
    @State private var selectedTab = 0
    @State private var autoRefresh = false

    private let appGroupID = "group.com.qwikcap.app"
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Tab selector
                Picker("Log Type", selection: $selectedTab) {
                    Text("Tunnel Log").tag(0)
                    Text("Traffic Log").tag(1)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()

                // Auto-refresh toggle
                HStack {
                    Toggle("Auto-refresh (2s)", isOn: $autoRefresh)
                        .font(.caption)
                    Spacer()
                    Button(action: refreshLogs) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                // Log content
                ScrollView {
                    ScrollViewReader { proxy in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(selectedTab == 0 ? tunnelLog : trafficLog)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("logContent")
                        }
                        .padding()
                    }
                }
                .background(Color(.systemGray6))

                // Actions
                HStack(spacing: 16) {
                    Button(action: clearLogs) {
                        Label("Clear", systemImage: "trash")
                    }
                    .foregroundColor(.red)

                    Spacer()

                    Button(action: copyLogs) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }

                    ShareLink(item: selectedTab == 0 ? tunnelLog : trafficLog) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                .padding()
            }
            .navigationTitle("Debug Logs")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                refreshLogs()
            }
            .onReceive(timer) { _ in
                if autoRefresh {
                    refreshLogs()
                }
            }
        }
    }

    private func refreshLogs() {
        // Read tunnel debug log
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let tunnelLogURL = containerURL.appendingPathComponent("tunnel_debug.log")
            if let content = try? String(contentsOf: tunnelLogURL, encoding: .utf8) {
                tunnelLog = content.isEmpty ? "No tunnel logs yet.\n\nStart the VPN to see logs here." : content
            } else {
                tunnelLog = "No tunnel log file found.\n\nStart the VPN to generate logs."
            }

            // Read traffic log
            let trafficLogURL = containerURL.appendingPathComponent("traffic_log.json")
            if let data = try? Data(contentsOf: trafficLogURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var formatted = "Traffic Entries: \(json.count)\n"
                formatted += "=" .repeated(50) + "\n\n"

                for (index, entry) in json.suffix(50).enumerated() {
                    let method = entry["method"] as? String ?? "?"
                    let host = entry["host"] as? String ?? "?"
                    let path = entry["path"] as? String ?? "/"
                    let status = entry["statusCode"] as? Int
                    let proto = entry["protocol"] as? String ?? "http"

                    formatted += "[\(index + 1)] \(method) \(proto)://\(host)\(path)\n"
                    if let status = status {
                        formatted += "    Status: \(status)\n"
                    }
                    if let error = entry["error"] as? String {
                        formatted += "    ERROR: \(error)\n"
                    }
                    formatted += "\n"
                }

                if json.isEmpty {
                    formatted += "No traffic captured yet.\n\nMake sure:\n1. VPN is connected\n2. Certificate is trusted\n3. Try browsing to a website"
                }

                trafficLog = formatted
            } else {
                trafficLog = "No traffic log found.\n\nTraffic will appear here once captured."
            }
        } else {
            tunnelLog = "Cannot access app group container.\n\nApp Group ID: \(appGroupID)"
            trafficLog = tunnelLog
        }
    }

    private func clearLogs() {
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            if selectedTab == 0 {
                let tunnelLogURL = containerURL.appendingPathComponent("tunnel_debug.log")
                try? "".write(to: tunnelLogURL, atomically: true, encoding: .utf8)
            } else {
                let trafficLogURL = containerURL.appendingPathComponent("traffic_log.json")
                try? "[]".data(using: .utf8)?.write(to: trafficLogURL)
            }
            refreshLogs()
        }
    }

    private func copyLogs() {
        UIPasteboard.general.string = selectedTab == 0 ? tunnelLog : trafficLog
    }
}

extension String {
    func repeated(_ count: Int) -> String {
        return String(repeating: self, count: count)
    }
}

#Preview {
    DebugLogView()
}
