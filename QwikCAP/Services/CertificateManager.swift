import Foundation
import Security
import CryptoKit

class CertificateManager: ObservableObject {
    static let shared = CertificateManager()

    @Published var hasCACertificate: Bool = false
    @Published var certificateInfo: CertificateInfo?
    @Published var isGenerating: Bool = false
    @Published var errorMessage: String?

    private let appGroupID = "group.com.qwikcap.app"
    private let caKeyTag = "com.qwikcap.ca.privatekey"
    private let caCertKey = "com.qwikcap.ca.certificate"

    private init() {
        loadCertificateStatus()
    }

    // MARK: - Public Methods

    func loadCertificateStatus() {
        let (cert, _) = loadCACertificateAndKey()
        hasCACertificate = cert != nil

        if let cert = cert {
            certificateInfo = extractCertificateInfo(from: cert)
        } else {
            certificateInfo = nil
        }
    }

    func generateCACertificate() async throws {
        await MainActor.run {
            isGenerating = true
            errorMessage = nil
        }

        defer {
            Task { @MainActor in
                isGenerating = false
            }
        }

        // Generate RSA key pair
        let privateKey = try generatePrivateKey()

        // Generate self-signed CA certificate
        let certificate = try generateSelfSignedCACertificate(privateKey: privateKey)

        // Store in Keychain/UserDefaults
        try storeCACertificate(certificate, privateKey: privateKey)

        await MainActor.run {
            loadCertificateStatus()
        }
    }

    func exportCertificateAsDER() throws -> Data {
        let (cert, _) = loadCACertificateAndKey()
        guard let certificate = cert else {
            throw CertificateError.certificateNotFound
        }

        guard let derData = SecCertificateCopyData(certificate) as Data? else {
            throw CertificateError.exportFailed
        }

        return derData
    }

    func exportCertificateAsPEM() throws -> String {
        let derData = try exportCertificateAsDER()
        let base64 = derData.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----"
    }

    func deleteCACertificate() throws {
        // Delete private key from Keychain
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: caKeyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA
        ]
        SecItemDelete(keyQuery as CFDictionary)

        // Delete certificate from UserDefaults
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.removeObject(forKey: caCertKey)

