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

    @Published var excludedHosts: [String] {
        didSet { defaults.set(excludedHosts, forKey: "excludedHosts") }
    }

    // MARK: - Local Traffic Inspection Settings

    @Published var localInspectionEnabled: Bool {
        didSet { defaults.set(localInspectionEnabled, forKey: "localInspectionEnabled") }
    }

    @Published var forwardToRemoteProxy: Bool {
        didSet { defaults.set(forwardToRemoteProxy, forKey: "forwardToRemoteProxy") }
    }

    @Published var captureRequestBodies: Bool {
        didSet { defaults.set(captureRequestBodies, forKey: "captureRequestBodies") }
    }

    @Published var captureResponseBodies: Bool {
        didSet { defaults.set(captureResponseBodies, forKey: "captureResponseBodies") }
    }

    @Published var maxBodySize: Int {
        didSet { defaults.set(maxBodySize, forKey: "maxBodySize") }
    }

    private init() {
        // Load saved values or use defaults
        proxyHost = defaults.string(forKey: "proxyHost") ?? ""

        let savedProxyPort = defaults.integer(forKey: "proxyPort")
        proxyPort = savedProxyPort == 0 ? 8080 : savedProxyPort

        excludedHosts = defaults.stringArray(forKey: "excludedHosts") ?? [
            "*.apple.com",
            "*.icloud.com",
            "*.mzstatic.com"
        ]

        // Local inspection settings
        localInspectionEnabled = defaults.bool(forKey: "localInspectionEnabled")
        forwardToRemoteProxy = defaults.bool(forKey: "forwardToRemoteProxy")

        // Body capture settings with defaults
        captureRequestBodies = defaults.object(forKey: "captureRequestBodies") as? Bool ?? true
        captureResponseBodies = defaults.object(forKey: "captureResponseBodies") as? Bool ?? true

        let savedMaxBodySize = defaults.integer(forKey: "maxBodySize")
        maxBodySize = savedMaxBodySize == 0 ? 1_000_000 : savedMaxBodySize  // 1MB default
    }

    // MARK: - Configuration Helpers

    var isConfigured: Bool {
        !proxyHost.isEmpty && proxyPort > 0
    }

    var isRemoteProxyConfigured: Bool {
        !proxyHost.isEmpty && proxyPort > 0
    }

    var effectiveProxyMode: ProxyMode {
        if localInspectionEnabled {
            return forwardToRemoteProxy && isRemoteProxyConfigured ? .localWithForwarding : .localOnly
        } else if isRemoteProxyConfigured {
            return .remoteOnly
        } else {
            return .disabled
        }
    }
}

// MARK: - Proxy Mode

enum ProxyMode {
    case disabled
    case localOnly
    case localWithForwarding
    case remoteOnly

    var description: String {
        switch self {
        case .disabled: return "No proxy configured"
        case .localOnly: return "Local inspection only"
        case .localWithForwarding: return "Local inspection + Remote forwarding"
        case .remoteOnly: return "Remote proxy only"
        }
    }
}
