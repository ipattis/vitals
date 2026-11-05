import Darwin
import Foundation
import IOKit

enum CoreKind { case efficiency, performance, unknown }

struct CPUReading {
    var user: Double = 0        // 0...1 of all cores
    var system: Double = 0      // 0...1 of all cores
    var cores: [Double] = []    // 0...1 per logical core
    var coreKinds: [CoreKind] = []
    var loadAverage: [Double] = [0, 0, 0]
    var total: Double { min(1, user + system) }
}

/// Per-core tick deltas from `host_processor_info`.
final class CPUSampler {
    private let host = mach_host_self()
    private var previous: [UInt32] = []
    let coreKinds: [CoreKind]

    init() {
        coreKinds = CPUSampler.detectCoreKinds()
    }

    func sample() -> CPUReading {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return CPUReading() }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let n = Int(cpuCount)
        let stride = Int(CPU_STATE_MAX)
        var current = [UInt32](repeating: 0, count: n * stride)
        for i in 0..<(n * stride) { current[i] = UInt32(bitPattern: info[i]) }
        defer { previous = current }

        var reading = CPUReading()
        reading.coreKinds = coreKinds.count == n ? coreKinds : Array(repeating: .unknown, count: n)
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { reading.loadAverage = load }

        guard previous.count == current.count else {
            reading.cores = Array(repeating: 0, count: n)
            return reading
        }

        var sumUser: UInt64 = 0, sumSystem: UInt64 = 0, sumAll: UInt64 = 0
        reading.cores.reserveCapacity(n)
        for c in 0..<n {
            let base = c * stride
            func delta(_ state: Int32) -> UInt64 {
                UInt64(current[base + Int(state)] &- previous[base + Int(state)])
            }
            let user = delta(CPU_STATE_USER) + delta(CPU_STATE_NICE)
            let system = delta(CPU_STATE_SYSTEM)
            let idle = delta(CPU_STATE_IDLE)
            let all = user + system + idle
            reading.cores.append(all == 0 ? 0 : Double(user + system) / Double(all))
            sumUser += user; sumSystem += system; sumAll += all
        }
        if sumAll > 0 {
            reading.user = Double(sumUser) / Double(sumAll)
            reading.system = Double(sumSystem) / Double(sumAll)
        }
        return reading
    }

    /// Reads "cluster-type" (E/P) for each core from the device tree; falls back to sysctl counts.
    private static func detectCoreKinds() -> [CoreKind] {
        let count = Int(Sys.int("hw.logicalcpu") ?? 0)
        var kinds = [CoreKind](repeating: .unknown, count: count)
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if cpus != 0 {
            defer { IOObjectRelease(cpus) }
            var iterator: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(cpus, "IODeviceTree", &iterator) == KERN_SUCCESS {
                defer { IOObjectRelease(iterator) }
                while case let entry = IOIteratorNext(iterator), entry != 0 {
                    defer { IOObjectRelease(entry) }
                    guard let id = (IOKitUtil.property(entry, "logical-cpu-id") as? NSNumber)?.intValue,
                          id >= 0, id < count,
                          let data = IOKitUtil.property(entry, "cluster-type") as? Data,
                          let first = data.first else { continue }
                    kinds[id] = first == UInt8(ascii: "E") ? .efficiency : (first == UInt8(ascii: "P") ? .performance : .unknown)
                }
            }
        }
        if kinds.contains(.unknown), let e = Sys.int("hw.perflevel1.logicalcpu"), Sys.int("hw.nperflevels") ?? 1 > 1 {
            // Apple Silicon lists efficiency cores first.
            kinds = (0..<count).map { $0 < Int(e) ? .efficiency : .performance }
        }
        return kinds
    }
}
