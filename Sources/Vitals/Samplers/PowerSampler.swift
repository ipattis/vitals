import Foundation
import IOKit

struct PowerReading {
    var hasBattery = false
    var level: Double = 0            // 0...1
    var isCharging = false
    var isPluggedIn = false
    var isFullyCharged = false
    var minutesRemaining: Int?       // to empty when on battery, to full when charging
    var cycleCount: Int?
    var health: Double?              // current max capacity / design capacity
    var batteryTemperature: Double?  // °C
    var batteryPower: Double?        // W, negative while discharging
    var systemPower: Double?         // W, whole-machine draw
    var adapterWatts: Int?
}

/// Battery details come from the AppleSmartBattery registry entry; system power from
/// its PowerTelemetryData, falling back to the SMC "PSTR" key on desktops.
final class PowerSampler {
    private let smc: SMC?

    init(smc: SMC?) { self.smc = smc }

    func sample() -> PowerReading {
        var r = PowerReading()
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if battery != 0 {
            defer { IOObjectRelease(battery) }
            let p = IOKitUtil.properties(battery)
            func int(_ k: String) -> Int64? { (p[k] as? NSNumber)?.int64Value }
            func bool(_ k: String) -> Bool { (p[k] as? NSNumber)?.boolValue ?? false }

            if let current = int("CurrentCapacity"), let max = int("MaxCapacity"), max > 0, bool("BatteryInstalled") || p["BatteryInstalled"] == nil {
                r.hasBattery = true
                r.level = Double(current) / Double(max)
            }
            r.isCharging = bool("IsCharging")
            r.isPluggedIn = bool("ExternalConnected")
            r.isFullyCharged = bool("FullyCharged")
            r.cycleCount = int("CycleCount").map(Int.init)
            if let raw = int("AppleRawMaxCapacity"), let design = int("DesignCapacity"), design > 0 {
                r.health = min(1, Double(raw) / Double(design))
            }
            if let t = int("Temperature"), t > 0 { r.batteryTemperature = Double(t) / 100 }
            if let mv = int("Voltage"), let ma = int("InstantAmperage") ?? int("Amperage") {
                r.batteryPower = Double(mv) * Double(ma) / 1_000_000
            }
            let minutes = r.isCharging ? int("AvgTimeToFull") : (r.isPluggedIn ? nil : int("TimeRemaining") ?? int("AvgTimeToEmpty"))
            if let m = minutes, m > 0, m < 65535 { r.minutesRemaining = Int(m) }
            if let adapter = p["AdapterDetails"] as? [String: Any], let w = (adapter["Watts"] as? NSNumber)?.intValue, w > 0 {
                r.adapterWatts = w
            }
            if let telemetry = p["PowerTelemetryData"] as? [String: Any],
               let load = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue, load > 0 {
                r.systemPower = load / 1000
            }
        }
        if r.systemPower == nil, let pstr = smc?.double("PSTR"), pstr > 0, pstr < 2000 {
            r.systemPower = pstr
        }
        return r
    }
}
