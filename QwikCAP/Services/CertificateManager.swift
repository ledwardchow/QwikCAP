import Foundation
import Security
import UIKit
import CryptoKit

class CertificateManager: ObservableObject {
    static let shared = CertificateManager()

    @Published var isCertificateGenerated = false
    @Published var isCertificateInstalled = false  // Note: This cannot be detected programmatically
    @Published var certificateFingerprint: String = ""
    @Published var statusMessage: String = "Checking certificate status..."
    @Published var detailedStatus: CertificateStatus = .notGenerated

    private let keychainService = "com.qwikcap.certificate"
    private let caKeyTag = "com.qwikcap.ca.privatekey"
    private let caCertTag = "com.qwikcap.ca.certificate"

    private let appGroupID = "group.com.qwikcap.app"

    enum CertificateStatus: Equatable {
        case notGenerated
        case generated
        case exported
        case installationPending  // User needs to install
        case trustPending  // User needs to trust
        case ready  // Manually confirmed by user

        var description: String {
            switch self {
            case .notGenerated: return "Certificate not generated"
            case .generated: return "Certificate generated, needs export"
            case .exported: return "Certificate exported, awaiting installation"
            case .installationPending: return "Install the profile in Settings"
            case .trustPending: return "Enable trust in Certificate Trust Settings"
            case .ready: return "Certificate ready for use"
            }
        }

        var icon: String {
            switch self {
            case .notGenerated: return "xmark.circle"
            case .generated, .exported: return "arrow.down.circle"
            case .installationPending, .trustPending: return "exclamationmark.triangle"
            case .ready: return "checkmark.shield.fill"
            }
        }

        var color: String {
            switch self {
            case .notGenerated: return "red"
            case .generated, .exported, .installationPending, .trustPending: return "orange"
            case .ready: return "green"
            }
        }
    }

    private init() {
        checkCertificateStatus()
    }

    // MARK: - Certificate Generation

    func generateCACertificate() async throws -> (privateKey: SecKey, certificate: Data) {
        // Generate RSA key pair
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error) else {
            throw CertificateError.keyGenerationFailed(error?.takeRetainedValue().localizedDescription ?? "Unknown error")
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CertificateError.publicKeyExtractionFailed
        }

        // Create self-signed CA certificate
        let certificate = try createSelfSignedCACertificate(privateKey: privateKey, publicKey: publicKey)

        // Store in keychain
        try storeCACredentials(privateKey: privateKey, certificate: certificate)

        // Store in app group for extension access
        try storeInAppGroup(privateKey: privateKey, certificate: certificate)

        await MainActor.run {
            self.isCertificateGenerated = true
            self.isCertificateInstalled = false // User still needs to trust it
            self.certificateFingerprint = calculateFingerprint(certificate)
            self.statusMessage = "Certificate generated. Please export and install it."
            self.detailedStatus = .generated
        }

