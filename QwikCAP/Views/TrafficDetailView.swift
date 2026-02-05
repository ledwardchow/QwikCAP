import SwiftUI

struct TrafficDetailView: View {
    let entry: TrafficEntry

    @State private var selectedTab = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Summary header
                summaryHeader

                // Tabs
                Picker("Section", selection: $selectedTab) {
                    Text("Headers").tag(0)
                    Text("Request").tag(1)
                    Text("Response").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                // Content
                ScrollView {
                    switch selectedTab {
                    case 0:
                        headersView
                    case 1:
                        bodyView(data: entry.requestBody, contentType: entry.requestHeaders["Content-Type"])
                    case 2:
                        bodyView(data: entry.responseBody, contentType: entry.contentType)
                    default:
                        EmptyView()
                    }
                }
            }
            .navigationTitle("Request Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: entry.url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.method)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(methodColor)
                    .foregroundColor(.white)
                    .cornerRadius(4)

                if let status = entry.statusCode {
                    Text("\(status)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(statusColor(status))
                }

                Spacer()
            }

            Text(entry.url)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)

            HStack(spacing: 16) {
                if let duration = entry.duration {
                    Label(TrafficEntry.formatDuration(duration), systemImage: "clock")
                }

                if entry.requestSize > 0 {
                    Label(TrafficEntry.formatBytes(entry.requestSize), systemImage: "arrow.up")
                }

                if entry.responseSize > 0 {
                    Label(TrafficEntry.formatBytes(entry.responseSize), systemImage: "arrow.down")
                }

                if let error = entry.error {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemGroupedBackground))
    }

    private var headersView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Request headers
            VStack(alignment: .leading, spacing: 8) {
                Text("Request Headers")
                    .font(.headline)
                    .padding(.horizontal)

                if entry.requestHeaders.isEmpty {
                    Text("No headers")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                } else {
                    ForEach(entry.requestHeaders.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HeaderRow(key: key, value: value)
                    }
                }
            }

            Divider()

            // Response headers
            VStack(alignment: .leading, spacing: 8) {
                Text("Response Headers")
                    .font(.headline)
                    .padding(.horizontal)

                if let responseHeaders = entry.responseHeaders, !responseHeaders.isEmpty {
                    ForEach(responseHeaders.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HeaderRow(key: key, value: value)
                    }
                } else {
                    Text("No headers")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
            }
        }
        .padding(.vertical)
    }

    private func bodyView(data: Data?, contentType: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let data = data, !data.isEmpty {
                // Content type info
                if let contentType = contentType {
                    HStack {
                        Text("Content-Type:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(contentType)
                            .font(.caption)
                    }
                    .padding(.horizontal)
                }

                // Size info
                HStack {
                    Text("Size:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(TrafficEntry.formatBytes(data.count))
                        .font(.caption)
                }
                .padding(.horizontal)

                Divider()
                    .padding(.vertical, 8)

                // Body content
                if let string = String(data: data, encoding: .utf8) {
                    // Try to pretty-print JSON
                    if contentType?.contains("json") == true,
                       let jsonObject = try? JSONSerialization.jsonObject(with: data),
                       let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted),
                       let prettyString = String(data: prettyData, encoding: .utf8) {
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(prettyString)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.horizontal)
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(string)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.horizontal)
                        }
                    }
                } else {
                    // Binary data
                    Text("Binary data (\(TrafficEntry.formatBytes(data.count)))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)

                    // Hex dump preview
                    let hexPreview = data.prefix(256).map { String(format: "%02x", $0) }.joined(separator: " ")
                    Text(hexPreview)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No body content")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            }
        }
        .padding(.vertical)
    }

    private var methodColor: Color {
        switch entry.method.uppercased() {
        case "GET": return .blue
        case "POST": return .green
        case "PUT": return .orange
        case "DELETE": return .red
        case "PATCH": return .purple
        default: return .gray
        }
    }

    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        case 500..<600: return .red
        default: return .secondary
        }
    }
}

struct HeaderRow: View {
    let key: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.caption)
                .fontWeight(.medium)
            Text(value)
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

#Preview {
    TrafficDetailView(entry: TrafficEntry(
        method: "POST",
        url: "https://api.example.com/users/login",
        host: "api.example.com",
        path: "/users/login",
        scheme: "https",
        statusCode: 200,
        requestHeaders: [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": "Bearer token123"
        ],
        requestBody: "{\"username\": \"test\", \"password\": \"secret\"}".data(using: .utf8),
        responseHeaders: [
            "Content-Type": "application/json",
            "X-Request-Id": "abc123"
        ],
        responseBody: "{\"token\": \"jwt123\", \"user\": {\"id\": 1, \"name\": \"Test User\"}}".data(using: .utf8),
        duration: 0.234
    ))
}
