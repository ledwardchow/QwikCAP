import Foundation
import Network
import Security
import os.log

class TLSHandler {
    private let log = OSLog(subsystem: "com.qwikcap.tunnel", category: "TLSHandler")

    private let connectionManager: ConnectionManager
    private let appGroupID = "group.com.qwikcap.app"

    private var caPrivateKey: SecKey?
    private var caCertificateData: Data?

    // Cache for generated host certificates
    private var certificateCache: [String: (identity: SecIdentity, certificate: SecCertificate)] = [:]
    private let cacheLock = NSLock()

    private let queue = DispatchQueue(label: "com.qwikcap.tlshandler", qos: .userInitiated)

    init(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager
        loadCACertificate()
    }

    // MARK: - CA Certificate Loading

    private func loadCACertificate() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            os_log("Failed to access app group container", log: log, type: .error)
            return
        }

        let keyPath = containerURL.appendingPathComponent("ca_private_key.der")
        let certPath = containerURL.appendingPathComponent("ca_certificate.der")

        do {
            let keyData = try Data(contentsOf: keyPath)
            let certData = try Data(contentsOf: certPath)

            // Load private key
            let keyAttributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: 2048
            ]

            var error: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateWithData(keyData as CFData, keyAttributes as CFDictionary, &error) else {
                os_log("Failed to load CA private key: %{public}@", log: log, type: .error, error?.takeRetainedValue().localizedDescription ?? "Unknown")
                return
            }

            caPrivateKey = privateKey
            caCertificateData = certData

            os_log("CA certificate loaded successfully", log: log, type: .info)
        } catch {
            os_log("Failed to load CA certificate files: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }

    // MARK: - TLS Interception

    func interceptTLS(
        clientConnection: NWConnection,
        serverConnection: NWConnection,
        host: String,
        port: Int,
        connectionId: String
    ) {
        // Generate or retrieve certificate for this host
        guard let identity = getOrCreateIdentity(forHost: host) else {
            os_log("Failed to get identity for host: %{public}@", log: log, type: .error, host)
            // Fall back to simple tunneling without interception
            startPassthroughTunnel(clientConnection: clientConnection, serverConnection: serverConnection)
            return
        }

        // Create TLS options for client connection
        let tlsOptions = NWProtocolTLS.Options()

        // Set our identity
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, sec_identity_create(identity)!)

        // Create new parameters with TLS (used for future connection upgrades)
        _ = NWParameters(tls: tlsOptions)

        os_log("Starting TLS interception for %{public}@", log: log, type: .debug, host)

        // Start TLS handshake with client
        startClientTLSHandshake(
            clientConnection: clientConnection,
            serverConnection: serverConnection,
            host: host,
            port: port,
            connectionId: connectionId,
            identity: identity
        )
    }

    private func startClientTLSHandshake(
        clientConnection: NWConnection,
        serverConnection: NWConnection,
        host: String,
        port: Int,
        connectionId: String,
        identity: SecIdentity
    ) {
        // For NWConnection, we need to create a new connection with TLS
        // This is a simplified version - in production, you'd use a proper TLS library

        // Start bidirectional relay with logging
        startInterceptingRelay(
            clientConnection: clientConnection,
            serverConnection: serverConnection,
            host: host,
            port: port,
            connectionId: connectionId
        )
    }

    private func startInterceptingRelay(
        clientConnection: NWConnection,
        serverConnection: NWConnection,
        host: String,
        port: Int,
        connectionId: String
    ) {
        // Client -> Server (with logging)
        func relayClientToServer() {
            clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }

                if let data = data, !data.isEmpty {
                    // Try to parse as HTTP request
                    if let requestString = String(data: data, encoding: .utf8) {
                        self.parseAndLogHTTPSRequest(requestString, host: host, port: port, connectionId: connectionId)
                    }

                    serverConnection.send(content: data, completion: .contentProcessed { error in
                        if error == nil && !isComplete {
                            relayClientToServer()
                        }
                    })
                } else if isComplete || error != nil {
                    serverConnection.cancel()
                }
            }
        }

        // Server -> Client (with logging)
        func relayServerToClient() {
            serverConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }

                if let data = data, !data.isEmpty {
                    // Try to parse as HTTP response
                    if let responseString = String(data: data, encoding: .utf8) {
                        self.parseAndLogHTTPSResponse(responseString, connectionId: connectionId)
                    }

                    clientConnection.send(content: data, completion: .contentProcessed { error in
                        if error == nil && !isComplete {
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

    private func startPassthroughTunnel(clientConnection: NWConnection, serverConnection: NWConnection) {
        // Simple bidirectional tunnel without interception
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

    // MARK: - Certificate Generation

    private func getOrCreateIdentity(forHost host: String) -> SecIdentity? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        // Check cache
        if let cached = certificateCache[host] {
            return cached.identity
        }

        // Generate new certificate
        guard caPrivateKey != nil else {
            os_log("CA private key not available", log: log, type: .error)
            return nil
        }

        do {
            var hostPrivateKey: SecKey?
            let certData = try generateHostCertificate(forHost: host, privateKey: &hostPrivateKey)

            guard let privateKey = hostPrivateKey else {
                os_log("Failed to generate host private key", log: log, type: .error)
                return nil
            }

            // Create SecCertificate
            guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
                os_log("Failed to create SecCertificate", log: log, type: .error)
                return nil
            }

            // Create identity
            guard let identity = createIdentity(certificate: certificate, privateKey: privateKey) else {
                os_log("Failed to create identity", log: log, type: .error)
                return nil
            }

            certificateCache[host] = (identity, certificate)
            return identity

        } catch {
            os_log("Failed to generate host certificate: %{public}@", log: log, type: .error, error.localizedDescription)
            return nil
        }
    }

    private func generateHostCertificate(forHost host: String, privateKey: inout SecKey?) throws -> Data {
        guard let caKey = caPrivateKey else {
            throw TLSError.caNotLoaded
        }

        // Generate RSA key pair for host
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false
        ]

        var error: Unmanaged<CFError>?
        guard let hostPrivateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error) else {
            throw TLSError.keyGenerationFailed(error?.takeRetainedValue().localizedDescription ?? "Unknown")
        }

        guard let hostPublicKey = SecKeyCopyPublicKey(hostPrivateKey) else {
            throw TLSError.publicKeyExtractionFailed
        }

        privateKey = hostPrivateKey

        // Build certificate
        var certBuilder = TLSCertificateBuilder()
        certBuilder.serialNumber = generateSerialNumber()
        certBuilder.issuerCN = "QwikCAP Root CA"
        certBuilder.issuerO = "QwikCAP"
        certBuilder.issuerC = "US"
        certBuilder.subjectCN = host
        certBuilder.subjectO = "QwikCAP Generated"
        certBuilder.subjectC = "US"
        certBuilder.notBefore = Date()
        certBuilder.notAfter = Date().addingTimeInterval(365 * 24 * 60 * 60)
        certBuilder.publicKey = hostPublicKey
        certBuilder.isCA = false
        certBuilder.subjectAltNames = [host]

        return try certBuilder.build(signingKey: caKey)
    }

    private func generateSerialNumber() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] = bytes[0] & 0x7F
        return Data(bytes)
    }

    private func createIdentity(certificate: SecCertificate, privateKey: SecKey) -> SecIdentity? {
        // Store certificate and key temporarily in keychain
        let certTag = "com.qwikcap.temp.cert.\(UUID().uuidString)"
        let keyTag = "com.qwikcap.temp.key.\(UUID().uuidString)"

        // Add certificate to keychain
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: certTag
        ]
        SecItemDelete(certQuery as CFDictionary)
        var status = SecItemAdd(certQuery as CFDictionary, nil)
        guard status == errSecSuccess else { return nil }

        // Add private key to keychain
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrLabel as String: certTag
        ]
        SecItemDelete(keyQuery as CFDictionary)
        status = SecItemAdd(keyQuery as CFDictionary, nil)
        guard status == errSecSuccess else { return nil }

        // Retrieve identity
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: certTag,
            kSecReturnRef as String: true
        ]

        var identityRef: CFTypeRef?
        status = SecItemCopyMatching(identityQuery as CFDictionary, &identityRef)

        // Clean up temporary items
        SecItemDelete(certQuery as CFDictionary)
        SecItemDelete(keyQuery as CFDictionary)

        guard status == errSecSuccess else { return nil }
        return (identityRef as! SecIdentity)
    }

    // MARK: - HTTP Parsing and Logging

    private func parseAndLogHTTPSRequest(_ data: String, host: String, port: Int, connectionId: String) {
        let lines = data.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return }

        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 2 else { return }

        let method = requestLine[0]
        let path = requestLine[1]

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

        connectionManager.logRequest(
            connectionId: connectionId,
            method: method,
            host: host,
            port: port,
            path: path,
            headers: headers,
            body: body,
            isHTTPS: true
        )
    }

    private func parseAndLogHTTPSResponse(_ data: String, connectionId: String) {
        let lines = data.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return }

        let statusLine = lines[0].components(separatedBy: " ")
        guard statusLine.count >= 2, let statusCode = Int(statusLine[1]) else { return }

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

        connectionManager.logResponse(
            connectionId: connectionId,
            statusCode: statusCode,
            headers: headers,
            body: body
        )
    }
}

