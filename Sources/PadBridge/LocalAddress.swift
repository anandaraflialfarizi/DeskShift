import Darwin
import Foundation
import SystemConfiguration

func localIPv4Address() -> String? {
    let state = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    let primary = state?[kSCDynamicStorePropNetPrimaryInterface as String] as? String
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let interfaces else { return nil }
    defer { freeifaddrs(interfaces) }

    let flags = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
    var fallback: String?
    for entry in sequence(first: interfaces, next: { $0.pointee.ifa_next }) {
        let interface = entry.pointee
        guard interface.ifa_flags & flags == flags, let address = interface.ifa_addr,
              address.pointee.sa_family == AF_INET else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let ip = String(cString: host)
        if String(cString: interface.ifa_name) == primary { return ip }
        if fallback == nil { fallback = ip }
    }
    return fallback
}
