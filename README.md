# QwikCAP

**Quick Capture All Packets** - An iOS app that captures HTTP, HTTPS, and WebSocket traffic and forwards it to a proxy like Burp Suite for security testing.

## Features

- 🔒 **HTTPS Interception** - Generate and install a CA certificate to intercept encrypted traffic
- 🌐 **HTTP/HTTPS/WebSocket Support** - Capture all common web traffic types
- 🔄 **Transparent Proxy** - Forward traffic to Burp Suite, Charles Proxy, or mitmproxy
- 📊 **Traffic Viewer** - View captured requests/responses with syntax highlighting
- 📤 **Export Options** - Export traffic as HAR or Burp-compatible format
- ⚙️ **Configurable** - Filter hosts, exclude domains, configure capture options

## Requirements

- iOS 16.0+
- Xcode 15.0+
- Apple Developer Account (for Network Extension entitlements)
- Physical iOS device (Network Extensions don't work in Simulator)

## Setup Instructions

### 1. Developer Account Configuration

Before building, you need to configure your Apple Developer account:

1. Open the project in Xcode
2. Select the **QwikCAP** target
3. Go to **Signing & Capabilities**
4. Select your development team
5. Update the **Bundle Identifier** to something unique (e.g., `com.yourname.qwikcap`)
6. Repeat for the **QwikCAPTunnel** extension target

### 2. App Group Configuration

1. In your Apple Developer account, create an App Group with identifier: `group.com.yourname.qwikcap`
2. Update the App Group identifier in both:
   - `QwikCAP/QwikCAP.entitlements`
   - `QwikCAPTunnel/QwikCAPTunnel.entitlements`
3. Also update the `appGroupID` constant in:
   - `CertificateManager.swift`
   - `VPNManager.swift`
   - `TrafficLogger.swift`
   - `PacketTunnelProvider.swift`
   - `TLSHandler.swift`
   - `ConnectionManager.swift`

### 3. Network Extension Entitlement

You need the **Network Extension** entitlement from Apple:

1. Go to your [Apple Developer Account](https://developer.apple.com/account)
2. Navigate to **Certificates, Identifiers & Profiles**
3. Select **Identifiers** and find your App ID
4. Enable **Network Extensions** capability
5. Request the **packet-tunnel-provider** entitlement if not already available

### 4. Building and Running

1. Connect your iOS device
2. Select your device as the build target
3. Build and run the app (⌘R)
4. On first launch, iOS will ask for VPN permission

## Usage

### Initial Setup

1. **Generate Certificate**: Go to the Certificate tab and tap "Generate Certificate"
2. **Export Certificate**: Tap "Export Certificate" and choose to save/share the file
3. **Install Profile**:
   - Open the certificate file on your iOS device
   - Go to **Settings > General > VPN & Device Management**
   - Find the QwikCAP profile and tap **Install**
4. **Trust Certificate**:
   - Go to **Settings > General > About > Certificate Trust Settings**
   - Enable full trust for "QwikCAP Root CA"

### Configuring Burp Suite

1. In Burp Suite on your computer:
   - Go to **Proxy > Options**
   - Add a proxy listener on port `8080` bound to your computer's IP address (not 127.0.0.1)
   - Ensure "Support invisible proxying" is enabled for transparent mode

2. In QwikCAP on your iOS device:
   - Go to **Settings** tab
   - Enter your computer's IP address (e.g., `192.168.1.100`)
   - Set port to `8080`
   - Tap "Apply Configuration"

3. Start Capturing:
   - Go to **Dashboard** tab
   - Tap "Start Capture"
   - Your device traffic will now appear in Burp Suite

### Finding Your Computer's IP

- **macOS**: System Preferences > Network > Wi-Fi > IP Address
- **Windows**: `ipconfig` in Command Prompt
- **Linux**: `ip addr` or `ifconfig`

Make sure your iOS device and computer are on the same network!

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      QwikCAP App                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │  Dashboard  │  │   Traffic   │  │      Settings       │  │
│  │    View     │  │    List     │  │        View         │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│         │               │                    │              │
│  ┌──────┴───────────────┴────────────────────┴────────┐    │
│  │              Shared Services                        │    │
│  │  • VPNManager  • CertificateManager  • TrafficLogger│    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                              │
                    App Group (Shared Data)
                              │
┌─────────────────────────────────────────────────────────────┐
│                  QwikCAPTunnel Extension                    │
│  ┌─────────────────┐  ┌─────────────────────────────────┐  │
│  │ PacketTunnel    │  │         TCPProxyServer          │  │
│  │   Provider      │──│  • HTTP Parsing                 │  │
│  └─────────────────┘  │  • TLS Interception             │  │
│                       │  • WebSocket Handling            │  │
│                       │  • Proxy Forwarding              │  │
│                       └─────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │   Burp Suite    │
                    │   (or other     │
                    │    proxy)       │
                    └─────────────────┘
```

## Troubleshooting

### VPN won't connect
- Ensure you've granted VPN permission when prompted
- Check that the Network Extension entitlement is properly configured
- Try deleting and reinstalling the app

### HTTPS sites show certificate errors
- Make sure you've installed AND trusted the CA certificate
- Certificate trust is a separate step from installation
- Go to Settings > General > About > Certificate Trust Settings

### Traffic not appearing in Burp Suite
- Verify your computer's IP address is correct in QwikCAP settings
- Ensure Burp is listening on the correct interface (not just localhost)
- Check that both devices are on the same network
- Try disabling firewall temporarily

### Certificate generation fails
- The app needs Keychain access - try reinstalling
- Ensure you have sufficient storage space

### App crashes on launch
- This usually indicates an entitlement issue
- Verify all signing and capabilities are correctly configured

## Security Considerations

⚠️ **Important**: This app is intended for security testing of your own applications and devices.

- Only use on networks and systems you own or have permission to test
- The CA certificate can intercept ALL HTTPS traffic - be aware of the security implications
- Remove the CA certificate when not actively testing
- Never share your generated CA private key

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
│
└── README.md
```

## License

MIT License - See LICENSE file for details.

## Acknowledgments

- Inspired by tools like Burp Suite, Charles Proxy, and mitmproxy
- Built with Apple's NetworkExtension framework
- Uses SwiftUI for the user interface
