import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @EnvironmentObject var proxyConfig: ProxyConfiguration

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            MainDashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "gauge")
                }
                .tag(0)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(1)

            CertificateGuideView()
                .tabItem {
                    Label("Certificate", systemImage: "lock.shield")
                }
                .tag(2)
        }
        .accentColor(.blue)
    }
}

struct MainDashboardView: View {
    @EnvironmentObject var vpnManager: VPNManager
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

                    Spacer()
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("QwikCAP")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(VPNManager.shared)
        .environmentObject(ProxyConfiguration.shared)
}
