import Foundation
import Network

class ProxyForwarder {
    static let shared = ProxyForwarder()

    private var activeConnections: [String: ProxyConnection] = [:]
    private let connectionsLock = NSLock()
    private let queue = DispatchQueue(label: "com.qwikcap.proxyforwarder", qos: .userInitiated)

    private init() {}

    // MARK: - Connection Forwarding

    func forwardRequest(
        _ request: Data,
        toHost host: String,
        port: Int,
        useTLS: Bool,
        connectionId: String,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let proxyConfig = ProxyConfiguration.shared

        // If upstream proxy is configured, connect through it
        if proxyConfig.isConfigured {
            forwardThroughProxy(
                request,
                targetHost: host,
                targetPort: port,
                useTLS: useTLS,
                proxyHost: proxyConfig.proxyHost,
                proxyPort: proxyConfig.proxyPort,
                connectionId: connectionId,
                completion: completion
            )
        } else {
            forwardDirect(
                request,
                host: host,
                port: port,
                useTLS: useTLS,
                connectionId: connectionId,
                completion: completion
            )
        }
    }

    private func forwardThroughProxy(
        _ request: Data,
        targetHost: String,
        targetPort: Int,
        useTLS: Bool,
        proxyHost: String,
        proxyPort: Int,
        connectionId: String,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxyHost),
            port: NWEndpoint.Port(integerLiteral: UInt16(proxyPort))
        )

        let connection = NWConnection(to: endpoint, using: .tcp)
        let proxyConnection = ProxyConnection(
            id: connectionId,
            connection: connection,
            targetHost: targetHost,
            targetPort: targetPort,
            useTLS: useTLS
        )

        storeConnection(proxyConnection)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if useTLS {
                    // Send CONNECT request for HTTPS
                    self?.sendConnectRequest(
                        proxyConnection: proxyConnection,
                        request: request,
                        completion: completion
                    )
                } else {
                    // Forward HTTP request directly
                    self?.sendRequest(
                        proxyConnection: proxyConnection,
                        request: request,
                        completion: completion
                    )
                }

            case .failed(let error):
                self?.removeConnection(connectionId)
                completion(.failure(error))

            case .cancelled:
                self?.removeConnection(connectionId)

            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func sendConnectRequest(
        proxyConnection: ProxyConnection,
        request: Data,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let connectRequest = "CONNECT \(proxyConnection.targetHost):\(proxyConnection.targetPort) HTTP/1.1\r\n" +
                           "Host: \(proxyConnection.targetHost):\(proxyConnection.targetPort)\r\n\r\n"

        proxyConnection.connection.send(content: connectRequest.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            if let error = error {
                completion(.failure(error))
                return
            }

            // Wait for 200 response
            proxyConnection.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }

                guard let data = data,
                      let response = String(data: data, encoding: .utf8),
                      response.contains("200") else {
                    completion(.failure(ProxyError.tunnelFailed))
                    return
                }

                // Now send the actual request
                self?.sendRequest(proxyConnection: proxyConnection, request: request, completion: completion)
            }
        })
    }

    private func sendRequest(
        proxyConnection: ProxyConnection,
        request: Data,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        proxyConnection.connection.send(content: request, completion: .contentProcessed { error in
            if let error = error {
                completion(.failure(error))
                return
            }

            // Receive response
            self.receiveResponse(proxyConnection: proxyConnection, completion: completion)
        })
    }

    private func receiveResponse(
        proxyConnection: ProxyConnection,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        var responseData = Data()

        func receiveMore() {
            proxyConnection.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                if let error = error {
                    completion(.failure(error))
                    self?.removeConnection(proxyConnection.id)
                    return
                }

                if let data = data {
                    responseData.append(data)
                }

                if isComplete {
                    completion(.success(responseData))
                    self?.removeConnection(proxyConnection.id)
                } else {
                    // Check if we have complete HTTP response
                    if self?.isCompleteResponse(responseData) == true {
                        completion(.success(responseData))
                        // Don't close for keep-alive
                    } else {
                        receiveMore()
                    }
                }
            }
        }

        receiveMore()
    }

    private func forwardDirect(
        _ request: Data,
        host: String,
        port: Int,
        useTLS: Bool,
        connectionId: String,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port))
        )

        let parameters: NWParameters = useTLS ? .tls : .tcp
        let connection = NWConnection(to: endpoint, using: parameters)

        let proxyConnection = ProxyConnection(
            id: connectionId,
            connection: connection,
            targetHost: host,
            targetPort: port,
            useTLS: useTLS
        )

        storeConnection(proxyConnection)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.sendRequest(proxyConnection: proxyConnection, request: request, completion: completion)
            case .failed(let error):
                self?.removeConnection(connectionId)
                completion(.failure(error))
            case .cancelled:
                self?.removeConnection(connectionId)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    // MARK: - Response Parsing

    private func isCompleteResponse(_ data: Data) -> Bool {
        guard let headerEndIndex = HTTPParser.extractHeadersEndIndex(data) else {
            return false
        }

        // Check for Content-Length
        if let contentLength = HTTPParser.extractContentLength(data) {
            let bodyLength = data.count - headerEndIndex
            return bodyLength >= contentLength
        }

        // Check for chunked encoding
        if HTTPParser.isChunkedEncoding(data) {
            // Look for final chunk marker
            let bodyData = data.suffix(from: headerEndIndex)
            if let bodyString = String(data: bodyData, encoding: .utf8) {
                return bodyString.contains("0\r\n\r\n")
            }
        }

        // No content-length and not chunked - assume complete after headers
        return true
    }

    // MARK: - Connection Management

    private func storeConnection(_ connection: ProxyConnection) {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        activeConnections[connection.id] = connection
    }

    private func removeConnection(_ id: String) {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        if let connection = activeConnections.removeValue(forKey: id) {
            connection.connection.cancel()
        }
    }

    func closeAllConnections() {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }

        for connection in activeConnections.values {
            connection.connection.cancel()
        }
        activeConnections.removeAll()
    }

    // MARK: - WebSocket Forwarding

    func forwardWebSocket(
        clientData: Data,
        toHost host: String,
        port: Int,
        useTLS: Bool,
        connectionId: String,
        onServerData: @escaping (Data) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        let proxyConfig = ProxyConfiguration.shared

        let actualHost = proxyConfig.isConfigured ? proxyConfig.proxyHost : host
        let actualPort = proxyConfig.isConfigured ? proxyConfig.proxyPort : port

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(actualHost),
            port: NWEndpoint.Port(integerLiteral: UInt16(actualPort))
        )

        let parameters: NWParameters = (useTLS && !proxyConfig.isConfigured) ? .tls : .tcp
        let connection = NWConnection(to: endpoint, using: parameters)

        let proxyConnection = ProxyConnection(
            id: connectionId,
            connection: connection,
            targetHost: host,
            targetPort: port,
            useTLS: useTLS
        )

        storeConnection(proxyConnection)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if proxyConfig.isConfigured && useTLS {
                    // Need to establish tunnel first
                    self?.establishWebSocketTunnel(
                        proxyConnection: proxyConnection,
                        initialData: clientData,
                        onServerData: onServerData,
                        onError: onError
                    )
                } else {
                    // Send data directly
                    connection.send(content: clientData, completion: .contentProcessed { error in
                        if let error = error {
                            onError(error)
                            return
                        }
                        self?.startWebSocketRelay(connection: connection, onServerData: onServerData, onError: onError)
                    })
                }

            case .failed(let error):
                self?.removeConnection(connectionId)
                onError(error)

            case .cancelled:
                self?.removeConnection(connectionId)

            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func establishWebSocketTunnel(
        proxyConnection: ProxyConnection,
        initialData: Data,
        onServerData: @escaping (Data) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        let connectRequest = "CONNECT \(proxyConnection.targetHost):\(proxyConnection.targetPort) HTTP/1.1\r\n" +
                           "Host: \(proxyConnection.targetHost):\(proxyConnection.targetPort)\r\n\r\n"

        proxyConnection.connection.send(content: connectRequest.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            if let error = error {
                onError(error)
                return
            }

            proxyConnection.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error = error {
                    onError(error)
                    return
                }

                guard let data = data,
                      let response = String(data: data, encoding: .utf8),
                      response.contains("200") else {
                    onError(ProxyError.tunnelFailed)
                    return
                }

                // Send initial WebSocket handshake
                proxyConnection.connection.send(content: initialData, completion: .contentProcessed { error in
                    if let error = error {
                        onError(error)
                        return
                    }
                    self?.startWebSocketRelay(connection: proxyConnection.connection, onServerData: onServerData, onError: onError)
                })
            }
        })
    }

    private func startWebSocketRelay(
        connection: NWConnection,
        onServerData: @escaping (Data) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error = error {
                    onError(error)
                    return
                }

                if let data = data, !data.isEmpty {
                    onServerData(data)
                }

                if !isComplete {
                    receiveMore()
                }
            }
        }

        receiveMore()
    }
}

// MARK: - Proxy Connection

class ProxyConnection {
    let id: String
    let connection: NWConnection
    let targetHost: String
    let targetPort: Int
    let useTLS: Bool

    init(id: String, connection: NWConnection, targetHost: String, targetPort: Int, useTLS: Bool) {
        self.id = id
        self.connection = connection
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.useTLS = useTLS
    }
}

// MARK: - Errors

enum ProxyError: Error, LocalizedError {
    case tunnelFailed
    case connectionFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .tunnelFailed: return "Failed to establish tunnel to proxy"
        case .connectionFailed: return "Connection to target failed"
        case .invalidResponse: return "Invalid response from server"
        }
    }
}
