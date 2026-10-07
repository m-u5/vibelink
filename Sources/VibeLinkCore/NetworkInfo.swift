import Foundation
import SystemConfiguration

public struct PrimaryInterface: Equatable {
    public let name: String
    public let index: UInt32
    public let ipv4: String
}

public enum NetworkInfo {
    /// The interface carrying the default IPv4 route (Wi-Fi or Ethernet), with its address.
    public static func primary() -> PrimaryInterface? {
        guard let store = SCDynamicStoreCreate(nil, "vibelink" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let name = dict["PrimaryInterface"] as? String,
              let ip = ipv4Addresses()[name]?.first else { return nil }
        let index = if_nametoindex(name)
        guard index != 0 else { return nil }
        return PrimaryInterface(name: name, index: index, ipv4: ip)
    }

    /// IPv4 addresses per interface name.
    public static func ipv4Addresses() -> [String: [String]] {
        var result: [String: [String]] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return result }
        defer { freeifaddrs(head) }
        var p = head
        while let ifa = p {
            if let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    result[String(cString: ifa.pointee.ifa_name), default: []].append(String(cString: host))
                }
            }
            p = ifa.pointee.ifa_next
        }
        return result
    }

    public static func allLocalIPv4() -> Set<String> {
        Set(ipv4Addresses().values.flatMap { $0 })
    }
}
