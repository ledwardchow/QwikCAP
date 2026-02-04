import SwiftUI

@main
struct QwikCAPApp: App {
    @StateObject private var vpnManager = VPNManager.shared
    @StateObject private var certificateManager = CertificateManager.shared
    @StateObject private var trafficLogger = TrafficLogger.shared
    @StateObject private var proxyConfig = ProxyConfiguration.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vpnManager)
                .environmentObject(certificateManager)
                .environmentObject(trafficLogger)
                .environmentObject(proxyConfig)
        }
    }
}
