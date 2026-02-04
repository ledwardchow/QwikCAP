import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @EnvironmentObject var certificateManager: CertificateManager
    @EnvironmentObject var trafficLogger: TrafficLogger
    @EnvironmentObject var proxyConfig: ProxyConfiguration

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            MainDashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "gauge")
                }
                .tag(0)

            TrafficListView()
                .tabItem {
                    Label("Traffic", systemImage: "arrow.left.arrow.right")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(2)

            CertificateGuideView()
                .tabItem {
                    Label("Certificate", systemImage: "lock.shield")
                }
                .tag(3)

            DebugLogView()
                .tabItem {
                    Label("Debug", systemImage: "ladybug")
                }
                .tag(4)
        }
        .accentColor(.blue)
    }
}

struct MainDashboardView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @EnvironmentObject var certificateManager: CertificateManager
    @EnvironmentObject var trafficLogger: TrafficLogger
    @EnvironmentObject var proxyConfig: ProxyConfiguration

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Status Card
                    VStack(spacing: 16) {
                        HStack {
                            Image(systemName: vpnManager.isConnected ? "checkmark.shield.fill" : "shield.slash")
                                .font(.system(size: 48))
                                .foregroundColor(vpnManager.isConnected ? .green : .gray)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(vpnManager.isConnected ? "Capturing Traffic" : "Not Connected")
                                    .font(.headline)
                                Text(vpnManager.statusMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }

                        Button(action: {
                            Task {
                                if vpnManager.isConnected {
                                    await vpnManager.disconnect()
                                } else {
                                    await vpnManager.connect()
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: vpnManager.isConnected ? "stop.fill" : "play.fill")
                                Text(vpnManager.isConnected ? "Stop Capture" : "Start Capture")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(vpnManager.isConnected ? Color.red : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(vpnManager.isConnecting)
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(radius: 2)

                    // Proxy Configuration Card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "server.rack")
                                .foregroundColor(.blue)
                            Text("Proxy Target")
                                .font(.headline)
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("IP Address")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(proxyConfig.proxyHost.isEmpty ? "Not configured" : proxyConfig.proxyHost)
                                    .font(.subheadline)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Port")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(proxyConfig.proxyPort)")
                                    .font(.subheadline)
                            }
                        }

                        if proxyConfig.proxyHost.isEmpty {
                            Text("Configure proxy settings to forward traffic to Burp Suite")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(radius: 2)

                    // Statistics Card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "chart.bar.fill")
                                .foregroundColor(.purple)
                            Text("Statistics")
                                .font(.headline)
                        }

                        HStack(spacing: 20) {
                            StatBox(title: "HTTP", count: trafficLogger.httpCount, color: .blue)
                            StatBox(title: "HTTPS", count: trafficLogger.httpsCount, color: .green)
                            StatBox(title: "WebSocket", count: trafficLogger.wsCount, color: .orange)
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(radius: 2)

                    // Certificate Status Card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: certificateStatusIcon)
                                .foregroundColor(certificateStatusColor)
                            Text("CA Certificate")
                                .font(.headline)
                            Spacer()
                            Text(certificateStatusText)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(certificateStatusColor.opacity(0.2))
                                .foregroundColor(certificateStatusColor)
                                .cornerRadius(4)
                        }

                        Text(certificateManager.statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if certificateManager.detailedStatus != .ready {
                            if certificateManager.detailedStatus == .notGenerated {
                                Button(action: {
                                    Task {
                                        do {
                                            let _ = try await certificateManager.generateCACertificate()
                                        } catch {
                                            print("Failed to generate certificate: \(error)")
                                        }
                                    }
                                }) {
                                    Text("Generate Certificate")
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                                .buttonStyle(.bordered)
                            } else if certificateManager.detailedStatus == .generated {
                                Button(action: {
                                    certificateManager.exportCertificateForInstallation()
                                }) {
                                    Text("Export Certificate")
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button(action: {
                                    certificateManager.markCertificateAsTrusted()
                                }) {
                                    Text("I've Trusted the Certificate")
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(radius: 2)

                    Spacer()
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("QwikCAP")
            .onAppear {
                certificateManager.checkCertificateStatus()
            }
        }
    }

    private var certificateStatusIcon: String {
        switch certificateManager.detailedStatus {
        case .notGenerated: return "xmark.shield"
        case .generated, .exported: return "shield.fill"
        case .installationPending, .trustPending: return "exclamationmark.shield"
        case .ready: return "checkmark.shield.fill"
        }
    }

    private var certificateStatusColor: Color {
        switch certificateManager.detailedStatus {
        case .notGenerated: return .red
        case .generated, .exported, .installationPending, .trustPending: return .orange
        case .ready: return .green
        }
    }

    private var certificateStatusText: String {
        switch certificateManager.detailedStatus {
        case .notGenerated: return "Not Generated"
        case .generated: return "Generated"
        case .exported: return "Exported"
        case .installationPending: return "Install Pending"
        case .trustPending: return "Trust Pending"
        case .ready: return "Ready"
        }
    }
}

struct StatBox: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

#Preview {
    ContentView()
        .environmentObject(VPNManager.shared)
        .environmentObject(CertificateManager.shared)
        .environmentObject(TrafficLogger.shared)
        .environmentObject(ProxyConfiguration.shared)
}
