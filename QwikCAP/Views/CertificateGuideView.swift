import SwiftUI

struct CertificateGuideView: View {
    @EnvironmentObject var certificateManager: CertificateManager

    @State private var currentStep = 0
    @State private var isGenerating = false
    @State private var showCertificateInfo = false

    let steps = [
        GuideStep(
            title: "Generate Certificate",
            description: "Create a CA certificate that will be used to intercept HTTPS traffic.",
            icon: "key.fill",
            action: "Generate Certificate"
        ),
        GuideStep(
            title: "Export Certificate",
            description: "Save the certificate to your device so you can install it.",
            icon: "square.and.arrow.up",
            action: "Export Certificate"
        ),
        GuideStep(
            title: "Install Profile",
            description: "Open Settings > General > VPN & Device Management and install the QwikCAP profile.",
            icon: "iphone.badge.play",
            action: "Open Settings"
        ),
        GuideStep(
            title: "Trust Certificate",
            description: "Go to Settings > General > About > Certificate Trust Settings and enable full trust for QwikCAP Root CA.",
            icon: "checkmark.shield.fill",
            action: "Open Trust Settings"
        )
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Status card
                    VStack(spacing: 16) {
                        Image(systemName: statusIcon)
                            .font(.system(size: 56))
                            .foregroundColor(statusColor)

                        Text(statusTitle)
                            .font(.headline)

                        Text(certificateManager.statusMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        // Show "I've Trusted the Certificate" button when appropriate
                        if certificateManager.detailedStatus == .trustPending ||
                           certificateManager.detailedStatus == .exported {
                            Button(action: {
                                certificateManager.markCertificateAsTrusted()
                            }) {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text("I've Installed & Trusted the Certificate")
                                }
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                            .padding(.top, 8)
                        }

                        // Show reset button if certificate is marked as trusted
                        if certificateManager.detailedStatus == .ready {
                            Button(action: {
                                certificateManager.resetTrustStatus()
                            }) {
                                Text("Reset Trust Status")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(radius: 2)

                    // Certificate info
                    if !certificateManager.certificateFingerprint.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Certificate Info")
                                    .font(.headline)
                                Spacer()
                                Button(action: { showCertificateInfo.toggle() }) {
                                    Image(systemName: showCertificateInfo ? "chevron.up" : "chevron.down")
                                }
                            }

                            if showCertificateInfo {
                                VStack(alignment: .leading, spacing: 8) {
                                    InfoRow(label: "Common Name", value: "QwikCAP Root CA")
                                    InfoRow(label: "Organization", value: "QwikCAP")

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("SHA-256 Fingerprint")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text(certificateManager.certificateFingerprint)
                                            .font(.system(.caption2, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .shadow(radius: 2)
                    }

                    // Setup guide
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Setup Guide")
                            .font(.headline)

                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            StepCard(
                                step: step,
                                stepNumber: index + 1,
                                isActive: index == currentStep,
                                isCompleted: index < currentStep,
                                action: {
                                    performStepAction(index)
                                }
                            )
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(radius: 2)

                    // Troubleshooting
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Troubleshooting")
                            .font(.headline)

                        TroubleshootingItem(
                            question: "Certificate not showing in Settings?",
                            answer: "Make sure you exported the certificate and opened it on this device. Try exporting again via AirDrop to yourself."
                        )

                        TroubleshootingItem(
                            question: "HTTPS sites not loading?",
                            answer: "Ensure you've enabled 'Full Trust' for the certificate in Certificate Trust Settings."
                        )

                        TroubleshootingItem(
                            question: "How do I remove the certificate?",
                            answer: "Go to Settings > General > VPN & Device Management, tap the QwikCAP profile, and select 'Remove Profile'."
                        )
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(radius: 2)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Certificate Setup")
            .onAppear {
                certificateManager.checkCertificateStatus()
            }
        }
    }

    // MARK: - Computed Properties for Status

    private var statusIcon: String {
        switch certificateManager.detailedStatus {
        case .notGenerated:
            return "shield.slash.fill"
        case .generated, .exported:
            return "shield.fill"
        case .installationPending, .trustPending:
            return "exclamationmark.shield.fill"
        case .ready:
            return "checkmark.shield.fill"
        }
    }

    private var statusColor: Color {
        switch certificateManager.detailedStatus {
        case .notGenerated:
            return .red
        case .generated, .exported, .installationPending, .trustPending:
            return .orange
        case .ready:
            return .green
        }
    }

    private var statusTitle: String {
        switch certificateManager.detailedStatus {
        case .notGenerated:
            return "Certificate Setup Required"
        case .generated:
            return "Certificate Generated"
        case .exported:
            return "Certificate Exported"
        case .installationPending:
            return "Install Profile in Settings"
        case .trustPending:
            return "Enable Certificate Trust"
        case .ready:
            return "Certificate Ready"
        }
    }

    private func performStepAction(_ stepIndex: Int) {
        switch stepIndex {
        case 0:
            // Generate certificate
            isGenerating = true
            Task {
                do {
                    let _ = try await certificateManager.generateCACertificate()
                    await MainActor.run {
                        isGenerating = false
                        currentStep = 1
                    }
                } catch {
                    await MainActor.run {
                        isGenerating = false
                    }
                }
            }

        case 1:
            // Export certificate
            certificateManager.exportCertificateForInstallation()
            currentStep = 2

        case 2:
            // Open settings
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            currentStep = 3

        case 3:
            // Open trust settings (this URL might not work on all iOS versions)
            if let url = URL(string: "App-Prefs:root=General&path=About/CERT_TRUST_SETTINGS") {
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url)
                } else if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsUrl)
                }
            }

        default:
            break
        }
    }
}

struct GuideStep {
    let title: String
    let description: String
    let icon: String
    let action: String
}

struct StepCard: View {
    let step: GuideStep
    let stepNumber: Int
    let isActive: Bool
    let isCompleted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Step number/checkmark
            ZStack {
                Circle()
                    .fill(isCompleted ? Color.green : (isActive ? Color.blue : Color.gray.opacity(0.3)))
                    .frame(width: 32, height: 32)

                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                } else {
                    Text("\(stepNumber)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(isActive ? .white : .gray)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: step.icon)
                        .foregroundColor(isActive ? .blue : .gray)

                    Text(step.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }

                Text(step.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if isActive {
                    Button(action: action) {
                        Text(step.action)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding()
        .background(isActive ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(8)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
        }
    }
}

struct TroubleshootingItem: View {
    let question: String
    let answer: String

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    Text(question)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if isExpanded {
                Text(answer)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 8)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    CertificateGuideView()
        .environmentObject(CertificateManager.shared)
}