        loadCertificateStatus()
    }

    // MARK: - Certificate Generation for TLS Interception

    func generateCertificateForHost(_ hostname: String) throws -> (SecCertificate, SecKey) {
        let (caCert, caKey) = loadCACertificateAndKey()
        guard let caCert = caCert, let privateKey = caKey else {
            throw CertificateError.caCertificateNotFound
        }

        // Generate a new key pair for the host certificate
        let hostPrivateKey = try generatePrivateKey()

        // Generate certificate signed by CA
        let hostCert = try generateHostCertificate(
            hostname: hostname,
            privateKey: hostPrivateKey,
            caPrivateKey: privateKey
        )

        return (hostCert, hostPrivateKey)
    }

    // MARK: - Private Methods

    private func generatePrivateKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false
            ]
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw CertificateError.keyGenerationFailed(error?.takeRetainedValue().localizedDescription ?? "Unknown error")
        }

        return privateKey
    }

    private func generateSelfSignedCACertificate(privateKey: SecKey) throws -> SecCertificate {
        // Get public key from private key
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CertificateError.publicKeyExtractionFailed
        }

        // Create certificate using manual ASN.1 construction
        let certData = try createCACertificateData(publicKey: publicKey, privateKey: privateKey)

        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw CertificateError.certificateCreationFailed
        }

        return certificate
    }

    private func generateHostCertificate(hostname: String, privateKey: SecKey, caPrivateKey: SecKey) throws -> SecCertificate {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CertificateError.publicKeyExtractionFailed
        }

        let certData = try createHostCertificateData(
            hostname: hostname,
            publicKey: publicKey,
            signingKey: caPrivateKey
        )

        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw CertificateError.certificateCreationFailed
        }

        return certificate
    }

    private func createCACertificateData(publicKey: SecKey, privateKey: SecKey) throws -> Data {
        // Build ASN.1 DER-encoded X.509 certificate
        var certBuilder = ASN1CertificateBuilder()

        // Set certificate fields
        certBuilder.serialNumber = generateSerialNumber()
        certBuilder.issuer = [
            ("CN", "QwikCAP Root CA"),
            ("O", "QwikCAP"),
            ("C", "US")
        ]
        certBuilder.subject = certBuilder.issuer
        certBuilder.notBefore = Date()
        certBuilder.notAfter = Calendar.current.date(byAdding: .year, value: 10, to: Date())!
        certBuilder.isCA = true

        // Get public key data
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw CertificateError.publicKeyExtractionFailed
        }
        certBuilder.publicKeyData = publicKeyData

        // Build TBS (to-be-signed) certificate
        let tbsCertificate = certBuilder.buildTBSCertificate()

        // Sign with private key
        let signature = try signData(tbsCertificate, with: privateKey)

        // Build final certificate
        return certBuilder.buildCertificate(tbsCertificate: tbsCertificate, signature: signature)
    }

    private func createHostCertificateData(hostname: String, publicKey: SecKey, signingKey: SecKey) throws -> Data {
        var certBuilder = ASN1CertificateBuilder()

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
            throw CertificateError.publicKeyExtractionFailed
        }
        certBuilder.publicKeyData = publicKeyData

        let tbsCertificate = certBuilder.buildTBSCertificate()
        let signature = try signData(tbsCertificate, with: signingKey)

        return certBuilder.buildCertificate(tbsCertificate: tbsCertificate, signature: signature)
    }

    private func signData(_ data: Data, with privateKey: SecKey) throws -> Data {
        // SHA-256 with RSA PKCS#1 v1.5
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data? else {
            throw CertificateError.signingFailed(error?.takeRetainedValue().localizedDescription ?? "Unknown error")
        }

        return signature
    }

    private func generateSerialNumber() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] &= 0x7F  // Ensure positive number
        return Data(bytes)
    }

    private func storeCACertificate(_ certificate: SecCertificate, privateKey: SecKey) throws {
        // Store private key in Keychain
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: caKeyTag.data(using: .utf8)!,
            kSecValueRef as String: privateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrAccessGroup as String: appGroupID
        ]

        // Delete existing key first
        SecItemDelete(keyQuery as CFDictionary)

        let status = SecItemAdd(keyQuery as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            throw CertificateError.keychainStoreFailed(status)
        }

        // Store certificate data in UserDefaults (shared via app group)
        let certData = SecCertificateCopyData(certificate) as Data
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(certData, forKey: caCertKey)
    }

    func loadCACertificateAndKey() -> (SecCertificate?, SecKey?) {
        // Load certificate from UserDefaults
        let defaults = UserDefaults(suiteName: appGroupID)
        guard let certData = defaults?.data(forKey: caCertKey),
              let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            return (nil, nil)
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

        guard status == errSecSuccess, let privateKey = item as! SecKey? else {
            return (certificate, nil)
        }

        return (certificate, privateKey)
    }

    private func extractCertificateInfo(from certificate: SecCertificate) -> CertificateInfo {
        let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? "Unknown"

        // Extract dates (simplified - in production use SecCertificateCopyValues)
        let now = Date()
        let validFrom = now
        let validUntil = Calendar.current.date(byAdding: .year, value: 10, to: now) ?? now

        // Calculate fingerprint
        let certData = SecCertificateCopyData(certificate) as Data
        let fingerprint = SHA256.hash(data: certData)
            .compactMap { String(format: "%02x", $0) }
            .joined(separator: ":")
            .uppercased()

        return CertificateInfo(
            commonName: summary,
            organization: "QwikCAP",
            validFrom: validFrom,
            validUntil: validUntil,
            serialNumber: "Auto-generated",
            fingerprint: String(fingerprint.prefix(59)),
            isInstalled: false,
            isTrusted: false
        )
    }
}

// MARK: - Certificate Info Model

