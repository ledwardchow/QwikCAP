import Foundation
import Network
import os.log

class TCPProxyServer {
    private let log = OSLog(subsystem: "com.qwikcap.tunnel", category: "TCPProxy")

    private var listener: NWListener?
    private var connectionManager: ConnectionManager
    private var tlsHandler: TLSHandler?

    private(set) var listeningPort: Int = 0

    private var proxyHost: String
    private var proxyPort: Int
    private var transparentMode: Bool

    private let queue = DispatchQueue(label: "com.qwikcap.tcpproxy", qos: .userInitiated)

    // Connection tracking
    private var connectionCount: Int = 0
    private let countLock = NSLock()

    init(connectionManager: ConnectionManager, proxyHost: String, proxyPort: Int, transparentMode: Bool) {
        self.connectionManager = connectionManager
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.transparentMode = transparentMode
        self.tlsHandler = TLSHandler(connectionManager: connectionManager)

        os_log("🔧 [PROXY] Initialized - Upstream: %{public}@:%{public}d, Transparent: %{public}@",
               log: log, type: .info,
               proxyHost.isEmpty ? "(none)" : proxyHost,
               proxyPort,
               transparentMode ? "YES" : "NO")
    }

    func start() throws {
        os_log("🔧 [PROXY] Starting TCP proxy server...", log: log, type: .info)

        // Create TCP listener
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        // Try to bind to a specific port first, then any port
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: 8888))
        } catch {
            os_log("⚠️ [PROXY] Port 8888 unavailable, binding to any port", log: log, type: .info)
            listener = try NWListener(using: parameters, on: .any)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .setup:
                os_log("🔧 [PROXY] Listener setting up...", log: self.log, type: .debug)
            case .waiting(let error):
                os_log("⏳ [PROXY] Listener waiting: %{public}@", log: self.log, type: .info, error.localizedDescription)
            case .ready:
                if let port = self.listener?.port?.rawValue {
                    self.listeningPort = Int(port)
                    os_log("🟢 [PROXY] Listening on port %{public}d", log: self.log, type: .info, port)
                }
            case .failed(let error):
                os_log("🔴 [PROXY] Listener FAILED: %{public}@", log: self.log, type: .error, error.localizedDescription)
            case .cancelled:
                os_log("🛑 [PROXY] Listener cancelled", log: self.log, type: .info)
            @unknown default:
                os_log("❓ [PROXY] Unknown listener state", log: self.log, type: .info)
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: queue)
        os_log("🔧 [PROXY] Listener start() called", log: log, type: .info)
    }

    func stop() {
        os_log("🛑 [PROXY] Stopping proxy server...", log: log, type: .info)
        listener?.cancel()
        listener = nil
        os_log("🛑 [PROXY] Proxy server stopped", log: log, type: .info)
    }

    func updateConfiguration(proxyHost: String, proxyPort: Int, transparentMode: Bool) {
        os_log("🔄 [PROXY] Configuration updated - Upstream: %{public}@:%{public}d",
               log: log, type: .info, proxyHost.isEmpty ? "(none)" : proxyHost, proxyPort)
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.transparentMode = transparentMode
    }

    private func incrementConnectionCount() -> Int {
        countLock.lock()
        defer { countLock.unlock() }
        connectionCount += 1
        return connectionCount
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ clientConnection: NWConnection) {
        let connNum = incrementConnectionCount()
        let connectionId = "conn-\(connNum)-\(UUID().uuidString.prefix(8))"

        os_log("📥 [PROXY] NEW CONNECTION #%{public}d: %{public}@", log: log, type: .info, connNum, connectionId)

        // Log endpoint info if available
        if let endpoint = clientConnection.currentPath?.remoteEndpoint {
            os_log("   [PROXY] Remote endpoint: %{public}@", log: log, type: .debug, "\(endpoint)")
        }

        clientConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .setup:
                os_log("   [PROXY] %{public}@: Setting up", log: self.log, type: .debug, connectionId)
            case .preparing:
                os_log("   [PROXY] %{public}@: Preparing", log: self.log, type: .debug, connectionId)
            case .ready:
                os_log("🟢 [PROXY] %{public}@: Ready, processing...", log: self.log, type: .info, connectionId)
                self.processClientConnection(clientConnection, connectionId: connectionId)
            case .waiting(let error):
                os_log("⏳ [PROXY] %{public}@: Waiting - %{public}@", log: self.log, type: .info, connectionId, error.localizedDescription)
            case .failed(let error):
                os_log("🔴 [PROXY] %{public}@: FAILED - %{public}@", log: self.log, type: .error, connectionId, error.localizedDescription)
            case .cancelled:
                os_log("🛑 [PROXY] %{public}@: Cancelled", log: self.log, type: .debug, connectionId)
            @unknown default:
                os_log("❓ [PROXY] %{public}@: Unknown state", log: self.log, type: .info, connectionId)
            }
        }

        clientConnection.start(queue: queue)
    }

    private func processClientConnection(_ clientConnection: NWConnection, connectionId: String) {
        os_log("📨 [PROXY] %{public}@: Waiting for initial data...", log: log, type: .debug, connectionId)

        // Read the initial request to determine the destination
        clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                os_log("🔴 [PROXY] %{public}@: Error receiving data: %{public}@", log: self.log, type: .error, connectionId, error.localizedDescription)
                clientConnection.cancel()
                return
            }

            guard let data = data, !data.isEmpty else {
                os_log("⚠️ [PROXY] %{public}@: Empty data received (isComplete: %{public}@)",
                       log: self.log, type: .info, connectionId, isComplete ? "YES" : "NO")
                if isComplete {
                    clientConnection.cancel()
                }
                return
            }

            os_log("📨 [PROXY] %{public}@: Received %{public}d bytes", log: self.log, type: .info, connectionId, data.count)

            // Try to log the first line of the request for debugging
            if let firstLine = String(data: data.prefix(200), encoding: .utf8)?
                .components(separatedBy: "\r\n").first {
                os_log("   [PROXY] %{public}@: Request: %{public}@", log: self.log, type: .info, connectionId, firstLine)
            }

            // Parse the request to determine type
            if let request = self.parseHTTPRequest(data) {
                os_log("📋 [PROXY] %{public}@: Parsed HTTP - Method: %{public}@, Host: %{public}@:%{public}d, Path: %{public}@",
                       log: self.log, type: .info, connectionId, request.method, request.host, request.port, request.path)

                if request.method == "CONNECT" {
                    // HTTPS tunnel request
                    os_log("🔐 [PROXY] %{public}@: CONNECT request to %{public}@:%{public}d",
                           log: self.log, type: .info, connectionId, request.host, request.port)
                    self.handleConnectRequest(
                        clientConnection: clientConnection,
                        request: request,
                        connectionId: connectionId
                    )
                } else {
                    // Regular HTTP request
                    os_log("🌐 [PROXY] %{public}@: HTTP request to %{public}@:%{public}d",
                           log: self.log, type: .info, connectionId, request.host, request.port)
                    self.handleHTTPRequest(
                        clientConnection: clientConnection,
                        request: request,
                        rawData: data,
                        connectionId: connectionId
                    )
                }
            } else {
                // Unknown protocol, try to forward as raw TCP
                os_log("❓ [PROXY] %{public}@: Unknown protocol, treating as raw TCP", log: self.log, type: .info, connectionId)
                self.handleRawConnection(
                    clientConnection: clientConnection,
                    initialData: data,
                    connectionId: connectionId
                )
            }
        }
    }

    // MARK: - HTTP Request Handling

    private func handleHTTPRequest(
        clientConnection: NWConnection,
        request: HTTPRequest,
        rawData: Data,
        connectionId: String
    ) {
        os_log("🌐 [PROXY] %{public}@: HTTP %{public}@ %{public}@",
               log: log, type: .info, connectionId, request.method, request.uri)

        // Log the request
        connectionManager.logRequest(
            connectionId: connectionId,
            method: request.method,
            host: request.host,
            port: request.port,
            path: request.path,
            headers: request.headers,
            body: request.body,
            isHTTPS: false
        )

        // Forward to upstream proxy or direct connection
        if !proxyHost.isEmpty && proxyPort > 0 {
            os_log("➡️ [PROXY] %{public}@: Forwarding to upstream proxy %{public}@:%{public}d",
                   log: log, type: .info, connectionId, proxyHost, proxyPort)
            forwardToProxy(
                clientConnection: clientConnection,
                data: rawData,
                host: proxyHost,
                port: proxyPort,
                connectionId: connectionId,
                isHTTPS: false
            )
        } else {
            os_log("➡️ [PROXY] %{public}@: Connecting directly to %{public}@:%{public}d",
                   log: log, type: .info, connectionId, request.host, request.port)
            connectDirect(
                clientConnection: clientConnection,
                data: rawData,
                host: request.host,
                port: request.port,
                connectionId: connectionId,
                isHTTPS: false
            )
        }
    }

    // MARK: - CONNECT (HTTPS) Handling

    private func handleConnectRequest(
        clientConnection: NWConnection,
        request: HTTPRequest,
        connectionId: String
    ) {
        os_log("🔐 [PROXY] %{public}@: CONNECT to %{public}@:%{public}d",
               log: log, type: .info, connectionId, request.host, request.port)

        // If we have an upstream proxy, forward the CONNECT request
        if !proxyHost.isEmpty && proxyPort > 0 {
            os_log("➡️ [PROXY] %{public}@: Forwarding CONNECT to upstream %{public}@:%{public}d",
                   log: log, type: .info, connectionId, proxyHost, proxyPort)
            forwardConnectToProxy(
                clientConnection: clientConnection,
                host: request.host,
                port: request.port,
                connectionId: connectionId
            )
        } else {
            // Handle TLS interception locally
            os_log("🔓 [PROXY] %{public}@: No upstream proxy, handling TLS locally",
                   log: log, type: .info, connectionId)
            handleTLSInterception(
                clientConnection: clientConnection,
                host: request.host,
                port: request.port,
                connectionId: connectionId
            )
        }
    }

    private func forwardConnectToProxy(
        clientConnection: NWConnection,
        host: String,
        port: Int,
        connectionId: String
    ) {
        os_log("🔗 [PROXY] %{public}@: Connecting to upstream proxy %{public}@:%{public}d",
               log: log, type: .info, connectionId, proxyHost, proxyPort)

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxyHost), port: NWEndpoint.Port(integerLiteral: UInt16(proxyPort)))

        let proxyConnection = NWConnection(to: endpoint, using: .tcp)

        proxyConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                os_log("🟢 [PROXY] %{public}@: Connected to upstream proxy", log: self.log, type: .info, connectionId)

                // Send CONNECT request to upstream proxy
                let connectRequest = "CONNECT \(host):\(port) HTTP/1.1\r\nHost: \(host):\(port)\r\n\r\n"
                os_log("➡️ [PROXY] %{public}@: Sending CONNECT to upstream", log: self.log, type: .debug, connectionId)

                proxyConnection.send(content: connectRequest.data(using: .utf8), completion: .contentProcessed { error in
                    if let error = error {
                        os_log("🔴 [PROXY] %{public}@: Failed to send CONNECT: %{public}@",
                               log: self.log, type: .error, connectionId, error.localizedDescription)
                        clientConnection.cancel()
                        proxyConnection.cancel()
                        return
                    }

                    // Wait for 200 response from proxy
                    proxyConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, recvError in
                        if let recvError = recvError {
                            os_log("🔴 [PROXY] %{public}@: Error receiving from upstream: %{public}@",
                                   log: self.log, type: .error, connectionId, recvError.localizedDescription)
                            clientConnection.cancel()
                            proxyConnection.cancel()
                            return
                        }

                        guard let data = data,
                              let response = String(data: data, encoding: .utf8) else {
                            os_log("🔴 [PROXY] %{public}@: Empty response from upstream", log: self.log, type: .error, connectionId)
                            clientConnection.cancel()
                            proxyConnection.cancel()
                            return
                        }

                        os_log("⬅️ [PROXY] %{public}@: Upstream response: %{public}@",
                               log: self.log, type: .debug, connectionId,
                               String(response.prefix(100)))

                        guard response.contains("200") else {
                            os_log("🔴 [PROXY] %{public}@: Upstream rejected CONNECT", log: self.log, type: .error, connectionId)
                            clientConnection.cancel()
                            proxyConnection.cancel()
                            return
                        }

                        os_log("🟢 [PROXY] %{public}@: Upstream accepted CONNECT", log: self.log, type: .info, connectionId)

                        // Send 200 to client
                        let ok = "HTTP/1.1 200 Connection Established\r\n\r\n"
                        clientConnection.send(content: ok.data(using: .utf8), completion: .contentProcessed { _ in
                            os_log("🔄 [PROXY] %{public}@: Starting TLS interception", log: self.log, type: .info, connectionId)
                            // Start bidirectional tunneling with TLS interception
                            self.tlsHandler?.interceptTLS(
                                clientConnection: clientConnection,
                                serverConnection: proxyConnection,
                                host: host,
                                port: port,
                                connectionId: connectionId
                            )
                        })
                    }
                })
            case .waiting(let error):
                os_log("⏳ [PROXY] %{public}@: Waiting for upstream: %{public}@",
                       log: self.log, type: .info, connectionId, error.localizedDescription)
            case .failed(let error):
                os_log("🔴 [PROXY] %{public}@: Upstream connection FAILED: %{public}@",
                       log: self.log, type: .error, connectionId, error.localizedDescription)
                clientConnection.cancel()
            default:
                break
            }
        }

        proxyConnection.start(queue: queue)
    }

    private func handleTLSInterception(
        clientConnection: NWConnection,
        host: String,
        port: Int,
        connectionId: String
    ) {
        // Connect to the actual server
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)))

        let tlsParameters = NWParameters.tls
        let serverConnection = NWConnection(to: endpoint, using: tlsParameters)

        serverConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // Send 200 to client
                let ok = "HTTP/1.1 200 Connection Established\r\n\r\n"
                clientConnection.send(content: ok.data(using: .utf8), completion: .contentProcessed { error in
                    if let error = error {
                        os_log("Failed to send 200: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                        return
                    }

                    // Start TLS interception
                    self?.tlsHandler?.interceptTLS(
                        clientConnection: clientConnection,
                        serverConnection: serverConnection,
                        host: host,
                        port: port,
                        connectionId: connectionId
                    )
                })
            case .failed(let error):
                os_log("Server connection failed: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                // Send error to client
                let errorResponse = "HTTP/1.1 502 Bad Gateway\r\n\r\n"
                clientConnection.send(content: errorResponse.data(using: .utf8), completion: .contentProcessed { _ in
                    clientConnection.cancel()
                })
            default:
                break
            }
        }

        serverConnection.start(queue: queue)
    }

    // MARK: - Raw TCP Handling

    private func handleRawConnection(
        clientConnection: NWConnection,
        initialData: Data,
        connectionId: String
    ) {
        // For non-HTTP traffic, just tunnel it through
        guard !proxyHost.isEmpty && proxyPort > 0 else {
            clientConnection.cancel()
            return
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxyHost), port: NWEndpoint.Port(integerLiteral: UInt16(proxyPort)))
        let serverConnection = NWConnection(to: endpoint, using: .tcp)

        serverConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // Forward initial data
                serverConnection.send(content: initialData, completion: .contentProcessed { _ in
                    self?.startBidirectionalTunnel(
                        clientConnection: clientConnection,
                        serverConnection: serverConnection,
                        connectionId: connectionId
                    )
                })
            case .failed:
                clientConnection.cancel()
            default:
                break
            }
        }

        serverConnection.start(queue: queue)
    }

    // MARK: - Forwarding

    private func forwardToProxy(
        clientConnection: NWConnection,
        data: Data,
        host: String,
        port: Int,
        connectionId: String,
        isHTTPS: Bool
    ) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)))
        let serverConnection = NWConnection(to: endpoint, using: .tcp)

        serverConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // Forward request
                serverConnection.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        os_log("Failed to forward request: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                        return
                    }

                    // Receive response
                    self?.receiveResponse(
                        clientConnection: clientConnection,
                        serverConnection: serverConnection,
                        connectionId: connectionId,
                        isHTTPS: isHTTPS
                    )
                })
            case .failed(let error):
                os_log("Server connection failed: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                let errorResponse = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
                clientConnection.send(content: errorResponse.data(using: .utf8), completion: .contentProcessed { _ in
                    clientConnection.cancel()
                })
            default:
                break
            }
        }

        serverConnection.start(queue: queue)
    }

    private func connectDirect(
        clientConnection: NWConnection,
        data: Data,
        host: String,
        port: Int,
        connectionId: String,
        isHTTPS: Bool
    ) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)))

        var parameters: NWParameters
        if isHTTPS {
            parameters = NWParameters.tls
        } else {
            parameters = NWParameters.tcp
        }

        let serverConnection = NWConnection(to: endpoint, using: parameters)

        serverConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                serverConnection.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        os_log("Failed to send to server: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                        return
                    }

                    self?.receiveResponse(
                        clientConnection: clientConnection,
                        serverConnection: serverConnection,
                        connectionId: connectionId,
                        isHTTPS: isHTTPS
                    )
                })
            case .failed(let error):
                os_log("Direct connection failed: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                let errorResponse = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
                clientConnection.send(content: errorResponse.data(using: .utf8), completion: .contentProcessed { _ in
                    clientConnection.cancel()
                })
            default:
                break
            }
        }

        serverConnection.start(queue: queue)
    }

    private func receiveResponse(
        clientConnection: NWConnection,
        serverConnection: NWConnection,
        connectionId: String,
        isHTTPS: Bool
    ) {
        serverConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let error = error {
                os_log("Error receiving response: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                clientConnection.cancel()
                serverConnection.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                // Log response
                if let response = self?.parseHTTPResponse(data) {
                    self?.connectionManager.logResponse(
                        connectionId: connectionId,
                        statusCode: response.statusCode,
                        headers: response.headers,
                        body: response.body
                    )
                }

                // Forward to client
                clientConnection.send(content: data, completion: .contentProcessed { error in
                    if error != nil {
                        clientConnection.cancel()
                        serverConnection.cancel()
                        return
                    }

                    if !isComplete {
                        self?.receiveResponse(
                            clientConnection: clientConnection,
                            serverConnection: serverConnection,
                            connectionId: connectionId,
                            isHTTPS: isHTTPS
                        )
                    } else {
                        // Continue reading for keep-alive connections
                        self?.processClientConnection(clientConnection, connectionId: connectionId)
                    }
                })
            } else if isComplete {
                clientConnection.cancel()
                serverConnection.cancel()
            }
        }
    }

    private func startBidirectionalTunnel(
        clientConnection: NWConnection,
        serverConnection: NWConnection,
        connectionId: String
    ) {
        // Client -> Server
        func relayClientToServer() {
            clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data = data, !data.isEmpty {
                    serverConnection.send(content: data, completion: .contentProcessed { _ in
                        if !isComplete {
                            relayClientToServer()
                        }
                    })
                } else if isComplete || error != nil {
                    serverConnection.cancel()
                }
            }
        }

        // Server -> Client
        func relayServerToClient() {
            serverConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data = data, !data.isEmpty {
                    clientConnection.send(content: data, completion: .contentProcessed { _ in
                        if !isComplete {
                            relayServerToClient()
                        }
                    })
                } else if isComplete || error != nil {
                    clientConnection.cancel()
                }
            }
        }

        relayClientToServer()
        relayServerToClient()
    }

    // MARK: - HTTP Parsing

    private func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }

        let lines = string.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }

        let method = requestLine[0]
        let uri = requestLine[1]

        // Parse headers
        var headers: [String: String] = [:]
        var headerEndIndex = 1
        for i in 1..<lines.count {
            if lines[i].isEmpty {
                headerEndIndex = i
                break
            }
            let parts = lines[i].split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        // Parse body
        var body: String? = nil
        if headerEndIndex + 1 < lines.count {
            body = lines[(headerEndIndex + 1)...].joined(separator: "\r\n")
        }

        // Determine host and port
        var host = ""
        var port = 80
        var path = uri

        if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
            if let url = URL(string: uri) {
                host = url.host ?? ""
                port = url.port ?? (uri.hasPrefix("https://") ? 443 : 80)
                path = url.path.isEmpty ? "/" : url.path
                if let query = url.query {
                    path += "?\(query)"
                }
            }
        } else if let hostHeader = headers["Host"] {
            let hostParts = hostHeader.split(separator: ":")
            host = String(hostParts[0])
            if hostParts.count > 1, let p = Int(hostParts[1]) {
                port = p
            }
        }

        // Handle CONNECT method
        if method == "CONNECT" {
            let parts = uri.split(separator: ":")
            if parts.count == 2 {
                host = String(parts[0])
                port = Int(parts[1]) ?? 443
            }
        }

        return HTTPRequest(
            method: method,
            uri: uri,
            host: host,
            port: port,
            path: path,
            headers: headers,
            body: body
        )
    }

    private func parseHTTPResponse(_ data: Data) -> HTTPResponse? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }

        let lines = string.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let statusLine = lines[0].components(separatedBy: " ")
        guard statusLine.count >= 2, let statusCode = Int(statusLine[1]) else { return nil }

        var headers: [String: String] = [:]
        var headerEndIndex = 1
        for i in 1..<lines.count {
            if lines[i].isEmpty {
                headerEndIndex = i
                break
            }
            let parts = lines[i].split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        var body: String? = nil
        if headerEndIndex + 1 < lines.count {
            body = lines[(headerEndIndex + 1)...].joined(separator: "\r\n")
        }

        return HTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }
}

// MARK: - HTTP Structures

struct HTTPRequest {
    let method: String
    let uri: String
    let host: String
    let port: Int
    let path: String
    let headers: [String: String]
    let body: String?
}

struct HTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: String?
}