// MARK: - Certificate Builder for TLS

struct TLSCertificateBuilder {
    var serialNumber: Data = Data()
    var issuerCN: String = ""
    var issuerO: String = ""
    var issuerC: String = ""
    var subjectCN: String = ""
    var subjectO: String = ""
    var subjectC: String = ""
    var notBefore: Date = Date()
    var notAfter: Date = Date()
    var publicKey: SecKey?
    var isCA: Bool = false
    var subjectAltNames: [String] = []

    func build(signingKey: SecKey) throws -> Data {
        var tbsCertificate = Data()

        // Version (v3 = 2)
        tbsCertificate.append(contentsOf: TDER.contextTag(0, content: TDER.integer(2)))

        // Serial Number
        tbsCertificate.append(contentsOf: TDER.integer(serialNumber))

        // Signature Algorithm
        tbsCertificate.append(contentsOf: TDER.sequence([
            TDER.objectIdentifier([1, 2, 840, 113549, 1, 1, 11]),
            TDER.null()
        ]))

        // Issuer
        tbsCertificate.append(contentsOf: buildName(cn: issuerCN, o: issuerO, c: issuerC))

        // Validity
        tbsCertificate.append(contentsOf: TDER.sequence([
            TDER.utcTime(notBefore),
            TDER.utcTime(notAfter)
        ]))

        // Subject
        tbsCertificate.append(contentsOf: buildName(cn: subjectCN, o: subjectO, c: subjectC))

        // Subject Public Key Info
        guard let pubKey = publicKey else {
            throw TLSError.publicKeyExtractionFailed
        }
        var error: Unmanaged<CFError>?
        guard let pubKeyData = SecKeyCopyExternalRepresentation(pubKey, &error) as Data? else {
            throw TLSError.keyExportFailed
        }
        tbsCertificate.append(contentsOf: buildSubjectPublicKeyInfo(pubKeyData))

        // Extensions
        var extensions = Data()
        extensions.append(contentsOf: buildBasicConstraintsExtension(isCA: isCA))
        extensions.append(contentsOf: buildKeyUsageExtension(isCA: isCA))

        if !isCA {
            extensions.append(contentsOf: buildExtendedKeyUsageExtension())
        }

        if !subjectAltNames.isEmpty {
            extensions.append(contentsOf: buildSANExtension(subjectAltNames))
        }

        tbsCertificate.append(contentsOf: TDER.contextTag(3, content: TDER.sequence(extensions)))

        let tbsCertificateSequence = TDER.sequence(tbsCertificate)

        // Sign
        let signature = try sign(data: tbsCertificateSequence, with: signingKey)

        // Build final certificate
        var certificate = Data()
        certificate.append(contentsOf: tbsCertificateSequence)
        certificate.append(contentsOf: TDER.sequence([
            TDER.objectIdentifier([1, 2, 840, 113549, 1, 1, 11]),
            TDER.null()
        ]))
        certificate.append(contentsOf: TDER.bitString(signature))

        return TDER.sequence(certificate)
    }

