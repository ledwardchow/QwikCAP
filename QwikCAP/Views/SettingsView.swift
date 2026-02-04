import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var proxyConfig: ProxyConfiguration
    @EnvironmentObject var vpnManager: VPNManager

    @State private var showPresetPicker = false
    @State private var showExcludedHostsEditor = false
    @State private var showIncludedHostsEditor = false
    @State private var newHost = ""

    var body: some View {
        NavigationView {
            Form {
                // Proxy Configuration
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
                        TextField("8080", value: $proxyConfig.proxyPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .keyboardType(.numberPad)
                    }

                    Button("Apply Preset...") {
                        showPresetPicker = true
                    }
                } header: {
                    Text("Proxy Target (Burp Suite)")
                } footer: {
                    Text("Enter the IP address of the machine running Burp Suite. Use your computer's local IP if Burp is on the same network.")
                }

                // Capture Options
                Section {
                    Toggle("HTTP Traffic", isOn: $proxyConfig.captureHTTP)
                    Toggle("HTTPS Traffic", isOn: $proxyConfig.captureHTTPS)
                    Toggle("WebSocket Traffic", isOn: $proxyConfig.captureWebSocket)
                    Toggle("Transparent Proxy Mode", isOn: $proxyConfig.transparentMode)
                } header: {
                    Text("Capture Options")
                } footer: {
                    Text("Transparent mode forwards traffic without modifying it. Disable for debugging.")
                }

                // Logging Options
                Section {
                    Toggle("Log Request Bodies", isOn: $proxyConfig.logRequestBodies)
                    Toggle("Log Response Bodies", isOn: $proxyConfig.logResponseBodies)

                    HStack {
                        Text("Max Body Size")
                        Spacer()
                        Picker("", selection: $proxyConfig.maxBodySize) {
                            Text("100 KB").tag(100 * 1024)
                            Text("500 KB").tag(500 * 1024)
                            Text("1 MB").tag(1024 * 1024)
                            Text("5 MB").tag(5 * 1024 * 1024)
                            Text("10 MB").tag(10 * 1024 * 1024)
                        }
                        .pickerStyle(.menu)
                    }
                } header: {
                    Text("Logging")
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

                    NavigationLink(destination: HostListEditor(
                        title: "Included Hosts Only",
                        hosts: $proxyConfig.includedHosts
                    )) {
                        HStack {
                            Text("Included Hosts Only")
                            Spacer()
                            Text(proxyConfig.includedHosts.isEmpty ? "All" : "\(proxyConfig.includedHosts.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Host Filtering")
                } footer: {
                    Text("Excluded hosts bypass the proxy. If 'Included Hosts Only' has entries, only those hosts are captured.")
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

                    Button(role: .destructive, action: {
                        TrafficLogger.shared.clearLog()
                    }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear Traffic Log")
                        }
                    }
                } header: {
                    Text("Actions")
                }

                // Export/Import
                Section {
                    Button(action: exportConfiguration) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export Configuration")
                        }
                    }

                    Button(action: importConfiguration) {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Import Configuration")
                        }
                    }
                } header: {
                    Text("Configuration")
                }

                // About
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    Link(destination: URL(string: "https://portswigger.net/burp")!) {
                        HStack {
                            Text("Burp Suite Documentation")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Select Preset", isPresented: $showPresetPicker) {
                Button("Burp Suite (Default)") {
                    proxyConfig.applyBurpSuitePreset()
                }
                Button("Charles Proxy") {
                    proxyConfig.applyCharlesProxyPreset()
                }
                Button("mitmproxy") {
                    proxyConfig.applyMitmProxyPreset()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func exportConfiguration() {
        guard let data = proxyConfig.exportConfiguration() else { return }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("qwikcap_config.json")
        try? data.write(to: tempURL)

        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }

    private func importConfiguration() {
        // Would need document picker - simplified for now
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
