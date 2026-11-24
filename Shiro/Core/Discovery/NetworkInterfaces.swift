import Foundation
import Darwin

struct IPv4Interface {
    var name: String
    var address: UInt32   // host byte order
    var netmask: UInt32   // host byte order

    var addressString: String { NetworkInterfaces.string(from: address) }

    /// All host addresses on this subnet (capped to the surrounding /23 to keep sweeps cheap).
    func sweepAddresses(limit: Int = 510) -> [UInt32] {
        var mask = netmask
        let minMask: UInt32 = 0xFFFF_FE00 // /23
        if mask < minMask { mask = minMask }
        let network = address & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        var out: [UInt32] = []
        out.reserveCapacity(Int(broadcast - network))
        var a = network + 1
        while a < broadcast && out.count < limit {
            if a != address { out.append(a) }
            a += 1
        }
        out.append(broadcast) // directed broadcast, harmless if blocked
        return out
    }
}

enum NetworkInterfaces {
    static func ipv4Interfaces() -> [IPv4Interface] {
        var result: [IPv4Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = p.pointee.ifa_netmask else { continue }
            let name = String(cString: p.pointee.ifa_name)
            // Wi-Fi (en*), USB/Ethernet adapters (en*), personal hotspot bridge.
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            result.append(IPv4Interface(name: name, address: a, netmask: m))
        }
        return result.sorted { $0.name < $1.name }
    }

    static func string(from hostOrder: UInt32) -> String {
        "\(hostOrder >> 24 & 0xFF).\(hostOrder >> 16 & 0xFF).\(hostOrder >> 8 & 0xFF).\(hostOrder & 0xFF)"
    }

    static func parse(_ s: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    static func isLocal(_ host: String) -> Bool {
        guard let a = parse(host) else { return false }
        return ipv4Interfaces().contains { ($0.address & $0.netmask) == (a & $0.netmask) }
    }
}
