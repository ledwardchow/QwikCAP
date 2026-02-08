# QwikCAP
VPN-based direct proxy forwarding for iOS traffic.

## Current capabilities

- Implements VPN-based direct proxy forwarding via a Network Extension tunnel.
- Routes device traffic through a VPN tunnel to a designated proxy endpoint (e.g., Burp Suite, mitmproxy).
- Lightweight configuration focused on quick-start for typical dev/ops scenarios.
- Architecture supports TLS interception and HTTP/WS parsing in the tunnel, but the current release exposes VPN-forwarding as the primary workflow.

 

## Getting started

Prerequisites:
- iOS 16.0+
- Xcode 15.0+
- Apple Developer Account (for Network Extension entitlements)
- Physical iOS device (Network Extensions don't work in Simulator)

Setup and Run:
- Open the project in Xcode and configure signing for the QwikCAP targets as described in the project notes.
- Build and deploy to a physical iOS device.
- On first launch, iOS will prompt for VPN permission; grant access to enable the VPN tunnel.

## Usage

Initial setup steps:
- Generate and install any required certificates as described in the project setup docs.
- Configure the proxy endpoint in QwikCAP Settings (IP address and port of your proxy server).
- Start the VPN-forwarding flow from the app to begin routing traffic through the proxy.

Typical workflow:
- The app establishes a VPN tunnel to the configured proxy endpoint.
- Traffic is forwarded through the VPN tunnel to the proxy, enabling interception or analysis by your chosen proxy solution.

## Configuration

- Config is managed via the app's UI and, where applicable, environment variables.
- Common fields:
  - VPN endpoint or configuration for the tunnel
  - Proxy address and port (e.g., Burp/mitmproxy listener)
  - Logging level

## How VPN forwarding works (conceptual)

- The app initializes a VPN tunnel via the iOS Network Extension.
- All designated traffic is redirected through the VPN tunnel to the proxy endpoint.
- This release focuses on VPN-forwarding; local inspection features are planned for future releases.

## Notes for Developers
- This release focuses on VPN-based direct proxy forwarding via the Network Extension tunnel.
- Local traffic inspection is not implemented in this release; no configuration or code paths for inspection are exposed here.

## Troubleshooting

- VPN won't connect
  - Ensure VPN permission is granted when prompted
  - Check that the Network Extension entitlement is correctly configured
  - Reinstall the app if necessary

- HTTPS sites show certificate errors
  - Ensure the CA certificate is installed and trusted
  - Certificate trust requires an explicit step in iOS settings

- Traffic not appearing in the proxy
  - Verify the proxy endpoint is reachable from the network
  - Ensure the iOS device and proxy are on the same network or reachable paths exist
  - Check firewall rules on the proxy side

- App crashes on launch
  - Entitlements and signing issues are the most common cause; verify all signing configurations

## Security Considerations

⚠️ This app is intended for security testing of your own applications and devices.

- Only use on networks you own or have explicit permission to test
- The VPN tunnel can forward all traffic; handle with care
- Remove VPN profiles when not actively testing
- Never share sensitive keys or credentials

## Project Structure

```
QwikCAP/
├── QwikCAP/                    # Main app target
│   ├── QwikCAPApp.swift        # App entry point
│   ├── ContentView.swift       # Main tab view
│   ├── Views/                  # SwiftUI views
│   │   ├── SettingsView.swift
│   │   ├── TrafficListView.swift
│   │   ├── TrafficDetailView.swift
│   │   └── CertificateGuideView.swift
│   ├── Services/               # Core services
│   │   ├── CertificateManager.swift
│   │   ├── VPNManager.swift
│   │   └── TrafficLogger.swift
│   ├── Models/                 # Data models
│   │   ├── ProxyConfiguration.swift
│   │   └── TrafficEntry.swift
│   └── Network/                # Network utilities
│       ├── HTTPParser.swift
│       ├── WebSocketHandler.swift
│       ├── TLSInterceptor.swift
│       └── ProxyForwarder.swift
│
├── QwikCAPTunnel/              # Network Extension target
│   ├── PacketTunnelProvider.swift
│   ├── TCPProxyServer.swift
│   ├── TLSHandler.swift
│   ├── ConnectionManager.swift
│   └── DNSResolver.swift
```

## License

MIT License - See LICENSE file for details.

## Acknowledgments

- Inspired by tools like Burp Suite, Charles Proxy, and mitmproxy
- Built with Apple's NetworkExtension framework
- Uses SwiftUI for the user interface
