import SwiftUI

struct CertificateGuideView: View {
    @EnvironmentObject var vpnManager: VPNManager

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Status card
                    VStack(spacing: 16) {
                        Image(systemName: vpnManager.isConnected ? "checkmark.shield.fill" : "shield.slash.fill")
                            .font(.system(size: 56))
                            .foregroundColor(vpnManager.isConnected ? .green : .orange)

                        Text(vpnManager.isConnected ? "VPN Connected" : "Connect VPN First")
                            .font(.headline)

                        Text(vpnManager.isConnected ?
                             "You can now install the Burp certificate" :
                             "Connect the VPN before installing the certificate")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(radius: 2)

                    // Setup guide
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Certificate Setup")
                            .font(.headline)

                        CertStepCard(
                            stepNumber: 1,
                            title: "Connect VPN",
                            description: "Enable the VPN from the Dashboard tab to route traffic through Burp Suite.",
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
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(radius: 2)

                    // Troubleshooting
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Troubleshooting")
                            .font(.headline)

                        TroubleshootingItem(
                            question: "http://burp not loading?",
                            answer: "Make sure the VPN is connected and your Burp proxy is running and listening on the configured IP/port."
                        )

                        TroubleshootingItem(
                            question: "HTTPS sites not loading after certificate install?",
                            answer: "Ensure you've enabled 'Full Trust' for PortSwigger CA in Settings > General > About > Certificate Trust Settings."
                        )

                        TroubleshootingItem(
                            question: "How do I remove the certificate?",
                            answer: "Go to Settings > General > VPN & Device Management, tap the PortSwigger CA profile, and select 'Remove Profile'."
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
        }
    }
}

struct CertStepCard: View {
    let stepNumber: Int
    let title: String
    let description: String
    let icon: String
    let isCompleted: Bool
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Step number/checkmark
            ZStack {
                Circle()
                    .fill(isCompleted ? Color.green : Color.gray.opacity(0.3))
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
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(isCompleted ? .green : .blue)

                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .strikethrough(isCompleted)
                        .foregroundColor(isCompleted ? .secondary : .primary)
                }

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let actionTitle = actionTitle, let action = action {
                    Button(action: action) {
                        Text(actionTitle)
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
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
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
        .environmentObject(VPNManager.shared)
}