        return (privateKey, certificate)
    }

    private func createSelfSignedCACertificate(privateKey: SecKey, publicKey: SecKey) throws -> Data {
        // Certificate structure using DER encoding
        let now = Date()
        let validityPeriod: TimeInterval = 365 * 24 * 60 * 60 * 10 // 10 years

        // Subject and Issuer DN
        let commonName = "QwikCAP Root CA"
        let organizationName = "QwikCAP"
        let countryName = "US"

        // Build X.509 certificate manually
        var certBuilder = X509CertificateBuilder()
        certBuilder.serialNumber = generateSerialNumber()
        certBuilder.issuerCN = commonName
        certBuilder.issuerO = organizationName
        certBuilder.issuerC = countryName
        certBuilder.subjectCN = commonName
        certBuilder.subjectO = organizationName
        certBuilder.subjectC = countryName
        certBuilder.notBefore = now
        certBuilder.notAfter = now.addingTimeInterval(validityPeriod)
        certBuilder.publicKey = publicKey
        certBuilder.isCA = true

        return try certBuilder.build(signingKey: privateKey)
    }

    private func generateSerialNumber() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] = bytes[0] & 0x7F // Ensure positive
        return Data(bytes)
    }

    private func calculateFingerprint(_ certData: Data) -> String {
        let hash = SHA256.hash(data: certData)
        return hash.compactMap { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: - Keychain Storage

    private func storeCACredentials(privateKey: SecKey, certificate: Data) throws {
        // Store private key
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: caKeyTag,
            kSecValueRef as String: privateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        SecItemDelete(keyQuery as CFDictionary) // Remove existing
        let keyStatus = SecItemAdd(keyQuery as CFDictionary, nil)
        guard keyStatus == errSecSuccess else {
            throw CertificateError.keychainStoreFailed("Private key: \(keyStatus)")
        }

        // Store certificate
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: caCertTag,
            kSecValueData as String: certificate,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        SecItemDelete(certQuery as CFDictionary) // Remove existing
        let certStatus = SecItemAdd(certQuery as CFDictionary, nil)
        guard certStatus == errSecSuccess else {
            throw CertificateError.keychainStoreFailed("Certificate: \(certStatus)")
        }
    }

    private func storeInAppGroup(privateKey: SecKey, certificate: Data) throws {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw CertificateError.appGroupAccessFailed
        }

        // Export private key
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw CertificateError.keyExportFailed(error?.takeRetainedValue().localizedDescription ?? "Unknown")
        }

        let keyPath = containerURL.appendingPathComponent("ca_private_key.der")
        let certPath = containerURL.appendingPathComponent("ca_certificate.der")

        try keyData.write(to: keyPath)
        try certificate.write(to: certPath)
    }

    // MARK: - Certificate Retrieval

    func getCAPrivateKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: caKeyTag,
            kSecReturnRef as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }

        return (item as! SecKey)
    }

    func getCACertificateData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: caCertTag,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }

        return item as? Data
    }

    // MARK: - Certificate Status

    func checkCertificateStatus() {
        if let certData = getCACertificateData() {
            isCertificateGenerated = true
            certificateFingerprint = calculateFingerprint(certData)

            // Check if certificate was exported (stored in UserDefaults)
            let defaults = UserDefaults(suiteName: appGroupID)
            let wasExported = defaults?.bool(forKey: "certificateExported") ?? false
            let userConfirmedTrust = defaults?.bool(forKey: "certificateTrusted") ?? false

            if userConfirmedTrust {
                detailedStatus = .ready
                statusMessage = "Certificate ready for use"
                isCertificateInstalled = true
            } else if wasExported {
                detailedStatus = .trustPending
                statusMessage = "Please install profile and enable trust"
                isCertificateInstalled = false
            } else {
                detailedStatus = .generated
                statusMessage = "Certificate generated, please export and install"
                isCertificateInstalled = false
            }
        } else {
            isCertificateGenerated = false
            isCertificateInstalled = false
            statusMessage = "No certificate generated"
            certificateFingerprint = ""
            detailedStatus = .notGenerated
        }
    }

    /// Call this when user confirms they have trusted the certificate
    func markCertificateAsTrusted() {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(true, forKey: "certificateTrusted")
        isCertificateInstalled = true
        detailedStatus = .ready
        statusMessage = "Certificate ready for use"
    }

    /// Call this to reset trust status (e.g., if user removes the profile)
    func resetTrustStatus() {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(false, forKey: "certificateTrusted")
        defaults?.set(false, forKey: "certificateExported")
        isCertificateInstalled = false
        checkCertificateStatus()
    }

    // MARK: - Certificate Installation

    func exportCertificateForInstallation() {
        guard let certData = getCACertificateData() else {
            Task { @MainActor in
                // Generate certificate if it doesn't exist
                do {
                    let _ = try await generateCACertificate()
                    exportCertificateForInstallation()
                } catch {
                    statusMessage = "Failed to generate certificate: \(error.localizedDescription)"
                }
            }
            return
        }

        // Save to temporary file and open profile installer
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("QwikCAP_CA.crt")

        do {
            try certData.write(to: tempURL)

            // Mark as exported
            let defaults = UserDefaults(suiteName: appGroupID)
            defaults?.set(true, forKey: "certificateExported")

            // Open the certificate for installation
            Task { @MainActor in
                detailedStatus = .exported
                statusMessage = "Certificate exported. Install it in Settings."

                if let url = URL(string: "x-apple-certs://") {
                    // Try to open certificate settings directly
                    if UIApplication.shared.canOpenURL(url) {
                        await UIApplication.shared.open(url)
                    }
                }

                // Share the certificate file
                let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    rootVC.present(activityVC, animated: true)
                }
            }
        } catch {
            statusMessage = "Failed to export certificate: \(error.localizedDescription)"
        }
    }

    func getCertificateAsPEM() -> String? {
        guard let certData = getCACertificateData() else { return nil }
        let base64 = certData.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----"
    }

    // MARK: - Host Certificate Generation

    func generateHostCertificate(forHost host: String, privateKey: inout SecKey?) throws -> Data {
        // Get CA credentials
        guard let caPrivateKey = getCAPrivateKey(),
              let caCertData = getCACertificateData() else {
            throw CertificateError.caNotFound
        }

        // Generate new key pair for host
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false
        ]

        var error: Unmanaged<CFError>?
        guard let hostPrivateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error) else {
            throw CertificateError.keyGenerationFailed(error?.takeRetainedValue().localizedDescription ?? "Unknown")
        }

        guard let hostPublicKey = SecKeyCopyPublicKey(hostPrivateKey) else {
            throw CertificateError.publicKeyExtractionFailed
        }

        privateKey = hostPrivateKey

        // Create host certificate signed by CA
        var certBuilder = X509CertificateBuilder()
        certBuilder.serialNumber = generateSerialNumber()
        certBuilder.issuerCN = "QwikCAP Root CA"
        certBuilder.issuerO = "QwikCAP"
        certBuilder.issuerC = "US"
        certBuilder.subjectCN = host
        certBuilder.subjectO = "QwikCAP Generated"
        certBuilder.subjectC = "US"
        certBuilder.notBefore = Date()
        certBuilder.notAfter = Date().addingTimeInterval(365 * 24 * 60 * 60) // 1 year
        certBuilder.publicKey = hostPublicKey
        certBuilder.isCA = false
        certBuilder.subjectAltNames = [host]

        return try certBuilder.build(signingKey: caPrivateKey)
    }
}

