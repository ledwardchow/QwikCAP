import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @EnvironmentObject var proxyConfig: ProxyConfiguration
    @EnvironmentObject var trafficStore: TrafficStore
    @EnvironmentObject var certificateManager: CertificateManager

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
                    Label("Traffic", systemImage: "list.bullet.rectangle")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(2)

            CertificateView()
                .tabItem {
                    Label("Certificate", systemImage: "lock.shield")
                }
                .tag(3)
        }
        .accentColor(.blue)
    }
}

struct MainDashboardView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @EnvironmentObject var proxyConfig: ProxyConfiguration
    @EnvironmentObject var trafficStore: TrafficStore

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
                                Text(vpnManager.isConnected ? "VPN Active" : "Not Connected")
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
                                Text(vpnManager.isConnected ? "Disconnect" : "Connect")
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

                    // Mode Card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: proxyConfig.localInspectionEnabled ? "eye.fill" : "server.rack")
                                .foregroundColor(.blue)
                            Text("Current Mode")
                                .font(.headline)
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(proxyConfig.effectiveProxyMode.description)
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                if proxyConfig.localInspectionEnabled {
                                    Text("Traffic captured locally for inspection")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else if proxyConfig.isConfigured {
                                    Text("Traffic forwarded to \(proxyConfig.proxyHost):\(proxyConfig.proxyPort)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()

                            if proxyConfig.localInspectionEnabled {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(radius: 2)

                    // Traffic Stats Card (when local inspection enabled)
                    if proxyConfig.localInspectionEnabled {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "chart.bar.fill")
                                    .foregroundColor(.blue)
                                Text("Traffic Stats")
                                    .font(.headline)
                            }

                            HStack(spacing: 20) {
                                StatItem(
                                    title: "Requests",
                                    value: "\(trafficStore.totalCount)",
                                    icon: "arrow.up.arrow.down"
                                )

                                StatItem(
                                    title: "Errors",
                                    value: "\(trafficStore.entries.filter { $0.isError }.count)",
                                    icon: "exclamationmark.triangle",
                                    color: .red
                                )
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .shadow(radius: 2)
                    }

                    // Proxy Configuration Card (when not using local inspection)
                    if !proxyConfig.localInspectionEnabled {
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
                                    Text(String(proxyConfig.proxyPort))
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
                    }

                    Spacer()
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("QwikCAP")
        }
    }
}

struct StatItem: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .blue

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    ContentView()
        .environmentObject(VPNManager.shared)
        .environmentObject(ProxyConfiguration.shared)
        .environmentObject(TrafficStore.shared)
        .environmentObject(CertificateManager.shared)
}