    private func buildName(cn: String, o: String, c: String) -> Data {
        var rdnSequence = Data()
        rdnSequence.append(contentsOf: TDER.set([
            TDER.sequence([TDER.objectIdentifier([2, 5, 4, 6]), TDER.printableString(c)])
        ]))
        rdnSequence.append(contentsOf: TDER.set([
            TDER.sequence([TDER.objectIdentifier([2, 5, 4, 10]), TDER.utf8String(o)])
        ]))
        rdnSequence.append(contentsOf: TDER.set([
            TDER.sequence([TDER.objectIdentifier([2, 5, 4, 3]), TDER.utf8String(cn)])
        ]))
        return TDER.sequence(rdnSequence)
    }

    private func buildSubjectPublicKeyInfo(_ pubKeyData: Data) -> Data {
        let algorithmIdentifier = TDER.sequence([
            TDER.objectIdentifier([1, 2, 840, 113549, 1, 1, 1]),
            TDER.null()
        ])
        return TDER.sequence([algorithmIdentifier, TDER.bitString(pubKeyData)])
    }

    private func buildBasicConstraintsExtension(isCA: Bool) -> Data {
        let oid = TDER.objectIdentifier([2, 5, 29, 19])
        let critical = TDER.boolean(true)
        let value = TDER.octetString(TDER.sequence(isCA ? [TDER.boolean(true)] : []))
        return TDER.sequence([oid, critical, value])
    }

