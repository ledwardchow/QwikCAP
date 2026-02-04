import Foundation
import Network
import os.log

class DNSResolver {
    private let log = OSLog(subsystem: "com.qwikcap.tunnel", category: "DNSResolver")

    private var cache: [String: CachedDNSEntry] = [:]
    private let cacheLock = NSLock()
    private let cacheTimeout: TimeInterval = 300 // 5 minutes

    // MARK: - Resolution

    func resolve(hostname: String, completion: @escaping (Result<[String], Error>) -> Void) {
        // Check cache first
        if let cached = getCachedEntry(hostname) {
            completion(.success(cached))
            return
        }

        // Perform DNS lookup
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_flags = AI_CANONNAME

            var result: UnsafeMutablePointer<addrinfo>?

            let status = getaddrinfo(hostname, nil, &hints, &result)
            defer { freeaddrinfo(result) }

            guard status == 0, let info = result else {
                let error = NSError(
                    domain: "DNSResolver",
                    code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: gai_strerror(status))]
                )
                completion(.failure(error))
                return
            }

            var addresses: [String] = []
            var current: UnsafeMutablePointer<addrinfo>? = info

            while let addr = current {
                if let address = self?.addressToString(addr.pointee) {
                    addresses.append(address)
                }
                current = addr.pointee.ai_next
            }

            if addresses.isEmpty {
                completion(.failure(DNSError.noAddressFound))
            } else {
                self?.cacheEntry(hostname, addresses: addresses)
                completion(.success(addresses))
            }
        }
    }

    func resolveSync(hostname: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?

        let status = getaddrinfo(hostname, nil, &hints, &result)
        defer { freeaddrinfo(result) }

        guard status == 0, let info = result else {
            return nil
        }

        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = info

        while let addr = current {
            if let address = addressToString(addr.pointee) {
                addresses.append(address)
            }
            current = addr.pointee.ai_next
        }

        return addresses.isEmpty ? nil : addresses
    }

    // MARK: - Address Conversion

    private func addressToString(_ info: addrinfo) -> String? {
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))

        let result = getnameinfo(
            info.ai_addr,
            info.ai_addrlen,
            &hostname,
            socklen_t(hostname.count),
            nil,
            0,
            NI_NUMERICHOST
        )

        guard result == 0 else { return nil }
        return String(cString: hostname)
    }

    // MARK: - Caching

    private func getCachedEntry(_ hostname: String) -> [String]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard let entry = cache[hostname] else { return nil }

        if Date().timeIntervalSince(entry.timestamp) > cacheTimeout {
            cache.removeValue(forKey: hostname)
            return nil
        }

        return entry.addresses
    }

    private func cacheEntry(_ hostname: String, addresses: [String]) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        cache[hostname] = CachedDNSEntry(addresses: addresses, timestamp: Date())
    }

    func clearCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        cache.removeAll()
    }

    // MARK: - Reverse DNS

    func reverseLookup(ip: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)

            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else {
                completion(nil)
                return
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))

            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    getnameinfo(
                        sockaddrPtr,
                        socklen_t(MemoryLayout<sockaddr_in>.size),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        0
                    )
                }
            }

            if result == 0 {
                completion(String(cString: hostname))
            } else {
                completion(nil)
            }
        }
    }
}

// MARK: - Cache Entry

struct CachedDNSEntry {
    let addresses: [String]
    let timestamp: Date
}

// MARK: - Errors

enum DNSError: Error, LocalizedError {
    case noAddressFound
    case invalidHostname
    case lookupFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAddressFound: return "No address found for hostname"
        case .invalidHostname: return "Invalid hostname"
        case .lookupFailed(let msg): return "DNS lookup failed: \(msg)"
        }
    }
}
