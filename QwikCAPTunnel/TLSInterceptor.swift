import Foundation
import Security
import Network
import os.log

class TLSInterceptor {
    private let log = OSLog(subsystem: "com.qwikcap.tunnel", category: "TLSInterceptor")

    private var caCertificate: SecCertificate?
    private var caPrivateKey: SecKey?
    private var certificateCache: [String: (SecIdentity, Date)] = [:]
    private let cacheLock = NSLock()
    private let cacheMaxAge: TimeInterval = 3600  // 1 hour

    private let appGroupID = "group.com.qwikcap.app"
    private let caKeyTag = "com.qwikcap.ca.privatekey"
    private let caCertKey = "com.qwikcap.ca.certificate"

    var isReady: Bool {
        return caCertificate != nil && caPrivateKey != nil
    }

    init() {
        loadCACertificate()
    }

    // MARK: - CA Certificate Loading

    func loadCACertificate() {
        // Load certificate from UserDefaults (shared via app group)
        let defaults = UserDefaults(suiteName: appGroupID)
        guard let certData = defaults?.data(forKey: caCertKey),
              let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            os_log("No CA certificate found in app group", log: log, type: .info)
            return
        }

        // Load private key from Keychain
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: caKeyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true,
            kSecAttrAccessGroup as String: appGroupID
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(keyQuery as CFDictionary, &item)

        guard status == errSecSuccess else {
            os_log("Failed to load CA private key: %{public}d", log: log, type: .error, status)
            return
        }

        caCertificate = certificate
        caPrivateKey = (item as! SecKey)

        os_log("CA certificate loaded successfully", log: log, type: .info)
    }

    // MARK: - Certificate Generation for Host

    func getIdentityForHost(_ hostname: String) throws -> SecIdentity {
        // Check cache
        cacheLock.lock()
        if let (identity, timestamp) = certificateCache[hostname] {
            if Date().timeIntervalSince(timestamp) < cacheMaxAge {
                cacheLock.unlock()
                return identity
            }
            certificateCache.removeValue(forKey: hostname)
        }
        cacheLock.unlock()

        // Generate new certificate
        let identity = try generateIdentityForHost(hostname)

        // Cache it
        cacheLock.lock()
        certificateCache[hostname] = (identity, Date())
        cacheLock.unlock()

        return identity
    }

    private func generateIdentityForHost(_ hostname: String) throws -> SecIdentity {
        guard let caCertificate = caCertificate, let caPrivateKey = caPrivateKey else {
            throw TLSInterceptorError.caCertificateNotLoaded
        }

        // Generate new key pair for this host
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false
            ]
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error) else {
            throw TLSInterceptorError.keyGenerationFailed(error?.takeRetainedValue().localizedDescription ?? "Unknown")
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw TLSInterceptorError.publicKeyExtractionFailed
        }

        // Generate certificate signed by CA
        let certData = try createHostCertificateData(
            hostname: hostname,
            publicKey: publicKey,
            signingKey: caPrivateKey
        )

        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw TLSInterceptorError.certificateCreationFailed
        }

        // Create identity from certificate and private key
        let identity = try createIdentity(certificate: certificate, privateKey: privateKey)

        return identity
    }

    private func createIdentity(certificate: SecCertificate, privateKey: SecKey) throws -> SecIdentity {
        // Add certificate and key to temporary keychain items
        let certAddQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        // Delete if exists, then add
        SecItemDelete(certAddQuery as CFDictionary)
        var status = SecItemAdd(certAddQuery as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            os_log("Failed to add certificate to keychain: %{public}d", log: log, type: .error, status)
        }

        // Add private key
        let keyAddQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        SecItemDelete(keyAddQuery as CFDictionary)
        status = SecItemAdd(keyAddQuery as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            os_log("Failed to add key to keychain: %{public}d", log: log, type: .error, status)
        }

        // Get identity
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var identityRef: CFTypeRef?
        status = SecItemCopyMatching(identityQuery as CFDictionary, &identityRef)

        guard status == errSecSuccess, let identity = identityRef as! SecIdentity? else {
            // Fallback: create identity manually (this is a workaround)
            throw TLSInterceptorError.identityCreationFailed(status)
        }

        return identity
    }

    // MARK: - TLS Options

    func createTLSOptions(for hostname: String) throws -> NWProtocolTLS.Options {
        let tlsOptions = NWProtocolTLS.Options()

        let identity = try getIdentityForHost(hostname)

        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            sec_identity_create(identity)!
        )

        // Allow older TLS versions for compatibility
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv12
        )

        return tlsOptions
    }

    // MARK: - Certificate Creation (ASN.1)

    private func createHostCertificateData(hostname: String, publicKey: SecKey, signingKey: SecKey) throws -> Data {
        var certBuilder = ASN1CertBuilder()

        certBuilder.serialNumber = generateSerialNumber()
        certBuilder.issuer = [
            ("CN", "QwikCAP Root CA"),
            ("O", "QwikCAP"),
            ("C", "US")
        ]
        certBuilder.subject = [
            ("CN", hostname),
            ("O", "QwikCAP Generated")
        ]
        certBuilder.notBefore = Date()
        certBuilder.notAfter = Calendar.current.date(byAdding: .day, value: 30, to: Date())!
        certBuilder.isCA = false
        certBuilder.subjectAltNames = [hostname]

        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw TLSInterceptorError.publicKeyExtractionFailed
        }
        certBuilder.publicKeyData = publicKeyData

        let tbsCertificate = certBuilder.buildTBSCertificate()
        let signature = try signData(tbsCertificate, with: signingKey)

        return certBuilder.buildCertificate(tbsCertificate: tbsCertificate, signature: signature)
    }

    private func signData(_ data: Data, with privateKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data? else {
            throw TLSInterceptorError.signingFailed(error?.takeRetainedValue().localizedDescription ?? "Unknown")
        }
        return signature
    }

    private func generateSerialNumber() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] &= 0x7F
        return Data(bytes)
    }

    // MARK: - Cache Management

    func clearCache() {
        cacheLock.lock()
        certificateCache.removeAll()
        cacheLock.unlock()
    }
}