// MARK: - X509 Certificate Builder

struct X509CertificateBuilder {
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
        // Build TBS Certificate
        var tbsCertificate = Data()

        // Version (v3 = 2)
        tbsCertificate.append(contentsOf: DER.contextTag(0, content: DER.integer(2)))

        // Serial Number
        tbsCertificate.append(contentsOf: DER.integer(serialNumber))

        // Signature Algorithm (SHA256 with RSA)
        tbsCertificate.append(contentsOf: DER.sequence([
            DER.objectIdentifier([1, 2, 840, 113549, 1, 1, 11]), // sha256WithRSAEncryption
            DER.null()
        ]))

        // Issuer
        tbsCertificate.append(contentsOf: buildName(cn: issuerCN, o: issuerO, c: issuerC))

        // Validity
        tbsCertificate.append(contentsOf: DER.sequence([
            DER.utcTime(notBefore),
            DER.utcTime(notAfter)
        ]))

        // Subject
        tbsCertificate.append(contentsOf: buildName(cn: subjectCN, o: subjectO, c: subjectC))

        // Subject Public Key Info
        guard let pubKey = publicKey else {
            throw CertificateError.publicKeyExtractionFailed
        }
        var error: Unmanaged<CFError>?
        guard let pubKeyData = SecKeyCopyExternalRepresentation(pubKey, &error) as Data? else {
            throw CertificateError.keyExportFailed(error?.takeRetainedValue().localizedDescription ?? "Unknown")
        }
        tbsCertificate.append(contentsOf: buildSubjectPublicKeyInfo(pubKeyData))

