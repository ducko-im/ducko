import Darwin

/// Enumerates local network interface addresses for direct SOCKS5 candidates.
enum NetworkInterfaces {
    struct Address {
        let ip: String
        let isIPv4: Bool
    }

    /// Returns non-loopback, non-link-local addresses for all active interfaces.
    static func localAddresses() -> [Address] {
        var ifaddrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrs) == 0, let first = ifaddrs else { return [] }
        defer { freeifaddrs(first) }

        var addresses: [Address] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first

        while let ifa = current {
            defer { current = ifa.pointee.ifa_next }

            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0, let addr = ifa.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)

            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))

            switch family {
            case AF_INET:
                addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var inAddr = sin.pointee.sin_addr
                    inet_ntop(AF_INET, &inAddr, &buffer, socklen_t(buffer.count))
                }
                let ip = String(cString: buffer)
                addresses.append(Address(ip: ip, isIPv4: true))

            case AF_INET6:
                addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    var in6Addr = sin6.pointee.sin6_addr
                    inet_ntop(AF_INET6, &in6Addr, &buffer, socklen_t(buffer.count))
                }
                let ip = String(cString: buffer)
                // Skip link-local IPv6 addresses (fe80::)
                guard !ip.hasPrefix("fe80") else { continue }
                addresses.append(Address(ip: ip, isIPv4: false))

            default:
                continue
            }
        }

        return addresses
    }
}
