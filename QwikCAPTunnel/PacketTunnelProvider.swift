import NetworkExtension
import os.log

class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.qwikcap.tunnel", category: "PacketTunnel")

    private var proxyHost: String = ""
    private var proxyPort: Int = 8080
    private var excludedHosts: [String] = []

    private let appGroupID = "group.com.qwikcap.app"

    // Tunnel virtual IP
    private let tunnelAddress = "10.8.0.1"

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("Starting tunnel...", log: log, type: .info)

        // Load configuration
        loadConfiguration()

        os_log("Configuration loaded - Proxy: %{public}@:%{public}d", log: log, type: .info, proxyHost, proxyPort)

        // Configure tunnel network settings
        let tunnelNetworkSettings = createTunnelSettings()

        setTunnelNetworkSettings(tunnelNetworkSettings) { [weak self] error in
            if let error = error {
                os_log("Failed to set tunnel settings: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }

            os_log("Tunnel settings applied successfully", log: self?.log ?? .default, type: .info)
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("Stopping tunnel with reason: %{public}d", log: log, type: .info, reason.rawValue)
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let action = message["action"] as? String else {
            completionHandler?(nil)
            return
        }

        switch action {
        case "updateConfig":
            loadConfiguration()
            // Re-apply tunnel settings with new configuration
            let tunnelNetworkSettings = createTunnelSettings()
            setTunnelNetworkSettings(tunnelNetworkSettings) { _ in
                completionHandler?(nil)
            }

        default:
            completionHandler?(nil)
        }
    }

    // MARK: - Configuration

    private func loadConfiguration() {
        os_log("Loading configuration...", log: log, type: .info)

        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol else {
            os_log("Protocol configuration is not NETunnelProviderProtocol", log: log, type: .error)
            return
        }

        guard let config = protocolConfig.providerConfiguration else {
            os_log("No provider configuration found", log: log, type: .error)
            return
        }

        proxyHost = config["proxyHost"] as? String ?? ""
        proxyPort = config["proxyPort"] as? Int ?? 8080
        excludedHosts = config["excludedHosts"] as? [String] ?? []

        os_log("Configuration loaded - Proxy: %{public}@:%{public}d", log: log, type: .info, proxyHost, proxyPort)
    }

    // MARK: - Tunnel Network Settings

    private func createTunnelSettings() -> NEPacketTunnelNetworkSettings {
        let tunnelSubnetMask = "255.255.255.0"
        let tunnelRemoteAddress = "10.8.0.2"

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)

        // IPv4 settings
        let ipv4Settings = NEIPv4Settings(addresses: [tunnelAddress], subnetMasks: [tunnelSubnetMask])
        ipv4Settings.includedRoutes = []
        ipv4Settings.excludedRoutes = []
        settings.ipv4Settings = ipv4Settings

        // DNS settings
        let dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings

        // Proxy settings
        let proxySettings = NEProxySettings()

        if !proxyHost.isEmpty && proxyPort > 0 {
            proxySettings.httpEnabled = true
            proxySettings.httpServer = NEProxyServer(address: proxyHost, port: proxyPort)

            proxySettings.httpsEnabled = true
            proxySettings.httpsServer = NEProxyServer(address: proxyHost, port: proxyPort)

            os_log("Proxy configured: %{public}@:%{public}d", log: log, type: .info, proxyHost, proxyPort)
        } else {
            proxySettings.httpEnabled = false
            proxySettings.httpsEnabled = false
            os_log("No proxy configured", log: log, type: .info)
        }

        proxySettings.matchDomains = [""]

        // Exclude certain domains from proxy
        var exclusionList = excludedHosts
        exclusionList.append("localhost")
        exclusionList.append("*.local")
        exclusionList.append("*.apple.com")
        exclusionList.append("*.icloud.com")
        proxySettings.exceptionList = exclusionList

        settings.proxySettings = proxySettings
        settings.mtu = 1500

        return settings
    }
}

// MARK: - Tunnel Errors

enum TunnelError: Error, LocalizedError {
    case internalError
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .internalError: return "Internal tunnel error"
        case .configurationFailed: return "Failed to configure tunnel"
        }
    }
}