    private func buildKeyUsageExtension(isCA: Bool) -> Data {
        let oid = TDER.objectIdentifier([2, 5, 29, 15])
        let critical = TDER.boolean(true)
        let usage: UInt8 = isCA ? 0x06 : 0xA0
        let value = TDER.octetString(TDER.bitString(Data([usage])))
        return TDER.sequence([oid, critical, value])
    }

    private func buildExtendedKeyUsageExtension() -> Data {
        let oid = TDER.objectIdentifier([2, 5, 29, 37])
        let value = TDER.octetString(TDER.sequence([
            TDER.objectIdentifier([1, 3, 6, 1, 5, 5, 7, 3, 1]),
            TDER.objectIdentifier([1, 3, 6, 1, 5, 5, 7, 3, 2])
        ]))
        return TDER.sequence([oid, value])
    }

    private func buildSANExtension(_ names: [String]) -> Data {
        let oid = TDER.objectIdentifier([2, 5, 29, 17])
        var sanData = Data()
        for name in names {
            if isIPAddress(name) {
                sanData.append(contentsOf: TDER.contextTagImplicit(7, content: ipToBytes(name)))
            } else {
                sanData.append(contentsOf: TDER.contextTagImplicit(2, content: Data(name.utf8)))
            }
        }
        let value = TDER.octetString(TDER.sequence(sanData))
        return TDER.sequence([oid, value])
    }

    private func isIPAddress(_ string: String) -> Bool {
        var sin = sockaddr_in()
        var sin6 = sockaddr_in6()
        return string.withCString { cstring in
            inet_pton(AF_INET, cstring, &sin.sin_addr) == 1 ||
            inet_pton(AF_INET6, cstring, &sin6.sin6_addr) == 1
        }
    }

