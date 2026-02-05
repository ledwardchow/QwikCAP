import SwiftUI

struct CertificateView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @EnvironmentObject var certificateManager: CertificateManager
    @EnvironmentObject var proxyConfig: ProxyConfiguration

    @State private var showingExportSheet = false
    @State private var exportedCertData: Data?
    @State private var showingDeleteAlert = false
    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Local CA Certificate Section
                    if proxyConfig.localInspectionEnabled {
                        localCertificateSection
                    }

                    // Burp Certificate Section (when not using local inspection or forwarding)
                    if !proxyConfig.localInspectionEnabled || proxyConfig.forwardToRemoteProxy {
                        burpCertificateSection
                    }

                    // Show local cert section even when disabled, but collapsed
                    if !proxyConfig.localInspectionEnabled {
                        collapsedLocalCertSection
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Certificate")
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred")
        }
        .alert("Delete Certificate", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteCertificate()
            }
        } message: {
            Text("Are you sure you want to delete the local CA certificate? You'll need to generate a new one and reinstall it to use local traffic inspection.")
        }
        .sheet(isPresented: $showingExportSheet) {
            if let data = exportedCertData {
                CertificateExportSheet(certData: data)
            }
        }
    }

    // MARK: - Local Certificate Section

    private var localCertificateSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.blue)
                Text("Local CA Certificate")
                    .font(.headline)
            }

            if certificateManager.hasCACertificate {
                // Certificate exists
                VStack(alignment: .leading, spacing: 12) {
                    if let info = certificateManager.certificateInfo {
                        CertificateInfoCard(info: info)
                    }

                    HStack(spacing: 12) {
                        Button(action: exportCertificate) {
                            Label("Export", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive, action: { showingDeleteAlert = true }) {
                            Label("Delete", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    // Installation guide
                    localCertInstallGuide
                }
            } else {
                // No certificate - show generation option
                VStack(spacing: 16) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)

                    Text("No CA Certificate")
                        .font(.headline)

                    Text("Generate a CA certificate to enable HTTPS traffic inspection.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button(action: generateCertificate) {
                        if certificateManager.isGenerating {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Label("Generate Certificate", systemImage: "plus.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(certificateManager.isGenerating)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }

    private var localCertInstallGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Installation Steps")
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                InstallStep(number: 1, text: "Export the certificate using the button above")
                InstallStep(number: 2, text: "Open the exported file to download the profile")
                InstallStep(number: 3, text: "Go to Settings > General > VPN & Device Management")
                InstallStep(number: 4, text: "Install the QwikCAP CA profile")
                InstallStep(number: 5, text: "Go to Settings > General > About > Certificate Trust Settings")
                InstallStep(number: 6, text: "Enable full trust for QwikCAP Root CA")
            }
        }
        .padding()
        .background(Color.blue.opacity(0.05))
        .cornerRadius(8)
    }

    private var collapsedLocalCertSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lock.shield")
                    .foregroundColor(.secondary)
                Text("Local CA Certificate")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Disabled")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Enable Local Traffic Inspection in Settings to manage CA certificates for HTTPS inspection.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }

    // MARK: - Burp Certificate Section

    private var burpCertificateSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: vpnManager.isConnected ? "checkmark.shield.fill" : "shield.slash.fill")
                    .foregroundColor(vpnManager.isConnected ? .green : .orange)

                Text("Burp Suite Certificate")
                    .font(.headline)
            }

            Text(vpnManager.isConnected ?
                 "VPN connected - You can now install the Burp certificate" :
                 "Connect the VPN first to install Burp's certificate")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Setup guide
            VStack(alignment: .leading, spacing: 12) {
                CertStepCard(
                    stepNumber: 1,
                    title: "Connect VPN",
                    description: "Enable the VPN from the Dashboard to route traffic through Burp Suite.",
                    icon: "network",
                    isCompleted: vpnManager.isConnected
                )

                CertStepCard(
                    stepNumber: 2,
                    title: "Open Certificate URL",
                    description: "With VPN connected, open Safari and navigate to http://burp to download the certificate.",
                    icon: "safari",
                    isCompleted: false,
                    actionTitle: vpnManager.isConnected ? "Open http://burp" : nil,
                    action: vpnManager.isConnected ? {
                        if let url = URL(string: "http://burp") {
                            UIApplication.shared.open(url)
                        }
                    } : nil
                )

                CertStepCard(
                    stepNumber: 3,
                    title: "Download Certificate",
                    description: "On the Burp page, tap 'CA Certificate' to download the certificate file.",
                    icon: "arrow.down.circle",
                    isCompleted: false
                )

                CertStepCard(
                    stepNumber: 4,
                    title: "Install Profile",
                    description: "Go to Settings > General > VPN & Device Management and install the downloaded profile.",
                    icon: "gear",
                    isCompleted: false,
                    actionTitle: "Open Settings",
                    action: {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                )

                CertStepCard(
                    stepNumber: 5,
                    title: "Trust Certificate",
                    description: "Go to Settings > General > About > Certificate Trust Settings and enable full trust for PortSwigger CA.",
                    icon: "checkmark.shield",
                    isCompleted: false
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }

    // MARK: - Actions

    private func generateCertificate() {
        Task {
            do {
                try await certificateManager.generateCACertificate()
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    private func exportCertificate() {
        do {
            exportedCertData = try certificateManager.exportCertificateAsDER()
            showingExportSheet = true
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func deleteCertificate() {
        do {
            try certificateManager.deleteCACertificate()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

// MARK: - Certificate Info Card

struct CertificateInfoCard: View {
    let info: CertificateInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                Text(info.commonName)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Organization:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(info.organization)
                        .font(.caption)
                }

                GridRow {
                    Text("Valid Until:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(info.validUntil, style: .date)
                        .font(.caption)
                }

                GridRow {
                    Text("Fingerprint:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(info.fingerprint)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                }
            }
        }
        .padding()
        .background(Color.green.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Install Step

struct InstallStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.blue)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Certificate Export Sheet

struct CertificateExportSheet: View {
    let certData: Data
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "doc.badge.arrow.up")
                    .font(.system(size: 64))
                    .foregroundColor(.blue)

                Text("Export Certificate")
                    .font(.headline)

                Text("Save the certificate file and open it to install the profile on your device.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                ShareLink(
                    item: CertificateFile(data: certData),
                    preview: SharePreview("QwikCAP CA Certificate", image: Image(systemName: "lock.shield"))
                ) {
                    Label("Save Certificate", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 40)
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Certificate File for Sharing

struct CertificateFile: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .x509Certificate) { file in
            file.data
        }
    }
}



#Preview {
    CertificateView()
        .environmentObject(VPNManager.shared)
        .environmentObject(CertificateManager.shared)
        .environmentObject(ProxyConfiguration.shared)
}
