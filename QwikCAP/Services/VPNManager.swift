import Foundation
import NetworkExtension

class VPNManager: ObservableObject {
    static let shared = VPNManager()

    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var statusMessage = "Not connected"

    private var vpnManager: NETunnelProviderManager?

    private init() {
        Task {
            await loadVPNConfiguration()
        }
    }

    // MARK: - VPN Configuration

    func loadVPNConfiguration() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()

            if let existingManager = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == "com.qwikcap.app.tunnel"
            }) {
                vpnManager = existingManager
            } else {
                vpnManager = NETunnelProviderManager()
            }

            await updateStatus()
        } catch {
            await MainActor.run {
                statusMessage = "Failed to load VPN configuration: \(error.localizedDescription)"
            }
        }
    }

    func setupVPNConfiguration() async throws {
        guard let manager = vpnManager else {
            throw VPNError.managerNotInitialized
        }

        let proxyConfig = ProxyConfiguration.shared

        // Configure protocol
        let protocolConfig = NETunnelProviderProtocol()
        protocolConfig.providerBundleIdentifier = "com.qwikcap.app.tunnel"
        protocolConfig.serverAddress = "QwikCAP Local"
        protocolConfig.providerConfiguration = [
            "proxyHost": proxyConfig.proxyHost,
            "proxyPort": proxyConfig.proxyPort,
            "excludedHosts": proxyConfig.excludedHosts,
            "localInspectionEnabled": proxyConfig.localInspectionEnabled,
            "forwardToRemoteProxy": proxyConfig.forwardToRemoteProxy
        ] as [String: Any]

        manager.protocolConfiguration = protocolConfig
        manager.localizedDescription = "QwikCAP Proxy"
        manager.isEnabled = true
        manager.isOnDemandEnabled = false

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        await MainActor.run {
            statusMessage = "VPN configured successfully"
        }
    }

    // MARK: - Connection Control

    func connect() async {
        await MainActor.run {
            isConnecting = true
            statusMessage = "Connecting..."
        }

        do {
            // Ensure configuration is set up
            try await setupVPNConfiguration()

            guard let manager = vpnManager else {
                throw VPNError.managerNotInitialized
            }

            // Start the tunnel
            let session = manager.connection as? NETunnelProviderSession
            try session?.startTunnel(options: nil)

            // Wait for connection
            await waitForConnection()

        } catch {
            await MainActor.run {
                isConnecting = false
                statusMessage = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    func disconnect() async {
        guard let manager = vpnManager else { return }

        await MainActor.run {
            statusMessage = "Disconnecting..."
        }

        let session = manager.connection as? NETunnelProviderSession
        session?.stopTunnel()

        await waitForDisconnection()
    }

    private func waitForConnection() async {
        for _ in 0..<30 {
            await updateStatus()

            if isConnected {
                return
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        await MainActor.run {
            isConnecting = false
            statusMessage = "Connection timed out"
        }
    }

    private func waitForDisconnection() async {
        for _ in 0..<10 {
            await updateStatus()

            if !isConnected {
                return
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func updateStatus() async {
        guard let manager = vpnManager else {
            await MainActor.run {
                isConnected = false
                isConnecting = false
                statusMessage = "VPN not configured"
            }
            return
        }

        let status = manager.connection.status

        let proxyConfig = ProxyConfiguration.shared

        await MainActor.run {
            switch status {
            case .connected:
                isConnected = true
                isConnecting = false
                if proxyConfig.localInspectionEnabled {
                    statusMessage = "Connected - Local traffic inspection active"
                } else {
                    statusMessage = "Connected - Traffic routed through proxy"
                }
            case .connecting:
                isConnected = false
                isConnecting = true
                statusMessage = "Connecting..."
            case .disconnecting:
                isConnected = false
                isConnecting = false
                statusMessage = "Disconnecting..."
            case .disconnected:
                isConnected = false
                isConnecting = false
                statusMessage = "Disconnected"
            case .invalid:
                isConnected = false
                isConnecting = false
                statusMessage = "Invalid configuration"
            case .reasserting:
                isConnected = true
                isConnecting = false
                statusMessage = "Reconnecting..."
            @unknown default:
                statusMessage = "Unknown status"
            }
        }
    }

    // MARK: - Configuration Updates

    func updateProxyConfiguration() async {
        guard vpnManager != nil else { return }

        do {
            try await setupVPNConfiguration()

            // If connected, reconnect to apply new settings
            if isConnected {
                await disconnect()
                try? await Task.sleep(nanoseconds: 500_000_000)
                await connect()
            }
        } catch {
            await MainActor.run {
                statusMessage = "Failed to update configuration: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Message Passing

    func sendMessageToTunnel(_ message: [String: Any]) async -> Data? {
        guard let manager = vpnManager,
              let session = manager.connection as? NETunnelProviderSession else {
            return nil
        }

        do {
            let messageData = try JSONSerialization.data(withJSONObject: message)
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    try session.sendProviderMessage(messageData) { response in
                        continuation.resume(returning: response)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            return nil
        }
    }
}

// MARK: - Errors

enum VPNError: Error, LocalizedError {
    case managerNotInitialized
    case configurationFailed(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .managerNotInitialized: return "VPN manager not initialized"
        case .configurationFailed(let msg): return "Configuration failed: \(msg)"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        }
    }
}
