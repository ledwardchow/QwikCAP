import Foundation
import Security

class TLSInterceptor {
    static let shared = TLSInterceptor()

    private var certificateCache: [String: SecIdentity] = [:]
    private let cacheLock = NSLock()

    private init() {}

    // MARK: - Identity Management

    func getOrCreateIdentity(forHost host: String) -> SecIdentity? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cached = certificateCache[host] {
            return cached
        }

        // Generate new certificate for this host
        guard let identity = generateIdentity(forHost: host) else {
            return nil
        }

        certificateCache[host] = identity
        return identity
    }

    private func generateIdentity(forHost host: String) -> SecIdentity? {
        let certManager = CertificateManager.shared

        do {
            var privateKey: SecKey?
            let certData = try certManager.generateHostCertificate(forHost: host, privateKey: &privateKey)

            guard let key = privateKey,
                  let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
                return nil
            }

            return createIdentity(certificate: certificate, privateKey: key)
        } catch {
            print("Failed to generate host certificate: \(error)")
            return nil
        }
    }

    private func createIdentity(certificate: SecCertificate, privateKey: SecKey) -> SecIdentity? {
        // Create temporary keychain items
        let label = "com.qwikcap.temp.\(UUID().uuidString)"

        // Add certificate
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label
        ]

        SecItemDelete(certQuery as CFDictionary)
        var status = SecItemAdd(certQuery as CFDictionary, nil)
        guard status == errSecSuccess else { return nil }

        // Add private key
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrLabel as String: label,
            kSecAttrApplicationTag as String: label.data(using: .utf8)!
        ]

        SecItemDelete(keyQuery as CFDictionary)
        status = SecItemAdd(keyQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            SecItemDelete(certQuery as CFDictionary)
            return nil
        }

        // Get identity
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true
        ]

        var result: CFTypeRef?
        status = SecItemCopyMatching(identityQuery as CFDictionary, &result)

        // Cleanup
        SecItemDelete(certQuery as CFDictionary)
        SecItemDelete(keyQuery as CFDictionary)

        guard status == errSecSuccess else { return nil }
        return (result as! SecIdentity)
    }

    // MARK: - TLS Session Info

    func extractServerCertificate(from trust: SecTrust) -> SecCertificate? {
        if let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
           let firstCert = certificates.first {
            return firstCert
        }
        return nil
    }

    func getCertificateCommonName(_ certificate: SecCertificate) -> String? {
        var commonName: CFString?
        let status = SecCertificateCopyCommonName(certificate, &commonName)
        guard status == errSecSuccess else { return nil }
        return commonName as String?
    }

    func getCertificateSubjectAltNames(_ certificate: SecCertificate) -> [String] {
        // This would require parsing the certificate's DER data
        // For simplicity, returning empty array
        return []
    }

    // MARK: - Cache Management

    func clearCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        certificateCache.removeAll()
    }

    func removeCachedIdentity(forHost host: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        certificateCache.removeValue(forKey: host)
    }
}
