import Foundation
import Combine

class ProxyConfiguration: ObservableObject {
    static let shared = ProxyConfiguration()

    private let defaults = UserDefaults(suiteName: "group.com.qwikcap.app")!

    @Published var proxyHost: String {
        didSet { defaults.set(proxyHost, forKey: "proxyHost") }
    }

    @Published var proxyPort: Int {
        didSet { defaults.set(proxyPort, forKey: "proxyPort") }
    }

    @Published var captureHTTP: Bool {
        didSet { defaults.set(captureHTTP, forKey: "captureHTTP") }
    }

    @Published var captureHTTPS: Bool {
        didSet { defaults.set(captureHTTPS, forKey: "captureHTTPS") }
    }

    @Published var captureWebSocket: Bool {
        didSet { defaults.set(captureWebSocket, forKey: "captureWebSocket") }
    }

    @Published var transparentMode: Bool {
        didSet { defaults.set(transparentMode, forKey: "transparentMode") }
    }

    @Published var excludedHosts: [String] {
        didSet { defaults.set(excludedHosts, forKey: "excludedHosts") }
    }

    @Published var includedHosts: [String] {
        didSet { defaults.set(includedHosts, forKey: "includedHosts") }
    }

    @Published var logRequestBodies: Bool {
        didSet { defaults.set(logRequestBodies, forKey: "logRequestBodies") }
    }

    @Published var logResponseBodies: Bool {
        didSet { defaults.set(logResponseBodies, forKey: "logResponseBodies") }
    }

    @Published var maxBodySize: Int {
        didSet { defaults.set(maxBodySize, forKey: "maxBodySize") }
    }

    @Published var interceptEnabled: Bool {
        didSet { defaults.set(interceptEnabled, forKey: "interceptEnabled") }
    }

    private init() {
        // Load saved values or use defaults
        proxyHost = defaults.string(forKey: "proxyHost") ?? ""

        let savedProxyPort = defaults.integer(forKey: "proxyPort")
        proxyPort = savedProxyPort == 0 ? 8080 : savedProxyPort

        captureHTTP = defaults.object(forKey: "captureHTTP") as? Bool ?? true
        captureHTTPS = defaults.object(forKey: "captureHTTPS") as? Bool ?? true
        captureWebSocket = defaults.object(forKey: "captureWebSocket") as? Bool ?? true
        transparentMode = defaults.object(forKey: "transparentMode") as? Bool ?? true

        excludedHosts = defaults.stringArray(forKey: "excludedHosts") ?? [
            "*.apple.com",
            "*.icloud.com",
            "*.mzstatic.com"
        ]
        includedHosts = defaults.stringArray(forKey: "includedHosts") ?? []

        logRequestBodies = defaults.object(forKey: "logRequestBodies") as? Bool ?? true
        logResponseBodies = defaults.object(forKey: "logResponseBodies") as? Bool ?? true

        let savedMaxBodySize = defaults.integer(forKey: "maxBodySize")
        maxBodySize = savedMaxBodySize == 0 ? 1024 * 1024 : savedMaxBodySize // 1MB default

        interceptEnabled = defaults.object(forKey: "interceptEnabled") as? Bool ?? false
    }

    // MARK: - Configuration Helpers

    var isConfigured: Bool {
        !proxyHost.isEmpty && proxyPort > 0
    }

    func shouldCapture(host: String, port: Int) -> Bool {
        // Check excluded hosts
        for pattern in excludedHosts {
            if matchesPattern(host: host, pattern: pattern) {
                return false
            }
        }

        // If included hosts is not empty, only capture those
        if !includedHosts.isEmpty {
            for pattern in includedHosts {
                if matchesPattern(host: host, pattern: pattern) {
                    return true
                }
            }
            return false
        }

        return true
    }

    private func matchesPattern(host: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host.hasSuffix(suffix) || host == suffix.dropFirst()
        }
        return host == pattern || host.hasSuffix(".\(pattern)")
    }

    func shouldCaptureProtocol(port: Int, isHTTPS: Bool) -> Bool {
        if isHTTPS {
            return captureHTTPS
        } else {
            return captureHTTP
        }
    }

    // MARK: - Preset Configurations

    func applyBurpSuitePreset() {
        proxyHost = "127.0.0.1" // Will be updated by user to their machine's IP
        proxyPort = 8080
        transparentMode = true
        captureHTTP = true
        captureHTTPS = true
        captureWebSocket = true
    }

    func applyCharlesProxyPreset() {
        proxyHost = "127.0.0.1"
        proxyPort = 8888
        transparentMode = true
        captureHTTP = true
        captureHTTPS = true
        captureWebSocket = true
    }

    func applyMitmProxyPreset() {
        proxyHost = "127.0.0.1"
        proxyPort = 8080
        transparentMode = true
        captureHTTP = true
        captureHTTPS = true
        captureWebSocket = true
    }

    // MARK: - Export/Import

    func exportConfiguration() -> Data? {
        let config: [String: Any] = [
            "proxyHost": proxyHost,
            "proxyPort": proxyPort,
            "captureHTTP": captureHTTP,
            "captureHTTPS": captureHTTPS,
            "captureWebSocket": captureWebSocket,
            "transparentMode": transparentMode,
            "excludedHosts": excludedHosts,
            "includedHosts": includedHosts,
            "logRequestBodies": logRequestBodies,
            "logResponseBodies": logResponseBodies,
            "maxBodySize": maxBodySize,
            "interceptEnabled": interceptEnabled
        ]
        return try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
    }

    func importConfiguration(from data: Data) throws {
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurationError.invalidFormat
        }

        if let host = config["proxyHost"] as? String { proxyHost = host }
        if let port = config["proxyPort"] as? Int { proxyPort = port }
        if let http = config["captureHTTP"] as? Bool { captureHTTP = http }
        if let https = config["captureHTTPS"] as? Bool { captureHTTPS = https }
        if let ws = config["captureWebSocket"] as? Bool { captureWebSocket = ws }
        if let transparent = config["transparentMode"] as? Bool { transparentMode = transparent }
        if let excluded = config["excludedHosts"] as? [String] { excludedHosts = excluded }
        if let included = config["includedHosts"] as? [String] { includedHosts = included }
        if let reqBodies = config["logRequestBodies"] as? Bool { logRequestBodies = reqBodies }
        if let resBodies = config["logResponseBodies"] as? Bool { logResponseBodies = resBodies }
        if let maxBody = config["maxBodySize"] as? Int { maxBodySize = maxBody }
        if let intercept = config["interceptEnabled"] as? Bool { interceptEnabled = intercept }
    }
}

enum ConfigurationError: Error, LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Invalid configuration format"
        }
    }
}
