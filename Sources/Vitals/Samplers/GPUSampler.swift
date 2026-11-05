import Foundation
import IOKit

struct GPUReading {
    var name: String = "GPU"
    var coreCount: Int?
    var device: Double = 0      // 0...1 overall utilisation
    var renderer: Double = 0
    var tiler: Double = 0
    var memoryInUse: UInt64 = 0 // bytes of unified memory the GPU is using
}

/// Reads `PerformanceStatistics` from the IOAccelerator service (no root needed).
final class GPUSampler {
    private var cachedName: String?
    private var cachedCores: Int?

    func sample() -> GPUReading? {
        var best: GPUReading?
        IOKitUtil.forEachService("IOAccelerator") { service in
            guard let stats = IOKitUtil.property(service, "PerformanceStatistics") as? [String: Any] else { return }
            var r = GPUReading()
            func pct(_ key: String) -> Double { Double((stats[key] as? NSNumber)?.intValue ?? 0) / 100 }
            r.device = pct("Device Utilization %")
            r.renderer = pct("Renderer Utilization %")
            r.tiler = pct("Tiler Utilization %")
            r.memoryInUse = (stats["In use system memory"] as? NSNumber)?.uint64Value ?? 0
            if cachedName == nil {
                cachedName = IOKitUtil.property(service, "model") as? String
                cachedCores = (IOKitUtil.property(service, "gpu-core-count") as? NSNumber)?.intValue
            }
            r.name = cachedName ?? "GPU"
            r.coreCount = cachedCores
            // With several GPUs (Intel Macs), report the busiest one.
            if best == nil || r.device > best!.device { best = r }
        }
        return best
    }
}
