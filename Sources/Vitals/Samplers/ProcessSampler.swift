import Darwin
import Foundation

struct ProcessUsage: Identifiable, Equatable {
    var id: pid_t { pid }
    var pid: pid_t
    var name: String
    var cpu: Double       // fraction of one core (1.5 = 150%, like Activity Monitor)
    var memory: UInt64    // physical footprint in bytes
}

struct ProcessReading {
    var topCPU: [ProcessUsage] = []
    var topMemory: [ProcessUsage] = []
    var count: Int = 0
}

/// Per-process CPU and memory via proc_pid_rusage. Without root this covers processes
/// owned by the current user (system daemons running as root are skipped).
final class ProcessSampler {
    private var previousCPU: [pid_t: UInt64] = [:]
    private var previousTime: Double = 0
    private var names: [pid_t: String] = [:]
    private let ticksToNanos: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb.denom == 0 ? 1 : Double(tb.numer) / Double(tb.denom)
    }()

    func sample(limit: Int = 5) -> ProcessReading {
        let now = monotonicSeconds()
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return ProcessReading() }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let found = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard found > 0 else { return ProcessReading() }

        let dt = now - previousTime
        var cpuNow: [pid_t: UInt64] = [:]
        var usages: [ProcessUsage] = []
        usages.reserveCapacity(found)
        var liveNames: [pid_t: String] = [:]

        for pid in pids.prefix(found) where pid > 0 {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { continue }
            let cpuTime = info.ri_user_time + info.ri_system_time
            cpuNow[pid] = cpuTime

            let name = names[pid] ?? ProcessSampler.name(of: pid)
            liveNames[pid] = name

            var cpu = 0.0
            if let prev = previousCPU[pid], dt > 0, cpuTime >= prev {
                cpu = Double(cpuTime - prev) * ticksToNanos / 1_000_000_000 / dt
            }
            usages.append(ProcessUsage(pid: pid, name: name, cpu: cpu, memory: info.ri_phys_footprint))
        }

        previousCPU = cpuNow
        previousTime = now
        names = liveNames

        var reading = ProcessReading()
        reading.count = found
        reading.topCPU = Array(usages.sorted { $0.cpu > $1.cpu }.prefix(limit))
        reading.topMemory = Array(usages.sorted { $0.memory > $1.memory }.prefix(limit))
        return reading
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { return String(cString: buffer) }
        return "pid \(pid)"
    }
}
