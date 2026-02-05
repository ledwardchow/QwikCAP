import Foundation
import Network
import os.log

protocol ProxyConnectionDelegate: AnyObject {
    func connectionDidComplete(_ connection: ProxyConnection)
    func connection(_ connection: ProxyConnection, didCaptureTraffic entry: TrafficEntryData)
}

class ProxyConnection {
    let id = UUID()
    private let log = OSLog(subsystem: "com.qwikcap.tunnel", category: "ProxyConnection")

    private let clientConnection: NWConnection
    private var serverConnection: NWConnection?
    private weak var delegate: ProxyConnectionDelegate?

    // Configuration
    private let tlsInterceptor: TLSInterceptor?
    private let forwardToRemoteProxy: Bool
    private let remoteProxyHost: String
    private let remoteProxyPort: Int

    // State
    private var isConnectTunnel = false
    private var targetHost: String = ""
    private var targetPort: Int = 0
    private var requestStartTime: Date?
    private var currentTrafficEntry: TrafficEntryData?
    private var requestBuffer = Data()
    private var responseBuffer = Data()

    init(
        clientConnection: NWConnection,
        delegate: ProxyConnectionDelegate?,
        tlsInterceptor: TLSInterceptor?,
        forwardToRemoteProxy: Bool,
        remoteProxyHost: String,
        remoteProxyPort: Int
    ) {
        self.clientConnection = clientConnection
        self.delegate = delegate
        self.tlsInterceptor = tlsInterceptor
        self.forwardToRemoteProxy = forwardToRemoteProxy
        self.remoteProxyHost = remoteProxyHost
        self.remoteProxyPort = remoteProxyPort
    }

    func start(queue: DispatchQueue) {
        clientConnection.stateUpdateHandler = { [weak self] state in
            self?.handleClientState(state)
        }

        clientConnection.start(queue: queue)
        readFromClient()
    }

    func cancel() {
        clientConnection.cancel()
        serverConnection?.cancel()
    }

    // MARK: - Client Connection Handling

