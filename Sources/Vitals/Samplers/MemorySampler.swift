import Darwin
import Foundation

enum PressureLevel: Int { case normal = 1, warning = 2, critical = 4 }

struct MemoryReading {
    var total: UInt64 = Sys.physicalMemory
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: Double = 0               // 0...1, derived from kern.memorystatus_level
    var pressureLevel: PressureLevel = .normal

    /// Matches Activity Monitor's "Memory Used" (App + Wired + Compressed).
    var used: UInt64 { app + wired + compressed }
    var free: UInt64 { total > used + cached ? total - used - cached : 0 }
    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

final class MemorySampler {
    private let host = mach_host_self()

    func sample() -> MemoryReading {
        var r = MemoryReading()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = Sys.pageSize
            let anonymous = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            r.app = (anonymous > purgeable ? anonymous - purgeable : 0) * page
            r.wired = UInt64(stats.wire_count) * page
            r.compressed = UInt64(stats.compressor_page_count) * page
            r.cached = (UInt64(stats.external_page_count) + purgeable) * page
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            r.swapUsed = swap.xsu_used
            r.swapTotal = swap.xsu_total
        }

        if let level = Sys.int("kern.memorystatus_level") {
            r.pressure = max(0, min(1, 1 - Double(level) / 100))
        }
        if let lvl = Sys.int("kern.memorystatus_vm_pressure_level"), let p = PressureLevel(rawValue: Int(lvl)) {
            r.pressureLevel = p
        }
        return r
    }
}