struct CertificateInfo: Identifiable {
    let id = UUID()
    let commonName: String
    let organization: String
    let validFrom: Date
    let validUntil: Date
    let serialNumber: String
    let fingerprint: String
    let isInstalled: Bool
    let isTrusted: Bool

    var isExpired: Bool { Date() > validUntil }
    var daysUntilExpiry: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: validUntil).day ?? 0
    }
}

// MARK: - Certificate Errors

enum CertificateError: Error, LocalizedError {
    case keyGenerationFailed(String)
    case publicKeyExtractionFailed
    case certificateCreationFailed
    case signingFailed(String)
    case keychainStoreFailed(OSStatus)
    case certificateNotFound
    case caCertificateNotFound
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let msg): return "Key generation failed: \(msg)"
        case .publicKeyExtractionFailed: return "Failed to extract public key"
        case .certificateCreationFailed: return "Failed to create certificate"
        case .signingFailed(let msg): return "Certificate signing failed: \(msg)"
        case .keychainStoreFailed(let status): return "Failed to store in Keychain: \(status)"
        case .certificateNotFound: return "Certificate not found"
        case .caCertificateNotFound: return "CA certificate not found - generate one first"
        case .exportFailed: return "Failed to export certificate"
        }
    }
}

// MARK: - ASN.1 Certificate Builder

private struct ASN1CertificateBuilder {
    var serialNumber: Data = Data()
    var issuer: [(String, String)] = []
    var subject: [(String, String)] = []
    var notBefore: Date = Date()
    var notAfter: Date = Date()
    var publicKeyData: Data = Data()
    var isCA: Bool = false
    var subjectAltNames: [String] = []

    // OIDs
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

        // Version (v3 = 2)
        tbs.append(contentsOf: asn1Explicit(tag: 0, content: asn1Integer(2)))

        // Serial number
        tbs.append(contentsOf: asn1Integer(serialNumber))

        // Signature algorithm (SHA256withRSA)
        tbs.append(contentsOf: asn1Sequence([
            asn1ObjectIdentifier(oidSHA256WithRSA),
            asn1Null()
        ]))

        // Issuer
        tbs.append(contentsOf: buildName(issuer))

        // Validity
        tbs.append(contentsOf: asn1Sequence([
            asn1UTCTime(notBefore),
            asn1UTCTime(notAfter)
        ]))

        // Subject
        tbs.append(contentsOf: buildName(subject))

        // Subject public key info
        tbs.append(contentsOf: buildPublicKeyInfo())

        // Extensions
        let extensions = buildExtensions()
        if !extensions.isEmpty {
            tbs.append(contentsOf: asn1Explicit(tag: 3, content: asn1Sequence(extensions)))
        }

