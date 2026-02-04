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
    }

    // MARK: - Configuration Helpers

    var isConfigured: Bool {
        !proxyHost.isEmpty && proxyPort > 0
    }
}
