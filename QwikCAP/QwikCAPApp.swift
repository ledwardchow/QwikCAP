import SwiftUI

@main
struct QwikCAPApp: App {
    @StateObject private var vpnManager = VPNManager.shared
    @StateObject private var proxyConfig = ProxyConfiguration.shared
    @StateObject private var trafficStore = TrafficStore.shared
    @StateObject private var certificateManager = CertificateManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vpnManager)
                .environmentObject(proxyConfig)
                .environmentObject(trafficStore)
                .environmentObject(certificateManager)
        }
    }
}