        return asn1Sequence(tbs)
    }

    func buildCertificate(tbsCertificate: Data, signature: Data) -> Data {
        let signatureAlgorithm = asn1Sequence([
            asn1ObjectIdentifier(oidSHA256WithRSA),
            asn1Null()
        ])

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

            let atv = asn1Sequence([
                asn1ObjectIdentifier(oid),
                type == "C" ? asn1PrintableString(value) : asn1UTF8String(value)
            ])
            rdns.append(contentsOf: asn1Set(atv))
        }
        return asn1Sequence(rdns)
    }

    private func buildPublicKeyInfo() -> Data {
        let algorithmIdentifier = asn1Sequence([
            asn1ObjectIdentifier(oidRSAEncryption),
            asn1Null()
        ])

        // Wrap public key data in BIT STRING
        let publicKeyBitString = asn1BitString(publicKeyData)

        return asn1Sequence(algorithmIdentifier + publicKeyBitString)
    }

    private func buildExtensions() -> [Data] {
        var extensions: [Data] = []

        // Basic Constraints
        let basicConstraintsValue = asn1Sequence(isCA ? [asn1Boolean(true)] : [])
        extensions.append(asn1Sequence([
            asn1ObjectIdentifier(oidBasicConstraints),
            asn1Boolean(true),  // critical
            asn1OctetString(basicConstraintsValue)
        ]))

        // Key Usage
        var keyUsageBits: UInt8 = 0
        if isCA {
            keyUsageBits = 0x06  // keyCertSign, cRLSign
        } else {
            keyUsageBits = 0xA0  // digitalSignature, keyEncipherment
        }
        let keyUsageValue = asn1BitString(Data([keyUsageBits]))
        extensions.append(asn1Sequence([
            asn1ObjectIdentifier(oidKeyUsage),
            asn1Boolean(true),  // critical
            asn1OctetString(keyUsageValue)
        ]))

        // Subject Alternative Name (for host certificates)
        if !subjectAltNames.isEmpty {
            var sanContent = Data()
            for name in subjectAltNames {
                // DNS name is context tag [2]
                let dnsBytes = name.data(using: .utf8) ?? Data()
                sanContent.append(contentsOf: asn1ContextTag(tag: 2, content: dnsBytes))
            }
            extensions.append(asn1Sequence([
                asn1ObjectIdentifier(oidSubjectAltName),
                asn1OctetString(asn1Sequence(sanContent))
            ]))
        }

        return extensions
    }

    // MARK: - ASN.1 Primitives

    private func asn1Length(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        } else if length < 256 {
            return Data([0x81, UInt8(length)])
        } else {
            return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
        }
    }

    private func asn1Sequence(_ content: Data) -> Data {
        return Data([0x30]) + asn1Length(content.count) + content
    }

    private func asn1Sequence(_ contents: [Data]) -> Data {
        let combined = contents.reduce(Data()) { $0 + $1 }
        return asn1Sequence(combined)
    }

    private func asn1Set(_ content: Data) -> Data {
        return Data([0x31]) + asn1Length(content.count) + content
    }

    private func asn1Integer(_ value: Int) -> Data {
        var bytes = withUnsafeBytes(of: value.bigEndian) { Array($0) }
        while bytes.count > 1 && bytes[0] == 0 && bytes[1] & 0x80 == 0 {
            bytes.removeFirst()
        }
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return Data([0x02]) + asn1Length(bytes.count) + Data(bytes)
    }

    private func asn1Integer(_ data: Data) -> Data {
        var bytes = Array(data)
        if bytes.isEmpty {
            bytes = [0]
        }
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return Data([0x02]) + asn1Length(bytes.count) + Data(bytes)
    }

    private func asn1ObjectIdentifier(_ oid: Data) -> Data {
        return Data([0x06]) + asn1Length(oid.count) + oid
    }

    private func asn1Null() -> Data {
        return Data([0x05, 0x00])
    }

    private func asn1Boolean(_ value: Bool) -> Data {
        return Data([0x01, 0x01, value ? 0xFF : 0x00])
    }

    private func asn1UTF8String(_ value: String) -> Data {
        let bytes = value.data(using: .utf8) ?? Data()
        return Data([0x0C]) + asn1Length(bytes.count) + bytes
    }

    private func asn1PrintableString(_ value: String) -> Data {
        let bytes = value.data(using: .ascii) ?? Data()
        return Data([0x13]) + asn1Length(bytes.count) + bytes
    }

    private func asn1BitString(_ data: Data) -> Data {
        // Bit string with 0 unused bits
        return Data([0x03]) + asn1Length(data.count + 1) + Data([0x00]) + data
    }

    private func asn1OctetString(_ data: Data) -> Data {
        return Data([0x04]) + asn1Length(data.count) + data
    }

    private func asn1UTCTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let str = formatter.string(from: date)
        let bytes = str.data(using: .ascii) ?? Data()
        return Data([0x17]) + asn1Length(bytes.count) + bytes
    }

    private func asn1Explicit(tag: Int, content: Data) -> Data {
        let tagByte = UInt8(0xA0 + tag)
        return Data([tagByte]) + asn1Length(content.count) + content
    }

    private func asn1ContextTag(tag: Int, content: Data) -> Data {
        let tagByte = UInt8(0x80 + tag)
        return Data([tagByte]) + asn1Length(content.count) + content
    }
}