        // Extensions
        var extensions = Data()

        // Basic Constraints
        if isCA {
            extensions.append(contentsOf: buildBasicConstraintsExtension(isCA: true))
            extensions.append(contentsOf: buildKeyUsageExtension(isCA: true))
        } else {
            extensions.append(contentsOf: buildBasicConstraintsExtension(isCA: false))
            extensions.append(contentsOf: buildKeyUsageExtension(isCA: false))
            extensions.append(contentsOf: buildExtendedKeyUsageExtension())
        }

        // Subject Alternative Names
        if !subjectAltNames.isEmpty {
            extensions.append(contentsOf: buildSANExtension(subjectAltNames))
        }

        tbsCertificate.append(contentsOf: DER.contextTag(3, content: DER.sequence(extensions)))

        // Wrap TBS Certificate in sequence
        let tbsCertificateSequence = DER.sequence(tbsCertificate)

        // Sign
        let signature = try sign(data: tbsCertificateSequence, with: signingKey)

        // Build final certificate
        var certificate = Data()
        certificate.append(contentsOf: tbsCertificateSequence)
        certificate.append(contentsOf: DER.sequence([
            DER.objectIdentifier([1, 2, 840, 113549, 1, 1, 11]), // sha256WithRSAEncryption
            DER.null()
        ]))
        certificate.append(contentsOf: DER.bitString(signature))

        return DER.sequence(certificate)
    }

    private func buildName(cn: String, o: String, c: String) -> Data {
        var rdnSequence = Data()

        // Country
        rdnSequence.append(contentsOf: DER.set([
            DER.sequence([
                DER.objectIdentifier([2, 5, 4, 6]), // countryName
                DER.printableString(c)
            ])
        ]))

        // Organization
        rdnSequence.append(contentsOf: DER.set([
            DER.sequence([
                DER.objectIdentifier([2, 5, 4, 10]), // organizationName
                DER.utf8String(o)
            ])
        ]))

        // Common Name
        rdnSequence.append(contentsOf: DER.set([
            DER.sequence([
                DER.objectIdentifier([2, 5, 4, 3]), // commonName
                DER.utf8String(cn)
            ])
        ]))

        return DER.sequence(rdnSequence)
    }

    private func buildSubjectPublicKeyInfo(_ pubKeyData: Data) -> Data {
        let algorithmIdentifier = DER.sequence([
            DER.objectIdentifier([1, 2, 840, 113549, 1, 1, 1]), // rsaEncryption
            DER.null()
        ])

        return DER.sequence([
            algorithmIdentifier,
            DER.bitString(pubKeyData)
        ])
    }

    private func buildBasicConstraintsExtension(isCA: Bool) -> Data {
        let oid = DER.objectIdentifier([2, 5, 29, 19]) // basicConstraints
        let critical = DER.boolean(true)
        let value = DER.octetString(DER.sequence(isCA ? [DER.boolean(true)] : []))

        return DER.sequence([oid, critical, value])
    }

    private func buildKeyUsageExtension(isCA: Bool) -> Data {
        let oid = DER.objectIdentifier([2, 5, 29, 15]) // keyUsage
        let critical = DER.boolean(true)

        let usage: UInt8
        if isCA {
            usage = 0x06 // keyCertSign, cRLSign
        } else {
            usage = 0xA0 // digitalSignature, keyEncipherment
        }

        let value = DER.octetString(DER.bitString(Data([usage])))
        return DER.sequence([oid, critical, value])
    }

    private func buildExtendedKeyUsageExtension() -> Data {
        let oid = DER.objectIdentifier([2, 5, 29, 37]) // extKeyUsage
        let value = DER.octetString(DER.sequence([
            DER.objectIdentifier([1, 3, 6, 1, 5, 5, 7, 3, 1]), // serverAuth
            DER.objectIdentifier([1, 3, 6, 1, 5, 5, 7, 3, 2])  // clientAuth
        ]))
        return DER.sequence([oid, value])
    }

    private func buildSANExtension(_ names: [String]) -> Data {
        let oid = DER.objectIdentifier([2, 5, 29, 17]) // subjectAltName

        var sanData = Data()
        for name in names {
            // Check if IP address or DNS name
            if isIPAddress(name) {
                sanData.append(contentsOf: DER.contextTagImplicit(7, content: ipToBytes(name)))
            } else {
                sanData.append(contentsOf: DER.contextTagImplicit(2, content: Data(name.utf8)))
            }
        }

        let value = DER.octetString(DER.sequence(sanData))
        return DER.sequence([oid, value])
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
            throw CertificateError.signingFailed(error?.takeRetainedValue().localizedDescription ?? "Unknown")
        }
        return signature
    }
}

