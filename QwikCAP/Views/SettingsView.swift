import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var proxyConfig: ProxyConfiguration
    @EnvironmentObject var vpnManager: VPNManager

    var body: some View {
        NavigationView {
            Form {
                // Local Traffic Inspection
                Section {
                    Toggle("Local Traffic Inspection", isOn: $proxyConfig.localInspectionEnabled)

                    if proxyConfig.localInspectionEnabled {
                        Toggle("Forward to Remote Proxy", isOn: $proxyConfig.forwardToRemoteProxy)
                            .padding(.leading, 16)
                    }
                } header: {
                    Text("Traffic Inspection")
                } footer: {
                    if proxyConfig.localInspectionEnabled {
                        Text("Traffic is captured locally for inspection. Enable forwarding to also send traffic to the remote proxy.")
                    } else {
                        Text("Enable to capture and inspect HTTP/HTTPS traffic locally.")
                    }
                }

                // Proxy Configuration (shown when forwarding or not using local inspection)
                if !proxyConfig.localInspectionEnabled || proxyConfig.forwardToRemoteProxy {
                    Section {
                        HStack {
                            Text("IP Address")
                            Spacer()
                            TextField("e.g., 192.168.1.100", text: $proxyConfig.proxyHost)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                                .keyboardType(.numbersAndPunctuation)
                                .autocapitalization(.none)
                        }

                        HStack {
                            Text("Port")
                            Spacer()
                            TextField("8080", text: Binding(
                                get: { String(proxyConfig.proxyPort) },
                                set: { proxyConfig.proxyPort = Int($0) ?? 8080 }
                            ))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .keyboardType(.numberPad)
                        }
                    } header: {
                        Text(proxyConfig.localInspectionEnabled ? "Remote Proxy Target" : "Proxy Target")
                    } footer: {
                        Text("Enter the IP address and port of the proxy server (e.g., Burp Suite).")
                    }
                }

                // Host Filtering
                Section {
                    NavigationLink(destination: HostListEditor(
                        title: "Excluded Hosts",
                        hosts: $proxyConfig.excludedHosts
                    )) {
                        HStack {
                            Text("Excluded Hosts")
                            Spacer()
                            Text("\(proxyConfig.excludedHosts.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Host Filtering")
                } footer: {
                    Text("Excluded hosts bypass the proxy and connect directly.")
                }

                // Actions
                Section {
                    Button(action: {
                        Task {
                            await vpnManager.updateProxyConfiguration()
                        }
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Apply Configuration")
                        }
                    }
                    .disabled(!vpnManager.isConnected)
                } header: {
                    Text("Actions")
                } footer: {
                    Text("Apply configuration changes to the active VPN connection.")
                }

                // About
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Mode")
                        Spacer()
                        Text(proxyConfig.effectiveProxyMode.description)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct HostListEditor: View {
    let title: String
    @Binding var hosts: [String]

    @State private var newHost = ""

    var body: some View {
        List {
            Section {
                ForEach(hosts, id: \.self) { host in
                    Text(host)
                }
                .onDelete(perform: deleteHost)
            }

            Section {
                HStack {
                    TextField("e.g., *.example.com", text: $newHost)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()

                    Button("Add") {
                        if !newHost.isEmpty && !hosts.contains(newHost) {
                            hosts.append(newHost)
                            newHost = ""
                        }
                    }
                    .disabled(newHost.isEmpty)
                }
            } footer: {
                Text("Use * as wildcard. Example: *.apple.com matches api.apple.com")
            }
        }
        .navigationTitle(title)
        .toolbar {
            EditButton()
        }
    }

    private func deleteHost(at offsets: IndexSet) {
        hosts.remove(atOffsets: offsets)
    }
}

#Preview {
    SettingsView()
        .environmentObject(ProxyConfiguration.shared)
        .environmentObject(VPNManager.shared)
}