// MARK: - Errors

enum TLSInterceptorError: Error, LocalizedError {
    case caCertificateNotLoaded
    case keyGenerationFailed(String)
    case publicKeyExtractionFailed
    case certificateCreationFailed
    case signingFailed(String)
    case identityCreationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .caCertificateNotLoaded: return "CA certificate not loaded"
        case .keyGenerationFailed(let msg): return "Key generation failed: \(msg)"
        case .publicKeyExtractionFailed: return "Failed to extract public key"
        case .certificateCreationFailed: return "Failed to create certificate"
        case .signingFailed(let msg): return "Signing failed: \(msg)"
        case .identityCreationFailed(let status): return "Identity creation failed: \(status)"
        }
    }
}

// MARK: - ASN.1 Certificate Builder (Simplified for Extension)

private struct ASN1CertBuilder {
    var serialNumber: Data = Data()
    var issuer: [(String, String)] = []
    var subject: [(String, String)] = []
    var notBefore: Date = Date()
    var notAfter: Date = Date()
    var publicKeyData: Data = Data()
    var isCA: Bool = false
    var subjectAltNames: [String] = []

    private let oidRSAEncryption = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
    private let oidSHA256WithRSA = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B])
    private let oidCommonName = Data([0x55, 0x04, 0x03])
    private let oidOrganization = Data([0x55, 0x04, 0x0A])
    private let oidCountry = Data([0x55, 0x04, 0x06])
    private let oidBasicConstraints = Data([0x55, 0x1D, 0x13])
    private let oidSubjectAltName = Data([0x55, 0x1D, 0x11])
    private let oidKeyUsage = Data([0x55, 0x1D, 0x0F])

    func buildTBSCertificate() -> Data {
        var tbs = Data()

        tbs.append(contentsOf: asn1Explicit(tag: 0, content: asn1Integer(2)))
        tbs.append(contentsOf: asn1Integer(serialNumber))
        tbs.append(contentsOf: asn1Sequence([asn1ObjectIdentifier(oidSHA256WithRSA), asn1Null()]))
        tbs.append(contentsOf: buildName(issuer))
        tbs.append(contentsOf: asn1Sequence([asn1UTCTime(notBefore), asn1UTCTime(notAfter)]))
        tbs.append(contentsOf: buildName(subject))
        tbs.append(contentsOf: buildPublicKeyInfo())

        let extensions = buildExtensions()
        if !extensions.isEmpty {
            tbs.append(contentsOf: asn1Explicit(tag: 3, content: asn1Sequence(extensions)))
        }

        return asn1Sequence(tbs)
    }

    func buildCertificate(tbsCertificate: Data, signature: Data) -> Data {
        let signatureAlgorithm = asn1Sequence([asn1ObjectIdentifier(oidSHA256WithRSA), asn1Null()])
        let signatureBitString = asn1BitString(signature)
        return asn1Sequence(tbsCertificate + signatureAlgorithm + signatureBitString)
    }

    private func buildName(_ components: [(String, String)]) -> Data {
        var rdns = Data()
        for (type, value) in components {
            let oid: Data
            switch type {
            case "CN": oid = oidCommonName
            case "O": oid = oidOrganization
            case "C": oid = oidCountry
            default: continue
            }
            let atv = asn1Sequence([asn1ObjectIdentifier(oid), type == "C" ? asn1PrintableString(value) : asn1UTF8String(value)])
            rdns.append(contentsOf: asn1Set(atv))
        }
        return asn1Sequence(rdns)
    }

    private func buildPublicKeyInfo() -> Data {
        let algorithmIdentifier = asn1Sequence([asn1ObjectIdentifier(oidRSAEncryption), asn1Null()])
        let publicKeyBitString = asn1BitString(publicKeyData)
        return asn1Sequence(algorithmIdentifier + publicKeyBitString)
    }

    private func buildExtensions() -> [Data] {
        var extensions: [Data] = []

        let basicConstraintsValue = asn1Sequence(isCA ? [asn1Boolean(true)] : [])
        extensions.append(asn1Sequence([asn1ObjectIdentifier(oidBasicConstraints), asn1Boolean(true), asn1OctetString(basicConstraintsValue)]))

        var keyUsageBits: UInt8 = isCA ? 0x06 : 0xA0
        let keyUsageValue = asn1BitString(Data([keyUsageBits]))
        extensions.append(asn1Sequence([asn1ObjectIdentifier(oidKeyUsage), asn1Boolean(true), asn1OctetString(keyUsageValue)]))

        if !subjectAltNames.isEmpty {
            var sanContent = Data()
            for name in subjectAltNames {
                let dnsBytes = name.data(using: .utf8) ?? Data()
                sanContent.append(contentsOf: asn1ContextTag(tag: 2, content: dnsBytes))
            }
            extensions.append(asn1Sequence([asn1ObjectIdentifier(oidSubjectAltName), asn1OctetString(asn1Sequence(sanContent))]))
        }

        return extensions
    }

    // ASN.1 Primitives
    private func asn1Length(_ length: Int) -> Data {
        if length < 128 { return Data([UInt8(length)]) }
        else if length < 256 { return Data([0x81, UInt8(length)]) }
        else { return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)]) }
    }

    private func asn1Sequence(_ content: Data) -> Data { Data([0x30]) + asn1Length(content.count) + content }
    private func asn1Sequence(_ contents: [Data]) -> Data { asn1Sequence(contents.reduce(Data()) { $0 + $1 }) }
    private func asn1Set(_ content: Data) -> Data { Data([0x31]) + asn1Length(content.count) + content }

    private func asn1Integer(_ value: Int) -> Data {
        var bytes = withUnsafeBytes(of: value.bigEndian) { Array($0) }
        while bytes.count > 1 && bytes[0] == 0 && bytes[1] & 0x80 == 0 { bytes.removeFirst() }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return Data([0x02]) + asn1Length(bytes.count) + Data(bytes)
    }

    private func asn1Integer(_ data: Data) -> Data {
        var bytes = Array(data)
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return Data([0x02]) + asn1Length(bytes.count) + Data(bytes)
    }

    private func asn1ObjectIdentifier(_ oid: Data) -> Data { Data([0x06]) + asn1Length(oid.count) + oid }
    private func asn1Null() -> Data { Data([0x05, 0x00]) }
    private func asn1Boolean(_ value: Bool) -> Data { Data([0x01, 0x01, value ? 0xFF : 0x00]) }
    private func asn1UTF8String(_ value: String) -> Data { let bytes = value.data(using: .utf8) ?? Data(); return Data([0x0C]) + asn1Length(bytes.count) + bytes }
    private func asn1PrintableString(_ value: String) -> Data { let bytes = value.data(using: .ascii) ?? Data(); return Data([0x13]) + asn1Length(bytes.count) + bytes }
    private func asn1BitString(_ data: Data) -> Data { Data([0x03]) + asn1Length(data.count + 1) + Data([0x00]) + data }
    private func asn1OctetString(_ data: Data) -> Data { Data([0x04]) + asn1Length(data.count) + data }

    private func asn1UTCTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let str = formatter.string(from: date)
        let bytes = str.data(using: .ascii) ?? Data()
        return Data([0x17]) + asn1Length(bytes.count) + bytes
    }

    private func asn1Explicit(tag: Int, content: Data) -> Data { Data([UInt8(0xA0 + tag)]) + asn1Length(content.count) + content }
    private func asn1ContextTag(tag: Int, content: Data) -> Data { Data([UInt8(0x80 + tag)]) + asn1Length(content.count) + content }
}
