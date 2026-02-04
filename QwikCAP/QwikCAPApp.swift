import SwiftUI

@main
struct QwikCAPApp: App {
    @StateObject private var vpnManager = VPNManager.shared
    @StateObject private var proxyConfig = ProxyConfiguration.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vpnManager)
                .environmentObject(proxyConfig)
        }
    }
}