// MARK: - DER Encoding Helpers

enum DER {
    static func sequence(_ content: Data) -> Data {
        return tag(0x30, content: content)
    }

    static func sequence(_ contents: [Data]) -> Data {
        var data = Data()
        for content in contents {
            data.append(content)
        }
        return sequence(data)
    }

    static func set(_ contents: [Data]) -> Data {
        var data = Data()
        for content in contents {
            data.append(content)
        }
        return tag(0x31, content: data)
    }

    static func integer(_ value: Int) -> Data {
        var bytes = [UInt8]()
        var v = value
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0

        if bytes[0] & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }

        return tag(0x02, content: Data(bytes))
    }

    static func integer(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        if bytes.isEmpty || bytes[0] & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return tag(0x02, content: Data(bytes))
    }

    static func bitString(_ data: Data) -> Data {
        var content = Data([0x00]) // No unused bits
        content.append(data)
        return tag(0x03, content: content)
    }

    static func octetString(_ data: Data) -> Data {
        return tag(0x04, content: data)
    }

    static func null() -> Data {
        return Data([0x05, 0x00])
    }

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

    static func utf8String(_ string: String) -> Data {
        return tag(0x0C, content: Data(string.utf8))
    }

    static func printableString(_ string: String) -> Data {
        return tag(0x13, content: Data(string.utf8))
    }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let string = formatter.string(from: date)
        return tag(0x17, content: Data(string.utf8))
    }

    static func boolean(_ value: Bool) -> Data {
        return tag(0x01, content: Data([value ? 0xFF : 0x00]))
    }

    static func contextTag(_ tag: UInt8, content: Data) -> Data {
        return DER.tag(0xA0 | tag, content: content)
    }

    static func contextTagImplicit(_ tag: UInt8, content: Data) -> Data {
        return DER.tag(0x80 | tag, content: content)
    }

    static func tag(_ tag: UInt8, content: Data) -> Data {
        var result = Data([tag])
        result.append(contentsOf: encodeLength(content.count))
        result.append(content)
        return result
    }

    private static func encodeLength(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        } else if length < 256 {
            return Data([0x81, UInt8(length)])
        } else if length < 65536 {
            return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
        } else {
            return Data([0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
        }
    }
}

// MARK: - Errors

enum CertificateError: Error, LocalizedError {
    case keyGenerationFailed(String)
    case publicKeyExtractionFailed
    case keyExportFailed(String)
    case keychainStoreFailed(String)
    case appGroupAccessFailed
    case caNotFound
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let msg): return "Key generation failed: \(msg)"
        case .publicKeyExtractionFailed: return "Failed to extract public key"
        case .keyExportFailed(let msg): return "Key export failed: \(msg)"
        case .keychainStoreFailed(let msg): return "Keychain storage failed: \(msg)"
        case .appGroupAccessFailed: return "Failed to access app group"
        case .caNotFound: return "CA certificate not found"
        case .signingFailed(let msg): return "Signing failed: \(msg)"
        }
    }
}
