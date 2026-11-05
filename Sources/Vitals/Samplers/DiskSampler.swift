import Foundation
import IOKit

struct VolumeStatus: Identifiable {
    var id: String { path }
    var name: String
    var path: String
    var total: UInt64
    var available: UInt64
    var isRoot: Bool
    var used: UInt64 { total > available ? total - available : 0 }
    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct DiskReading {
    var readRate: Double = 0   // bytes/sec across all block devices
    var writeRate: Double = 0
    var readOps: Double = 0    // operations/sec
    var writeOps: Double = 0
    var volumes: [VolumeStatus] = []
}

final class DiskSampler {
    private var previous: (read: UInt64, write: UInt64, rOps: UInt64, wOps: UInt64)?
    private var previousTime: Double = 0
    private var volumes: [VolumeStatus] = []
    private var lastVolumeRefresh: Double = -100

    func sample() -> DiskReading {
        let now = monotonicSeconds()
        var reading = DiskReading()

        var read: UInt64 = 0, write: UInt64 = 0, rOps: UInt64 = 0, wOps: UInt64 = 0
        IOKitUtil.forEachService("IOBlockStorageDriver") { service in
            guard let stats = IOKitUtil.property(service, "Statistics") as? [String: Any] else { return }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            rOps += (stats["Operations (Read)"] as? NSNumber)?.uint64Value ?? 0
            wOps += (stats["Operations (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        let dt = now - previousTime
        if let p = previous, dt > 0 {
            func rate(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? Double(a - b) / dt : 0 }
            reading.readRate = rate(read, p.read)
            reading.writeRate = rate(write, p.write)
            reading.readOps = rate(rOps, p.rOps)
            reading.writeOps = rate(wOps, p.wOps)
        }
        previous = (read, write, rOps, wOps)
        previousTime = now

        // Capacity barely changes, so only re-query volumes every 15 s.
        if now - lastVolumeRefresh > 15 {
            volumes = DiskSampler.readVolumes()
            lastVolumeRefresh = now
        }
        reading.volumes = volumes
        return reading
    }

    private static func readVolumes() -> [VolumeStatus] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey,
                                      .volumeIsRootFileSystemKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var result: [VolumeStatus] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsBrowsable ?? true,
                  let total = v.volumeTotalCapacity, total > 0 else { continue }
            let important = v.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? 0
            let plain = UInt64(max(0, v.volumeAvailableCapacity ?? 0))
            let isRoot = v.volumeIsRootFileSystem ?? (url.path == "/")
            result.append(VolumeStatus(name: v.volumeName ?? url.lastPathComponent, path: url.path,
                                       total: UInt64(total), available: max(important, plain), isRoot: isRoot))
        }
        return result.sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
    }
}