    private func handleClientState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            os_log("Client connection ready", log: log, type: .debug)
        case .failed(let error):
            os_log("Client connection failed: %{public}@", log: log, type: .error, error.localizedDescription)
            finalizeTrafficEntry(error: error.localizedDescription)
            delegate?.connectionDidComplete(self)
        case .cancelled:
            finalizeTrafficEntry()
            delegate?.connectionDidComplete(self)
        default:
            break
        }
    }

    private func readFromClient() {
        clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                os_log("Client read error: %{public}@", log: self.log, type: .error, error.localizedDescription)
                self.finalizeTrafficEntry(error: error.localizedDescription)
                self.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                self.handleClientData(data)
            }

            if isComplete {
                self.finalizeTrafficEntry()
                self.cancel()
            } else {
                self.readFromClient()
            }
        }
    }

    private func handleClientData(_ data: Data) {
        requestBuffer.append(data)

        // Try to parse the HTTP request
        guard let requestString = String(data: requestBuffer, encoding: .utf8) else {
            // Binary data, just forward it
            forwardToServer(data)
            return
        }

        // Check if we have a complete HTTP request (headers end with \r\n\r\n)
        guard requestString.contains("\r\n\r\n") else {
            // Wait for more data
            return
        }

        // Parse the request
        let httpParser = HTTPParser()
        guard let request = httpParser.parseRequest(requestBuffer) else {
            os_log("Failed to parse HTTP request", log: log, type: .error)
            forwardToServer(data)
            return
        }

        requestStartTime = Date()

        // Handle CONNECT method (HTTPS tunneling)
        if request.method == "CONNECT" {
            handleConnectRequest(request)
            return
        }

        // Create traffic entry
        let scheme = "http"
        let url = request.url.hasPrefix("http") ? request.url : "\(scheme)://\(request.host ?? "unknown")\(request.url)"

        currentTrafficEntry = TrafficEntryData(
            method: request.method,
            url: url,
            host: request.host ?? "unknown",
            path: request.url,
            scheme: scheme,
            requestHeaders: request.headers,
            requestBody: request.body
        )

        // Connect to server and forward request
        connectToServer(host: request.host ?? "", port: request.port ?? 80) { [weak self] success in
            guard let self = self, success else {
                self?.sendErrorResponse(502, message: "Bad Gateway")
                return
            }

            // Forward the request
            if self.forwardToRemoteProxy && !self.remoteProxyHost.isEmpty {
                // When forwarding to remote proxy, send the full request as-is
                self.forwardToServer(self.requestBuffer)
            } else {
                // Direct connection - rebuild request without absolute URL
                let rebuiltRequest = httpParser.rebuildRequest(request, forDirectConnection: true)
                self.forwardToServer(rebuiltRequest)
            }

            self.requestBuffer.removeAll()
        }
    }

    // MARK: - CONNECT Handling (HTTPS)

    private func handleConnectRequest(_ request: HTTPRequest) {
        isConnectTunnel = true

        // Parse host:port from CONNECT target
        let parts = request.url.split(separator: ":")
        targetHost = String(parts[0])
        targetPort = parts.count > 1 ? Int(parts[1]) ?? 443 : 443

        os_log("CONNECT request to %{public}@:%{public}d", log: log, type: .info, targetHost, targetPort)

        // If we have TLS interceptor, do MITM
        if let tlsInterceptor = tlsInterceptor {
            // Send 200 OK to client
            let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
            clientConnection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] error in
                if let error = error {
                    os_log("Failed to send CONNECT response: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                    self?.cancel()
                    return
                }

                // Start TLS interception
                self?.startTLSInterception(host: self?.targetHost ?? "", port: self?.targetPort ?? 443, interceptor: tlsInterceptor)
            })
        } else if forwardToRemoteProxy && !remoteProxyHost.isEmpty {
            // Forward CONNECT to remote proxy
            connectToServer(host: remoteProxyHost, port: remoteProxyPort) { [weak self] success in
                guard let self = self, success else {
                    self?.sendErrorResponse(502, message: "Bad Gateway")
                    return
                }

                // Forward the CONNECT request
                self.forwardToServer(self.requestBuffer)
                self.requestBuffer.removeAll()
                self.startBidirectionalForwarding()
            }
        } else {
            // Direct tunnel without interception
            connectToServer(host: targetHost, port: targetPort) { [weak self] success in
                guard let self = self, success else {
                    self?.sendErrorResponse(502, message: "Bad Gateway")
                    return
                }

                // Send 200 OK
                let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
                self.clientConnection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
                self.requestBuffer.removeAll()
                self.startBidirectionalForwarding()
            }
        }
    }

    private func startTLSInterception(host: String, port: Int, interceptor: TLSInterceptor) {
        // This is a simplified implementation
        // In production, you would:
        // 1. Upgrade client connection to TLS using generated certificate
        // 2. Connect to server with TLS
        // 3. Relay decrypted traffic

        // For now, just do passthrough
        connectToServer(host: host, port: port) { [weak self] success in
            guard success else {
                self?.sendErrorResponse(502, message: "Bad Gateway")
                return
            }
            self?.startBidirectionalForwarding()
        }
    }

    // MARK: - Server Connection

    private func connectToServer(host: String, port: Int, completion: @escaping (Bool) -> Void) {
        let actualHost: String
        let actualPort: Int

        if forwardToRemoteProxy && !remoteProxyHost.isEmpty && !isConnectTunnel {
            actualHost = remoteProxyHost
            actualPort = remoteProxyPort
        } else {
            actualHost = host
            actualPort = port
        }

        os_log("Connecting to server %{public}@:%{public}d", log: log, type: .debug, actualHost, actualPort)

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(actualHost), port: NWEndpoint.Port(integerLiteral: UInt16(actualPort)))
        let parameters = NWParameters.tcp

        serverConnection = NWConnection(to: endpoint, using: parameters)

        serverConnection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                completion(true)
                self?.readFromServer()
            case .failed(let error):
                os_log("Server connection failed: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                completion(false)
            case .cancelled:
                break
            default:
                break
            }
        }

        serverConnection?.start(queue: DispatchQueue(label: "com.qwikcap.server.\(id.uuidString)"))
    }

    private func forwardToServer(_ data: Data) {
        serverConnection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                os_log("Server send error: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
            }
        })
    }

    private func readFromServer() {
        serverConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                os_log("Server read error: %{public}@", log: self.log, type: .error, error.localizedDescription)
                self.finalizeTrafficEntry(error: error.localizedDescription)
                self.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                self.handleServerData(data)
            }

            if isComplete {
                self.finalizeTrafficEntry()
                self.cancel()
            } else {
                self.readFromServer()
            }
        }
    }

    private func handleServerData(_ data: Data) {
        responseBuffer.append(data)

        // Try to parse response headers for traffic entry
        if currentTrafficEntry != nil && currentTrafficEntry?.statusCode == nil {
            if let responseString = String(data: responseBuffer, encoding: .utf8),
               responseString.contains("\r\n") {
                let httpParser = HTTPParser()
                if let response = httpParser.parseResponse(responseBuffer) {
                    currentTrafficEntry?.statusCode = response.statusCode
                    currentTrafficEntry?.responseHeaders = response.headers
                }
            }
        }

        // Forward to client
        clientConnection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                os_log("Client send error: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
            }
        })
    }

    // MARK: - Bidirectional Forwarding (for tunnels)

    private func startBidirectionalForwarding() {
        // Already reading from client in readFromClient
        // Server reads handled by readFromServer
    }

    // MARK: - Error Response

    private func sendErrorResponse(_ code: Int, message: String) {
        let body = "<html><body><h1>\(code) \(message)</h1></body></html>"
        let response = """
            HTTP/1.1 \(code) \(message)\r
            Content-Type: text/html\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r
            \(body)
            """

        clientConnection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }

    // MARK: - Traffic Entry

    private func finalizeTrafficEntry(error: String? = nil) {
        guard var entry = currentTrafficEntry else { return }

        if let startTime = requestStartTime {
            entry.duration = Date().timeIntervalSince(startTime)
        }

        if let error = error {
            entry.error = error
        }

        // Limit response body size
        let maxBodySize = 100_000  // 100KB for extension memory limits
        if responseBuffer.count > 0 && responseBuffer.count <= maxBodySize {
            entry.responseBody = responseBuffer
        } else if responseBuffer.count > maxBodySize {
            entry.responseBody = responseBuffer.prefix(maxBodySize)
        }

        delegate?.connection(self, didCaptureTraffic: entry)
        currentTrafficEntry = nil
    }
}
