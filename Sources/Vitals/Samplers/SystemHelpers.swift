import Darwin
import Foundation
import IOKit

/// Small wrappers around sysctl and IOKit so the samplers stay readable.
enum Sys {
    static func int(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // sysctl may hand back a 32-bit value; the upper bytes stay zero (little-endian).
        if size == 4 { return Int64(Int32(truncatingIfNeeded: value)) }
        return value
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static var bootTime: Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    static let pageSize: UInt64 = UInt64(Sys.int("hw.pagesize") ?? 16384)
    static let physicalMemory: UInt64 = UInt64(Sys.int("hw.memsize") ?? 0)

    /// Friendly machine name, e.g. "MacBook Pro (16-inch, Nov 2024)".
    static let modelName: String = {
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if product != 0 {
            defer { IOObjectRelease(product) }
            if let data = IOKitUtil.property(product, "product-name") as? Data,
               let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
               !name.isEmpty {
                return name
            }
        }
        let raw = string("hw.model") ?? "Mac"
        if raw.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if raw.hasPrefix("MacBookAir") { return "MacBook Air" }
        if raw.hasPrefix("Macmini") { return "Mac mini" }
        if raw.hasPrefix("iMac") { return "iMac" }
        if raw.hasPrefix("MacPro") { return "Mac Pro" }
        return raw
    }()
}

enum IOKitUtil {
    /// Calls `body` for each service matching `className`, releasing each one afterwards.
    static func forEachService(_ className: String, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dict
    }
}

/// Monotonic clock in seconds, used to turn counters into rates.
@inline(__always) func monotonicSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}
