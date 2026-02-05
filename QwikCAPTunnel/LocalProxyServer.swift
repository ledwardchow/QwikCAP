import Foundation
import Network
import os.log

protocol LocalProxyServerDelegate: AnyObject {
    func proxyServer(_ server: LocalProxyServer, didReceiveTraffic entry: TrafficEntryData)
}

class LocalProxyServer {
    private let log = OSLog(subsystem: "com.qwikcap.tunnel", category: "LocalProxyServer")

    private var listener: NWListener?
    private let port: UInt16
    private var connections: [UUID: ProxyConnection] = [:]
    private let queue = DispatchQueue(label: "com.qwikcap.localproxy", qos: .userInitiated)
    private let connectionsLock = NSLock()

    weak var delegate: LocalProxyServerDelegate?

    // Configuration
    var forwardToRemoteProxy: Bool = false
    var remoteProxyHost: String = ""
    var remoteProxyPort: Int = 8080
    var tlsInterceptor: TLSInterceptor?

    init(port: UInt16 = 9090) {
        self.port = port
    }

    // MARK: - Lifecycle

    func start() throws {
        os_log("Starting local proxy server on port %{public}d", log: log, type: .info, port)

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ProxyServerError.invalidPort
        }

        listener = try NWListener(using: parameters, on: nwPort)

        listener?.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        os_log("Stopping local proxy server", log: log, type: .info)

        listener?.cancel()
        listener = nil

        connectionsLock.lock()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        connectionsLock.unlock()
    }

    // MARK: - Connection Handling

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            os_log("Local proxy server ready on port %{public}d", log: log, type: .info, port)
        case .failed(let error):
            os_log("Local proxy server failed: %{public}@", log: log, type: .error, error.localizedDescription)
        case .cancelled:
            os_log("Local proxy server cancelled", log: log, type: .info)
        default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let proxyConnection = ProxyConnection(
            clientConnection: connection,
            delegate: self,
            tlsInterceptor: tlsInterceptor,
            forwardToRemoteProxy: forwardToRemoteProxy,
            remoteProxyHost: remoteProxyHost,
            remoteProxyPort: remoteProxyPort
        )

        connectionsLock.lock()
        connections[proxyConnection.id] = proxyConnection
        connectionsLock.unlock()

        proxyConnection.start(queue: queue)

        os_log("New connection: %{public}@", log: log, type: .debug, proxyConnection.id.uuidString)
    }
}

// MARK: - ProxyConnectionDelegate

extension LocalProxyServer: ProxyConnectionDelegate {
    func connectionDidComplete(_ connection: ProxyConnection) {
        connectionsLock.lock()
        connections.removeValue(forKey: connection.id)
        connectionsLock.unlock()

        os_log("Connection completed: %{public}@", log: log, type: .debug, connection.id.uuidString)
    }

    func connection(_ connection: ProxyConnection, didCaptureTraffic entry: TrafficEntryData) {
        delegate?.proxyServer(self, didReceiveTraffic: entry)
    }
}

// MARK: - Proxy Server Error

enum ProxyServerError: Error, LocalizedError {
    case invalidPort
    case listenerFailed(Error)
    case connectionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidPort: return "Invalid port number"
        case .listenerFailed(let error): return "Listener failed: \(error.localizedDescription)"
        case .connectionFailed(let error): return "Connection failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Traffic Entry Data (Lightweight for Extension)

struct TrafficEntryData {
    let id: UUID
    let timestamp: Date
    let method: String
    let url: String
    let host: String
    let path: String
    let scheme: String
    var statusCode: Int?
    let requestHeaders: [String: String]
    let requestBody: Data?
    var responseHeaders: [String: String]?
    var responseBody: Data?
    var duration: TimeInterval?
    var error: String?
    let connectionId: UUID

    init(
        method: String,
        url: String,
        host: String,
        path: String,
        scheme: String,
        requestHeaders: [String: String],
        requestBody: Data? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.method = method
        self.url = url
        self.host = host
        self.path = path
        self.scheme = scheme
        self.statusCode = nil
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.responseHeaders = nil
        self.responseBody = nil
        self.duration = nil
        self.error = nil
        self.connectionId = UUID()
    }
}
