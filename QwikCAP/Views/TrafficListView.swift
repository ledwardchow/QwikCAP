import SwiftUI

struct TrafficListView: View {
    @EnvironmentObject var trafficLogger: TrafficLogger

    @State private var searchText = ""
    @State private var selectedProtocol: TrafficProtocol?
    @State private var selectedMethod: String?
    @State private var selectedEntry: TrafficEntry?
    @State private var showFilters = false
    @State private var showExportOptions = false

    var filteredEntries: [TrafficEntry] {
        trafficLogger.filteredEntries(
            searchText: searchText,
            protocolFilter: selectedProtocol,
            methodFilter: selectedMethod
        ).reversed() // Most recent first
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Filter bar
                if showFilters {
                    FilterBar(
                        selectedProtocol: $selectedProtocol,
                        selectedMethod: $selectedMethod
                    )
                }

                // Traffic list
                if filteredEntries.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.left.arrow.right.circle")
                            .font(.system(size: 64))
                            .foregroundColor(.gray)
                        Text("No Traffic Captured")
                            .font(.headline)
                        Text("Start capturing to see HTTP, HTTPS, and WebSocket traffic here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List(filteredEntries) { entry in
                        TrafficRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedEntry = entry
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Traffic")
            .searchable(text: $searchText, prompt: "Search host, path, or body...")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showFilters.toggle() }) {
                        Image(systemName: showFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { exportAsHAR() }) {
                            Label("Export as HAR", systemImage: "doc.text")
                        }
                        Button(action: { exportForBurp() }) {
                            Label("Export for Burp", systemImage: "square.and.arrow.up")
                        }
                        Divider()
                        Button(role: .destructive, action: { trafficLogger.clearLog() }) {
                            Label("Clear All", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $selectedEntry) { entry in
                NavigationView {
                    TrafficDetailView(entry: entry)
                }
            }
        }
    }

    private func exportAsHAR() {
        guard let data = trafficLogger.exportAsHAR() else { return }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("traffic.har")
        try? data.write(to: tempURL)

        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }

    private func exportForBurp() {
        guard let data = trafficLogger.exportForBurp() else { return }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("traffic_burp.json")
        try? data.write(to: tempURL)

        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }
}

struct FilterBar: View {
    @Binding var selectedProtocol: TrafficProtocol?
    @Binding var selectedMethod: String?

    let methods = ["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Protocol filters
                FilterChip(
                    label: "All",
                    isSelected: selectedProtocol == nil,
                    action: { selectedProtocol = nil }
                )

                ForEach(TrafficProtocol.allCases, id: \.self) { proto in
                    FilterChip(
                        label: proto.displayName,
                        isSelected: selectedProtocol == proto,
                        action: { selectedProtocol = proto }
                    )
                }

                Divider()
                    .frame(height: 24)

                // Method filters
                FilterChip(
                    label: "Any Method",
                    isSelected: selectedMethod == nil,
                    action: { selectedMethod = nil }
                )

                ForEach(methods, id: \.self) { method in
                    FilterChip(
                        label: method,
                        isSelected: selectedMethod == method,
                        action: { selectedMethod = method }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }
}

struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color(.systemGray5))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(16)
        }
    }
}

struct TrafficRow: View {
    let entry: TrafficEntry

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            StatusBadge(entry: entry)

            VStack(alignment: .leading, spacing: 4) {
                // Method and path
                HStack(spacing: 6) {
                    Text(entry.method)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(methodColor(entry.method))

                    Text(entry.path)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                // Host and protocol
                HStack(spacing: 4) {
                    Image(systemName: entry.protocol.isSecure ? "lock.fill" : "lock.open")
                        .font(.caption2)
                        .foregroundColor(entry.protocol.isSecure ? .green : .orange)

                    Text(entry.host)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if entry.port != entry.protocol.defaultPort {
                        Text(":\(entry.port)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Text(formatTime(entry.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func methodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": return .blue
        case "POST": return .green
        case "PUT": return .orange
        case "DELETE": return .red
        case "PATCH": return .purple
        default: return .gray
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct StatusBadge: View {
    let entry: TrafficEntry

    var body: some View {
        Text(entry.displayStatus)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .frame(width: 40)
            .padding(.vertical, 4)
            .background(statusColor)
            .cornerRadius(4)
    }

    var statusColor: Color {
        switch entry.statusColor {
        case .success: return .green
        case .redirect: return .blue
        case .clientError: return .orange
        case .serverError: return .red
        case .error: return .red
        case .neutral: return .gray
        }
    }
}

#Preview {
    TrafficListView()
        .environmentObject(TrafficLogger.shared)
}