    private func ipToBytes(_ ip: String) -> Data {
        var sin = sockaddr_in()
        if inet_pton(AF_INET, ip, &sin.sin_addr) == 1 {
            return withUnsafeBytes(of: sin.sin_addr) { Data($0) }
        }
        var sin6 = sockaddr_in6()
        if inet_pton(AF_INET6, ip, &sin6.sin6_addr) == 1 {
            return withUnsafeBytes(of: sin6.sin6_addr) { Data($0) }
        }
        return Data()
    }

    private func sign(data: Data, with privateKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data? else {
            throw TLSError.signingFailed
        }
        return signature
    }
}

// MARK: - DER Encoding (for TLS)

enum TDER {
    static func sequence(_ content: Data) -> Data { tag(0x30, content: content) }
    static func sequence(_ contents: [Data]) -> Data {
        var data = Data()
        for content in contents { data.append(content) }
        return sequence(data)
    }
    static func set(_ contents: [Data]) -> Data {
        var data = Data()
        for content in contents { data.append(content) }
        return tag(0x31, content: data)
    }
    static func integer(_ value: Int) -> Data {
        var bytes = [UInt8]()
        var v = value
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0x00, at: 0) }
        return tag(0x02, content: Data(bytes))
    }
    static func integer(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        if bytes.isEmpty || bytes[0] & 0x80 != 0 { bytes.insert(0x00, at: 0) }
        return tag(0x02, content: Data(bytes))
    }
    static func bitString(_ data: Data) -> Data {
        var content = Data([0x00])
        content.append(data)
        return tag(0x03, content: content)
    }
    static func octetString(_ data: Data) -> Data { tag(0x04, content: data) }
    static func null() -> Data { Data([0x05, 0x00]) }
    static func objectIdentifier(_ components: [Int]) -> Data {
        var bytes = [UInt8]()
        if components.count >= 2 {
            bytes.append(UInt8(components[0] * 40 + components[1]))
            for i in 2..<components.count {
                let value = components[i]
                if value < 128 {
                    bytes.append(UInt8(value))
                } else {
                    var temp = [UInt8]()
                    var v = value
                    while v > 0 {
                        temp.insert(UInt8((v & 0x7F) | (temp.isEmpty ? 0 : 0x80)), at: 0)
                        v >>= 7
                    }
                    bytes.append(contentsOf: temp)
                }
            }
        }
        return tag(0x06, content: Data(bytes))
    }
    static func utf8String(_ string: String) -> Data { tag(0x0C, content: Data(string.utf8)) }
    static func printableString(_ string: String) -> Data { tag(0x13, content: Data(string.utf8)) }
    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return tag(0x17, content: Data(formatter.string(from: date).utf8))
    }
    static func boolean(_ value: Bool) -> Data { tag(0x01, content: Data([value ? 0xFF : 0x00])) }
    static func contextTag(_ tag: UInt8, content: Data) -> Data { TDER.tag(0xA0 | tag, content: content) }
    static func contextTagImplicit(_ tag: UInt8, content: Data) -> Data { TDER.tag(0x80 | tag, content: content) }
    static func tag(_ tag: UInt8, content: Data) -> Data {
        var result = Data([tag])
        result.append(contentsOf: encodeLength(content.count))
        result.append(content)
        return result
    }
    private static func encodeLength(_ length: Int) -> Data {
        if length < 128 { return Data([UInt8(length)]) }
        else if length < 256 { return Data([0x81, UInt8(length)]) }
        else if length < 65536 { return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)]) }
        else { return Data([0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]) }
    }
}

// MARK: - Errors

enum TLSError: Error {
    case caNotLoaded
    case keyGenerationFailed(String)
    case publicKeyExtractionFailed
    case keyExportFailed
    case signingFailed
}
