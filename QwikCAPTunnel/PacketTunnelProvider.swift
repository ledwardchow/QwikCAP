import NetworkExtension
import os.log

class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.qwikcap.tunnel", category: "PacketTunnel")

    private var proxyServer: TCPProxyServer?
    private var connectionManager: ConnectionManager?
    private var dnsResolver: DNSResolver?

    private var proxyHost: String = ""
    private var proxyPort: Int = 8080
    private var captureHTTP: Bool = true
    private var captureHTTPS: Bool = true
    private var captureWebSocket: Bool = true
    private var excludedHosts: [String] = []
    private var transparentMode: Bool = true

    private let appGroupID = "group.com.qwikcap.app"

    // Debug log file for troubleshooting
    private var debugLogURL: URL?

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("🚀 [TUNNEL] Starting tunnel...", log: log, type: .info)
        debugLog("================== TUNNEL START ==================")
        debugLog("Start time: \(Date())")
        debugLog("Options: \(String(describing: options))")

        // Setup debug log file
        setupDebugLog()

        // Load configuration
        loadConfiguration()

        debugLog("Configuration loaded:")
        debugLog("  - Proxy Host: '\(proxyHost)'")
        debugLog("  - Proxy Port: \(proxyPort)")
        debugLog("  - Capture HTTP: \(captureHTTP)")
        debugLog("  - Capture HTTPS: \(captureHTTPS)")
        debugLog("  - Capture WebSocket: \(captureWebSocket)")
        debugLog("  - Transparent Mode: \(transparentMode)")
        debugLog("  - Excluded Hosts: \(excludedHosts)")

        // Initialize components
        connectionManager = ConnectionManager(appGroupID: appGroupID)
        dnsResolver = DNSResolver()

        debugLog("Components initialized")

        // Start proxy server
        proxyServer = TCPProxyServer(
            connectionManager: connectionManager!,
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            transparentMode: transparentMode
        )

        do {
            try proxyServer?.start()
            let port = proxyServer?.listeningPort ?? 0
            os_log("🟢 [TUNNEL] Proxy server started on port %{public}d", log: log, type: .info, port)
            debugLog("Proxy server started on port: \(port)")
        } catch {
            os_log("🔴 [TUNNEL] Failed to start proxy server: %{public}@", log: log, type: .error, error.localizedDescription)
            debugLog("ERROR: Failed to start proxy server: \(error.localizedDescription)")
            completionHandler(error)
            return
        }

        // Wait a moment for the proxy server to fully start and get its port
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else {
                completionHandler(TunnelError.internalError)
                return
            }

            // Configure tunnel network settings
            let tunnelNetworkSettings = self.createTunnelSettings()

            self.debugLog("Applying tunnel network settings...")
            self.debugLog("  - Tunnel Remote Address: \(tunnelNetworkSettings.tunnelRemoteAddress)")

            self.setTunnelNetworkSettings(tunnelNetworkSettings) { [weak self] error in
                if let error = error {
                    os_log("🔴 [TUNNEL] Failed to set tunnel settings: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                    self?.debugLog("ERROR: Failed to set tunnel settings: \(error.localizedDescription)")
                    completionHandler(error)
                    return
                }

                os_log("🟢 [TUNNEL] Tunnel settings applied successfully", log: self?.log ?? .default, type: .info)
                self?.debugLog("Tunnel settings applied successfully!")
                self?.debugLog("================== TUNNEL READY ==================")
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("🛑 [TUNNEL] Stopping tunnel with reason: %{public}d", log: log, type: .info, reason.rawValue)
        debugLog("================== TUNNEL STOP ==================")
        debugLog("Stop reason: \(stopReasonDescription(reason))")
        debugLog("Stop time: \(Date())")

        proxyServer?.stop()
        connectionManager?.closeAllConnections()

        debugLog("Cleanup completed")
        completionHandler()
    }

    private func stopReasonDescription(_ reason: NEProviderStopReason) -> String {
        switch reason {
        case .none: return "none"
        case .userInitiated: return "userInitiated"
        case .providerFailed: return "providerFailed"
        case .noNetworkAvailable: return "noNetworkAvailable"
        case .unrecoverableNetworkChange: return "unrecoverableNetworkChange"
        case .providerDisabled: return "providerDisabled"
        case .authenticationCanceled: return "authenticationCanceled"
        case .configurationFailed: return "configurationFailed"
        case .idleTimeout: return "idleTimeout"
        case .configurationDisabled: return "configurationDisabled"
        case .configurationRemoved: return "configurationRemoved"
        case .superceded: return "superceded"
        case .userLogout: return "userLogout"
        case .userSwitch: return "userSwitch"
        case .connectionFailed: return "connectionFailed"
        case .sleep: return "sleep"
        case .appUpdate: return "appUpdate"
        @unknown default: return "unknown(\(reason.rawValue))"
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let action = message["action"] as? String else {
            completionHandler?(nil)
            return
        }

        switch action {
        case "getStats":
            let stats = connectionManager?.getStatistics() ?? [:]
            let responseData = try? JSONSerialization.data(withJSONObject: stats)
            completionHandler?(responseData)

        case "updateConfig":
            loadConfiguration()
            proxyServer?.updateConfiguration(
                proxyHost: proxyHost,
                proxyPort: proxyPort,
                transparentMode: transparentMode
            )
            completionHandler?(nil)

        case "clearStats":
            connectionManager?.clearStatistics()
            completionHandler?(nil)

        default:
            completionHandler?(nil)
        }
    }

    // MARK: - Debug Logging

    private func setupDebugLog() {
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            debugLogURL = containerURL.appendingPathComponent("tunnel_debug.log")
            // Clear previous log
            try? "".write(to: debugLogURL!, atomically: true, encoding: .utf8)
            debugLog("Debug log initialized at: \(debugLogURL!.path)")
        }
    }

    private func debugLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"

        os_log("%{public}@", log: log, type: .debug, message)

        guard let url = debugLogURL else { return }
        DispatchQueue.global(qos: .utility).async {
            if let data = logLine.data(using: .utf8),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }

    // MARK: - Configuration

    private func loadConfiguration() {
        os_log("📋 [TUNNEL] Loading configuration...", log: log, type: .info)

        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol else {
            os_log("⚠️ [TUNNEL] Protocol configuration is not NETunnelProviderProtocol", log: log, type: .error)
            debugLog("WARNING: Protocol configuration type: \(type(of: protocolConfiguration))")
            return
        }

        guard let config = protocolConfig.providerConfiguration else {
            os_log("⚠️ [TUNNEL] No provider configuration found", log: log, type: .error)
            debugLog("WARNING: No provider configuration in protocol config")
            return
        }

        debugLog("Raw configuration: \(config)")

        proxyHost = config["proxyHost"] as? String ?? ""
        proxyPort = config["proxyPort"] as? Int ?? 8080
        captureHTTP = config["captureHTTP"] as? Bool ?? true
        captureHTTPS = config["captureHTTPS"] as? Bool ?? true
        captureWebSocket = config["captureWebSocket"] as? Bool ?? true
        excludedHosts = config["excludedHosts"] as? [String] ?? []
        transparentMode = config["transparentMode"] as? Bool ?? true

        os_log("📋 [TUNNEL] Configuration loaded - Proxy: %{public}@:%{public}d", log: log, type: .info, proxyHost, proxyPort)
    }

    // MARK: - Tunnel Network Settings

    private func createTunnelSettings() -> NEPacketTunnelNetworkSettings {
        debugLog("Creating tunnel network settings...")

        // Use a virtual IP for the tunnel
        let tunnelAddress = "10.8.0.1"
        let tunnelSubnetMask = "255.255.255.0"
        let tunnelRemoteAddress = "10.8.0.2"

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)

        debugLog("Tunnel addresses: local=\(tunnelAddress), remote=\(tunnelRemoteAddress)")

        // IPv4 settings
        let ipv4Settings = NEIPv4Settings(addresses: [tunnelAddress], subnetMasks: [tunnelSubnetMask])

        // Route all traffic through the tunnel
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]

        debugLog("IPv4 included routes: default (0.0.0.0/0)")

        // Exclude certain routes to prevent routing loops
        var excludedRoutes: [NEIPv4Route] = []

        // Exclude local network ranges
        excludedRoutes.append(NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"))
        excludedRoutes.append(NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"))
        excludedRoutes.append(NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"))
        excludedRoutes.append(NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"))

        // IMPORTANT: If upstream proxy is configured, exclude its IP to prevent loops
        if !proxyHost.isEmpty {
            // Try to determine if proxyHost is an IP or hostname
            if isIPAddress(proxyHost) {
                excludedRoutes.append(NEIPv4Route(destinationAddress: proxyHost, subnetMask: "255.255.255.255"))
                debugLog("Excluding upstream proxy IP from tunnel: \(proxyHost)")
            }
        }

        ipv4Settings.excludedRoutes = excludedRoutes
        settings.ipv4Settings = ipv4Settings

        debugLog("IPv4 excluded routes: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8")

        // DNS settings - use Google DNS
        let dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
        dnsSettings.matchDomains = [""] // Match all domains
        settings.dnsSettings = dnsSettings

        debugLog("DNS servers: 8.8.8.8, 8.8.4.4")

        // Proxy settings for HTTP/HTTPS interception
        let proxySettings = NEProxySettings()

        // Get the local proxy server port
        let localProxyPort = proxyServer?.listeningPort ?? 8888

        debugLog("Local proxy port: \(localProxyPort)")

        proxySettings.httpEnabled = captureHTTP
        proxySettings.httpServer = NEProxyServer(address: "127.0.0.1", port: localProxyPort)

        proxySettings.httpsEnabled = captureHTTPS
        proxySettings.httpsServer = NEProxyServer(address: "127.0.0.1", port: localProxyPort)

        // Match all domains - this is critical for proxy to work
        proxySettings.matchDomains = [""]

        debugLog("Proxy settings:")
        debugLog("  - HTTP enabled: \(captureHTTP), server: 127.0.0.1:\(localProxyPort)")
        debugLog("  - HTTPS enabled: \(captureHTTPS), server: 127.0.0.1:\(localProxyPort)")
        debugLog("  - Match domains: [''] (all)")

        // Exclude certain domains from proxy
        var exclusionList = excludedHosts
        exclusionList.append("localhost")
        exclusionList.append("*.local")
        exclusionList.append("*.apple.com") // Exclude Apple services to prevent issues
        exclusionList.append("*.icloud.com")
        proxySettings.exceptionList = exclusionList

        debugLog("Proxy exception list: \(exclusionList)")

        settings.proxySettings = proxySettings

        // MTU
        settings.mtu = 1500

        debugLog("MTU: 1500")
        debugLog("Tunnel settings configuration complete")

        return settings
    }

    private func isIPAddress(_ string: String) -> Bool {
        var sin = sockaddr_in()
        var sin6 = sockaddr_in6()
        return string.withCString { cstring in
            inet_pton(AF_INET, cstring, &sin.sin_addr) == 1 ||
            inet_pton(AF_INET6, cstring, &sin6.sin6_addr) == 1
        }
    }
}

// MARK: - Tunnel Errors

enum TunnelError: Error, LocalizedError {
    case internalError
    case proxyStartFailed
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .internalError: return "Internal tunnel error"
        case .proxyStartFailed: return "Failed to start proxy server"
        case .configurationFailed: return "Failed to configure tunnel"
        }
    }
}
