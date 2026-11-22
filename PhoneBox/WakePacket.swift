import Foundation
import Darwin

/// An IPv4 address of this phone on the local network, the broadcast address of its subnet, its interface and prefix length.
struct LanLink {
    let address: UInt32      // host byte order
    let netmask: UInt32
    let name: String

    var broadcast: UInt32 { address | ~netmask }
    func contains(_ other: UInt32) -> Bool { (address & netmask) == (other & netmask) }
}

/// The Wake-on-LAN magic packet: six 0xFF bytes, then the target's MAC 16 times (102 bytes, UDP port 9).
enum WakePacket {
    static let port: UInt16 = 9

    /// AA:BB:CC:DD:EE:FF, AA-BB-CC-DD-EE-FF or AABBCCDDEEFF; nil for anything else, all-zero or broadcast.
    static func parseMac(_ text: String) -> [UInt8]? {
        let hex = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        guard hex.count == 12, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        var mac = [UInt8]()
        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            mac.append(byte)
            index = next
        }
        if mac.allSatisfy({ $0 == 0 }) || mac.allSatisfy({ $0 == 0xFF }) { return nil }
        return mac
    }

    static func format(_ mac: [UInt8]) -> String { mac.map { String(format: "%02X", $0) }.joined(separator: ":") }

    /// The MACs an agent reported, as "AA:BB:CC:DD:EE:FF": invalid entries dropped, duplicates removed, at most 4.
    /// Nil when there is nothing usable: that is no new information, so the caller keeps the list it has.
    static func macs(from list: [Any]?) -> [String]? {
        guard let list else { return nil }
        var seen = Set<String>()
        let macs = list.compactMap { ($0 as? String).flatMap(parseMac) }.map(format).filter { seen.insert($0).inserted }.prefix(4)
        return macs.isEmpty ? nil : Array(macs)
    }

    /// An IPv4 address written out as four numbers, never a name: a lookup here would reach for DNS.
    static func ipv4Literal(_ text: String) -> UInt32? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for p in parts {
            guard (1...3).contains(p.count), p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = UInt32(p), n <= 255 else { return nil }
            value = (value << 8) | n
        }
        return value
    }

    /// The links on a network the computer is on: their subnet holds one of the computer's stored [hosts]. The packet
    /// carries the computer's MAC, so it must not go out on a café's or a hotel's network.
    static func linksOnOwnNetwork(hosts: [String], links: [LanLink]) -> [LanLink] {
        let addresses = hosts.compactMap(ipv4Literal)
        return links.filter { link in addresses.contains { link.contains($0) } }
    }

    /// The phone's private IPv4 addresses on Wi-Fi / Ethernet (en*), read from the network interfaces.
    static func lanLinks() -> [LanLink] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var links: [LanLink] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, let mask = ifa.ifa_netmask, addr.pointee.sa_family == sa_family_t(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let b0 = (a >> 24) & 0xFF, b1 = (a >> 16) & 0xFF
            let isPrivate = b0 == 10 || (b0 == 172 && (16...31).contains(b1)) || (b0 == 192 && b1 == 168)
            if isPrivate { links.append(LanLink(address: a, netmask: m, name: name)) }
        }
        return links
    }

    static func build(_ mac: [UInt8]) -> [UInt8] {
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += mac }
        return packet
    }

    /// Sends the packet for every MAC to the limited broadcast and to each link's subnet broadcast, 3 rounds, 100 ms
    /// apart. Every send is tried on its own. Returns how many sends worked.
    @discardableResult
    static func burst(macs: [[UInt8]], links: [LanLink], hosts: [String] = []) -> Int {
        // besides the broadcasts, straight to the computer's own addresses on that network: iOS may refuse broadcasts to
        // an app without Apple's multicast entitlement, and a network card often still answers its last address
        let unicast = hosts.compactMap(ipv4Literal)
        var worked = 0
        for round in 0..<3 {
            if round > 0 { Thread.sleep(forTimeInterval: 0.1) }
            for link in links {
                for mac in macs {
                    let packet = build(mac)
                    for target in [UInt32(0xFFFF_FFFF), link.broadcast] + unicast.filter({ link.contains($0) }) {
                        if send(packet, to: target, from: link) { worked += 1 }
                    }
                }
            }
        }
        return worked
    }

    /// One UDP datagram, bound to the link's own address so it leaves through that interface.
    private static func send(_ packet: [UInt8], to target: UInt32, from link: LanLink) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = link.address.bigEndian
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if bound != 0 { return false }
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = port.bigEndian
        remote.sin_addr.s_addr = target.bigEndian
        let sent = packet.withUnsafeBytes { buffer in
            withUnsafePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == packet.count
    }
}
