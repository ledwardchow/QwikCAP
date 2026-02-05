import NetworkExtension
import os.log

class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.qwikcap.tunnel", category: "PacketTunnel")

    private var proxyHost: String = ""
    private var proxyPort: Int = 8080
    private var excludedHosts: [String] = []

    // Local inspection settings
    private var localInspectionEnabled: Bool = false
    private var forwardToRemoteProxy: Bool = false

    private let appGroupID = "group.com.qwikcap.app"

    // Local proxy server components
    private var localProxyServer: LocalProxyServer?
    private var trafficRecorder: TrafficRecorder?
    private var tlsInterceptor: TLSInterceptor?

    // Local proxy port
    private let localProxyPort: UInt16 = 9090

    // Tunnel virtual IP
    private let tunnelAddress = "10.8.0.1"

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("Starting tunnel...", log: log, type: .info)

        // Load configuration
        loadConfiguration()

        os_log("Configuration loaded - Local inspection: %{public}@, Forward: %{public}@, Proxy: %{public}@:%{public}d",
               log: log, type: .info,
               localInspectionEnabled ? "YES" : "NO",
               forwardToRemoteProxy ? "YES" : "NO",
               proxyHost, proxyPort)

        // Start local proxy if inspection enabled
        if localInspectionEnabled {
            do {
                try startLocalProxy()
            } catch {
                os_log("Failed to start local proxy: %{public}@", log: log, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }
        }

        // Configure tunnel network settings
        let tunnelNetworkSettings = createTunnelSettings()

        setTunnelNetworkSettings(tunnelNetworkSettings) { [weak self] error in
            if let error = error {
                os_log("Failed to set tunnel settings: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                self?.stopLocalProxy()
                completionHandler(error)
                return
            }

            os_log("Tunnel settings applied successfully", log: self?.log ?? .default, type: .info)
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("Stopping tunnel with reason: %{public}d", log: log, type: .info, reason.rawValue)

        stopLocalProxy()

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

            // Restart local proxy if needed
            if localInspectionEnabled && localProxyServer == nil {
                try? startLocalProxy()
            } else if !localInspectionEnabled && localProxyServer != nil {
                stopLocalProxy()
            }

            // Update local proxy configuration
            localProxyServer?.forwardToRemoteProxy = forwardToRemoteProxy
            localProxyServer?.remoteProxyHost = proxyHost
            localProxyServer?.remoteProxyPort = proxyPort

            // Re-apply tunnel settings with new configuration
            let tunnelNetworkSettings = createTunnelSettings()
            setTunnelNetworkSettings(tunnelNetworkSettings) { _ in
                completionHandler?(nil)
            }

        case "clearTraffic":
            trafficRecorder?.clearAllTraffic()
            completionHandler?(nil)

        default:
            completionHandler?(nil)
        }
    }

    // MARK: - Local Proxy Management

    private func startLocalProxy() throws {
        os_log("Starting local proxy server...", log: log, type: .info)

        // Initialize TLS interceptor
        tlsInterceptor = TLSInterceptor()

        // Initialize traffic recorder
        trafficRecorder = TrafficRecorder()

        // Initialize and start local proxy server
        localProxyServer = LocalProxyServer(port: localProxyPort)
        localProxyServer?.delegate = self
        localProxyServer?.tlsInterceptor = tlsInterceptor
        localProxyServer?.forwardToRemoteProxy = forwardToRemoteProxy
        localProxyServer?.remoteProxyHost = proxyHost
        localProxyServer?.remoteProxyPort = proxyPort

        try localProxyServer?.start()

        os_log("Local proxy server started on port %{public}d", log: log, type: .info, localProxyPort)
    }

    private func stopLocalProxy() {
        os_log("Stopping local proxy server...", log: log, type: .info)

        localProxyServer?.stop()
        localProxyServer = nil
        trafficRecorder = nil
        tlsInterceptor = nil
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
        localInspectionEnabled = config["localInspectionEnabled"] as? Bool ?? false
        forwardToRemoteProxy = config["forwardToRemoteProxy"] as? Bool ?? false

        os_log("Configuration loaded - Proxy: %{public}@:%{public}d, Local: %{public}@",
               log: log, type: .info, proxyHost, proxyPort, localInspectionEnabled ? "YES" : "NO")
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

        if localInspectionEnabled {
            // Route traffic through local proxy for inspection
            proxySettings.httpEnabled = true
            proxySettings.httpServer = NEProxyServer(address: "127.0.0.1", port: Int(localProxyPort))

            proxySettings.httpsEnabled = true
            proxySettings.httpsServer = NEProxyServer(address: "127.0.0.1", port: Int(localProxyPort))

            os_log("Local proxy configured: 127.0.0.1:%{public}d", log: log, type: .info, localProxyPort)
        } else if !proxyHost.isEmpty && proxyPort > 0 {
            // Route traffic directly to remote proxy
            proxySettings.httpEnabled = true
            proxySettings.httpServer = NEProxyServer(address: proxyHost, port: proxyPort)

            proxySettings.httpsEnabled = true
            proxySettings.httpsServer = NEProxyServer(address: proxyHost, port: proxyPort)

            os_log("Remote proxy configured: %{public}@:%{public}d", log: log, type: .info, proxyHost, proxyPort)
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

// MARK: - LocalProxyServerDelegate

extension PacketTunnelProvider: LocalProxyServerDelegate {
    func proxyServer(_ server: LocalProxyServer, didReceiveTraffic entry: TrafficEntryData) {
        trafficRecorder?.recordTraffic(entry)
    }
}

// MARK: - Tunnel Errors

enum TunnelError: Error, LocalizedError {
    case internalError
    case configurationFailed
    case localProxyFailed

    var errorDescription: String? {
        switch self {
        case .internalError: return "Internal tunnel error"
        case .configurationFailed: return "Failed to configure tunnel"
        case .localProxyFailed: return "Failed to start local proxy"
        }
    }
}
