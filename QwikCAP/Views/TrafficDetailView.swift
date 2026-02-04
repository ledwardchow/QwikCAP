import SwiftUI

struct TrafficDetailView: View {
    let entry: TrafficEntry

    @State private var selectedTab = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(entry.method)
                        .font(.headline)
                        .foregroundColor(methodColor(entry.method))

                    Text(entry.fullURL)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundColor(.primary)
                }

                HStack(spacing: 16) {
                    Label(entry.protocol.displayName, systemImage: entry.protocol.isSecure ? "lock.fill" : "lock.open")
                        .font(.caption)
                        .foregroundColor(entry.protocol.isSecure ? .green : .orange)

                    if let statusCode = entry.statusCode {
                        Label("\(statusCode)", systemImage: "number")
                            .font(.caption)
                            .foregroundColor(statusColor(statusCode))
                    }

                    if let duration = entry.duration {
                        Label(formatDuration(duration), systemImage: "clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
            }
            .padding()
            .background(Color(.systemGroupedBackground))

            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("Request").tag(0)
                Text("Response").tag(1)
                Text("Raw").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Content
            ScrollView {
                switch selectedTab {
                case 0:
                    RequestDetailView(entry: entry)
                case 1:
                    ResponseDetailView(entry: entry)
                case 2:
                    RawDetailView(entry: entry)
                default:
                    EmptyView()
                }
            }
        }
        .navigationTitle("Request Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Button(action: copyRequest) {
                        Label("Copy Request", systemImage: "doc.on.doc")
                    }
                    Button(action: copyResponse) {
                        Label("Copy Response", systemImage: "doc.on.doc")
                    }
                    Button(action: copyCurl) {
                        Label("Copy as cURL", systemImage: "terminal")
                    }
                    Divider()
                    Button(action: shareEntry) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
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

    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        case 500..<600: return .red
        default: return .gray
        }
    }

    private func formatDuration(_ duration: Double) -> String {
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1000)
        }
        return String(format: "%.2f s", duration)
    }

    private func copyRequest() {
        var text = "\(entry.method) \(entry.path) HTTP/1.1\n"
        text += "Host: \(entry.host)\n"
        for (key, value) in entry.requestHeaders {
            text += "\(key): \(value)\n"
        }
        if let body = entry.requestBody {
            text += "\n\(body)"
        }
        UIPasteboard.general.string = text
    }

    private func copyResponse() {
        var text = "HTTP/1.1 \(entry.statusCode ?? 0)\n"
        for (key, value) in entry.responseHeaders {
            text += "\(key): \(value)\n"
        }
        if let body = entry.responseBody {
            text += "\n\(body)"
        }
        UIPasteboard.general.string = text
    }

    private func copyCurl() {
        var curl = "curl"

        if entry.method != "GET" {
            curl += " -X \(entry.method)"
        }

        for (key, value) in entry.requestHeaders {
            curl += " -H '\(key): \(value)'"
        }

        if let body = entry.requestBody, !body.isEmpty {
            curl += " -d '\(body.replacingOccurrences(of: "'", with: "'\\''"))'"
        }

        curl += " '\(entry.fullURL)'"

        UIPasteboard.general.string = curl
    }

    private func shareEntry() {
        var text = "=== REQUEST ===\n"
        text += "\(entry.method) \(entry.fullURL)\n\n"
        text += "Headers:\n"
        for (key, value) in entry.requestHeaders {
            text += "  \(key): \(value)\n"
        }
        if let body = entry.requestBody {
            text += "\nBody:\n\(body)\n"
        }

        text += "\n=== RESPONSE ===\n"
        text += "Status: \(entry.statusCode ?? 0)\n\n"
        text += "Headers:\n"
        for (key, value) in entry.responseHeaders {
            text += "  \(key): \(value)\n"
        }
        if let body = entry.responseBody {
            text += "\nBody:\n\(body)\n"
        }

        let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }
}

struct RequestDetailView: View {
    let entry: TrafficEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Headers
            DetailSection(title: "Headers") {
                if entry.requestHeaders.isEmpty {
                    Text("No headers")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(entry.requestHeaders.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HeaderRow(key: key, value: value)
                    }
                }
            }

            // Body
            if let body = entry.requestBody, !body.isEmpty {
                DetailSection(title: "Body") {
                    BodyView(content: body, contentType: entry.requestHeaders["Content-Type"])
                }
            }
        }
        .padding()
    }
}

struct ResponseDetailView: View {
    let entry: TrafficEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Status
            DetailSection(title: "Status") {
                HStack {
                    Text("\(entry.statusCode ?? 0)")
                        .font(.title2)
                        .fontWeight(.bold)

                    if let code = entry.statusCode {
                        Text(HTTPURLResponse.localizedString(forStatusCode: code))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Headers
            DetailSection(title: "Headers") {
                if entry.responseHeaders.isEmpty {
                    Text("No headers")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(entry.responseHeaders.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HeaderRow(key: key, value: value)
                    }
                }
            }

            // Body
            if let body = entry.responseBody, !body.isEmpty {
                DetailSection(title: "Body") {
                    BodyView(content: body, contentType: entry.responseHeaders["Content-Type"])
                }
            }
        }
        .padding()
    }
}

struct RawDetailView: View {
    let entry: TrafficEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailSection(title: "Raw Request") {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(buildRawRequest())
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
            }

            DetailSection(title: "Raw Response") {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(buildRawResponse())
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
            }
        }
        .padding()
    }

    private func buildRawRequest() -> String {
        var raw = "\(entry.method) \(entry.path) HTTP/1.1\r\n"
        raw += "Host: \(entry.host)\r\n"

        for (key, value) in entry.requestHeaders {
            raw += "\(key): \(value)\r\n"
        }

        raw += "\r\n"

        if let body = entry.requestBody {
            raw += body
        }

        return raw
    }

    private func buildRawResponse() -> String {
        var raw = "HTTP/1.1 \(entry.statusCode ?? 0) \(HTTPURLResponse.localizedString(forStatusCode: entry.statusCode ?? 0))\r\n"

        for (key, value) in entry.responseHeaders {
            raw += "\(key): \(value)\r\n"
        }

        raw += "\r\n"

        if let body = entry.responseBody {
            raw += body
        }

        return raw
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            content
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
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}

struct BodyView: View {
    let content: String
    let contentType: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let type = contentType {
                Text(type)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray5))
                    .cornerRadius(4)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(formattedContent)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 400)
            .background(Color(.systemGray6))
            .cornerRadius(8)
        }
    }

    var formattedContent: String {
        // Try to format JSON
        if contentType?.contains("json") == true {
            if let data = content.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data),
               let prettyData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
               let prettyString = String(data: prettyData, encoding: .utf8) {
                return prettyString
            }
        }
        return content
    }
}

#Preview {
    NavigationView {
        TrafficDetailView(entry: TrafficEntry(
            protocol: .https,
            method: "POST",
            host: "api.example.com",
            port: 443,
            path: "/users/login",
            requestHeaders: ["Content-Type": "application/json", "Authorization": "Bearer token123"],
            requestBody: "{\"username\": \"test\", \"password\": \"secret\"}",
            statusCode: 200,
            responseHeaders: ["Content-Type": "application/json"],
            responseBody: "{\"success\": true, \"token\": \"abc123\"}",
            duration: 0.245
        ))
    }
}
