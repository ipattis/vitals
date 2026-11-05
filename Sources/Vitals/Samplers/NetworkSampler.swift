import Darwin
import Foundation
import SystemConfiguration

struct InterfaceStatus: Identifiable {
    var id: String { bsdName }
    var bsdName: String
    var displayName: String
    var ipv4: String
    var downRate: Double
    var upRate: Double
    var isPrimary: Bool
}

struct NetworkReading {
    /// Bytes/sec summed over physical interfaces (en*), so VPN traffic isn't double counted.
    var downRate: Double = 0
    var upRate: Double = 0
    var sessionDown: UInt64 = 0
    var sessionUp: UInt64 = 0
    var primaryName: String?
    var primaryAddress: String?
    var interfaces: [InterfaceStatus] = []
}

final class NetworkSampler {
    private var previous: [String: (down: UInt64, up: UInt64)] = [:]
    private var previousTime: Double = 0
    private var sessionDown: UInt64 = 0
    private var sessionUp: UInt64 = 0

    private let store = SCDynamicStoreCreate(nil, "Vitals" as CFString, nil, nil)
    private var displayNames: [String: String] = [:]
    private var addresses: [String: String] = [:]
    private var primary: String?
    private var lastMetaRefresh: Double = -100

    func sample() -> NetworkReading {
        let now = monotonicSeconds()
        if now - lastMetaRefresh > 5 { refreshMetadata(); lastMetaRefresh = now }

        let counters = readCounters()
        let dt = now - previousTime
        var reading = NetworkReading()
        var rates: [String: (Double, Double)] = [:]

        if !previous.isEmpty, dt > 0 {
            var physDown: UInt64 = 0, physUp: UInt64 = 0
            for (name, c) in counters {
                guard let p = previous[name] else { continue }
                let d = c.down >= p.down ? c.down - p.down : 0
                let u = c.up >= p.up ? c.up - p.up : 0
                rates[name] = (Double(d) / dt, Double(u) / dt)
                if name.hasPrefix("en") { physDown += d; physUp += u }
            }
            sessionDown += physDown
            sessionUp += physUp
            reading.downRate = Double(physDown) / dt
            reading.upRate = Double(physUp) / dt
        }
        previous = counters
        previousTime = now

        reading.sessionDown = sessionDown
        reading.sessionUp = sessionUp
        if let primary {
            reading.primaryName = friendlyName(primary)
            reading.primaryAddress = addresses[primary]
        }
        reading.interfaces = addresses.keys.sorted { a, b in
            if a == primary { return true }
            if b == primary { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.map { name in
            InterfaceStatus(bsdName: name, displayName: friendlyName(name), ipv4: addresses[name] ?? "",
                            downRate: rates[name]?.0 ?? 0, upRate: rates[name]?.1 ?? 0,
                            isPrimary: name == primary)
        }
        return reading
    }

    private func friendlyName(_ bsd: String) -> String {
        if let n = displayNames[bsd] { return n }
        if bsd.hasPrefix("utun") || bsd.hasPrefix("ipsec") || bsd.hasPrefix("ppp") { return "VPN" }
        if bsd.hasPrefix("bridge") { return "Bridge" }
        return bsd
    }

    /// Byte counters for every non-loopback interface via NET_RT_IFLIST2 (64-bit counters).
    private func readCounters() -> [String: (down: UInt64, up: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: (down: UInt64, up: UInt64)] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if msg.ifm_flags & IFF_LOOPBACK == 0, if_indextoname(UInt32(msg.ifm_index), &nameBuffer) != nil {
                        result[String(cString: nameBuffer)] = (msg.ifm_data.ifi_ibytes, msg.ifm_data.ifi_obytes)
                    }
                }
                offset += messageLength
            }
        }
        return result
    }

    private func refreshMetadata() {
        if let store,
           let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            primary = global["PrimaryInterface"] as? String
        } else {
            primary = nil
        }

        if displayNames.isEmpty, let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for iface in all {
                if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
                   let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
                    displayNames[bsd] = name
                }
            }
        }

        var found: [String: String] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let ifa = cursor {
                defer { cursor = ifa.pointee.ifa_next }
                guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                      ifa.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                      ifa.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
                let name = String(cString: ifa.pointee.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
                   found[name] == nil {
                    found[name] = String(cString: host)
                }
            }
            freeifaddrs(first)
        }
        addresses = found
    }
}
