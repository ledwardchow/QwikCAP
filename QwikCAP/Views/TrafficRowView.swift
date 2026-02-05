import SwiftUI

struct TrafficRowView: View {
    let entry: TrafficEntry

    var body: some View {
        HStack(spacing: 12) {
            // Method badge
            Text(entry.method)
                .font(.caption)
                .fontWeight(.bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(methodColor)
                .foregroundColor(.white)
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.host)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(entry.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Status and timing
            VStack(alignment: .trailing, spacing: 2) {
                if let status = entry.statusCode {
                    Text("\(status)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(statusColor(status))
                } else if entry.error != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                if let duration = entry.duration {
                    Text(TrafficEntry.formatDuration(duration))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var methodColor: Color {
        switch entry.method.uppercased() {
        case "GET": return .blue
        case "POST": return .green
        case "PUT": return .orange
        case "DELETE": return .red
        case "PATCH": return .purple
        case "HEAD": return .gray
        case "OPTIONS": return .cyan
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

#Preview {
    List {
        TrafficRowView(entry: TrafficEntry(
            method: "GET",
            url: "https://api.example.com/users",
            host: "api.example.com",
            path: "/users",
            scheme: "https",
            statusCode: 200,
            requestHeaders: [:],
            duration: 0.234
        ))

        TrafficRowView(entry: TrafficEntry(
            method: "POST",
            url: "https://api.example.com/login",
            host: "api.example.com",
            path: "/login",
            scheme: "https",
            statusCode: 401,
            requestHeaders: ["Content-Type": "application/json"],
            duration: 1.5
        ))

        TrafficRowView(entry: TrafficEntry(
            method: "DELETE",
            url: "https://api.example.com/items/123",
            host: "api.example.com",
            path: "/items/123",
            scheme: "https",
            requestHeaders: [:]
        ))
    }
}
