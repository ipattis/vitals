import Foundation
import IOKit

// MARK: - Temperature sensors via the IOHID event system
// These functions are exported by IOKit but not in the public headers; they're the same
// calls Activity-style monitors use to read Apple Silicon die temperatures without root.

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timeout: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

private let kIOHIDEventTypeTemperature: Int64 = 15

struct Fan: Identifiable {
    var id: Int
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double
    var fraction: Double { maxRPM > minRPM ? max(0, min(1, (rpm - minRPM) / (maxRPM - minRPM))) : 0 }
}

struct SensorReading {
    var cpu: Double?            // average CPU / SoC die temperature, °C
    var cpuMax: Double?
    var gpu: Double?
    var ssd: Double?
    var battery: Double?
    var fans: [Fan] = []
    var all: [(name: String, value: Double)] = []
}

final class SensorSampler {
    private var client: AnyObject?
    private var services: [(name: String, service: AnyObject)] = []
    private let smc: SMC?
    private var fanCount: Int?

    init(smc: SMC?) {
        self.smc = smc
        guard let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        client = c
        // Usage page 0xff00 / usage 5 = Apple vendor temperature sensors.
        _ = IOHIDEventSystemClientSetMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        if let list = IOHIDEventSystemClientCopyServices(c)?.takeRetainedValue() as? [AnyObject] {
            for s in list {
                let name = (IOHIDServiceClientCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String) ?? "Sensor"
                services.append((name, s))
            }
        }
    }

    func sample() -> SensorReading {
        var r = SensorReading()
        var grouped: [String: [Double]] = [:]
        for (name, service) in services {
            guard let event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0)?.takeRetainedValue() else { continue }
            let value = IOHIDEventGetFloatValue(event, Int32(kIOHIDEventTypeTemperature << 16))
            guard value > 0, value < 150 else { continue }
            grouped[name, default: []].append(value)
        }
        // Sensors are often reported twice; collapse duplicates to their mean.
        r.all = grouped.map { ($0.key, $0.value.reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        func values(_ match: (String) -> Bool) -> [Double] { r.all.filter { match($0.name) }.map(\.value) }
        func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

        // M1/M2 expose per-cluster sensors (pACC/eACC); M3+ expose "PMU tdie" die sensors.
        var cpu = values { $0.contains("pACC") || $0.contains("eACC") }
        if cpu.isEmpty { cpu = values { $0.contains("tdie") } }
        if cpu.isEmpty { cpu = values { $0.localizedCaseInsensitiveContains("CPU") } }
        r.cpu = mean(cpu)
        r.cpuMax = cpu.max()
        r.gpu = mean(values { $0.contains("GPU") })
        r.ssd = mean(values { $0.contains("NAND") || $0.localizedCaseInsensitiveContains("SSD") })
        r.battery = mean(values { $0.localizedCaseInsensitiveContains("battery") })

        if let smc {
            if fanCount == nil { fanCount = Int(smc.double("FNum") ?? 0) }
            for i in 0..<(fanCount ?? 0) {
                guard let rpm = smc.double("F\(i)Ac"), rpm.isFinite else { continue }
                func finite(_ v: Double?) -> Double { v.flatMap { $0.isFinite ? $0 : nil } ?? 0 }
                r.fans.append(Fan(id: i, rpm: max(0, rpm),
                                  minRPM: finite(smc.double("F\(i)Mn")),
                                  maxRPM: finite(smc.double("F\(i)Mx"))))
            }
        }
        return r
    }
}

// MARK: - System Management Controller (fans, power)

/// Minimal read-only SMC client. The 80-byte SMCParamStruct is built as raw bytes at
/// fixed offsets so Swift struct padding can't break the layout the kernel expects.
final class SMC {
    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: (size: UInt32, type: UInt32)] = [:]

    private enum Offset { static let key = 0, dataSize = 28, dataType = 32, result = 40, command = 42, bytes = 48 }
    private enum Command { static let readKey: UInt8 = 5, keyInfo: UInt8 = 9 }

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(connection) }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = 80
        let result = input.withUnsafeBytes { inBuf in
            output.withUnsafeMutableBytes { outBuf in
                IOConnectCallStructMethod(connection, 2, inBuf.baseAddress, 80, outBuf.baseAddress, &outputSize)
            }
        }
        guard result == kIOReturnSuccess, output[Offset.result] == 0 else { return nil }
        return output
    }

    private static func put(_ value: UInt32, into buffer: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: value) { for (i, b) in $0.enumerated() { buffer[offset + i] = b } }
    }

    private static func get(_ buffer: [UInt8], at offset: Int) -> UInt32 {
        buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        let code = SMC.fourCC(key)
        var info = infoCache[code]
        if info == nil {
            var input = [UInt8](repeating: 0, count: 80)
            SMC.put(code, into: &input, at: Offset.key)
            input[Offset.command] = Command.keyInfo
            guard let out = call(input) else { return nil }
            info = (SMC.get(out, at: Offset.dataSize), SMC.get(out, at: Offset.dataType))
            infoCache[code] = info
        }
        guard let info, info.size > 0, info.size <= 32 else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        SMC.put(code, into: &input, at: Offset.key)
        SMC.put(info.size, into: &input, at: Offset.dataSize)
        input[Offset.command] = Command.readKey
        guard let out = call(input) else { return nil }
        let typeBytes = withUnsafeBytes(of: info.type.bigEndian) { Array($0) }
        let type = String(bytes: typeBytes, encoding: .ascii) ?? ""
        return (type, Array(out[Offset.bytes..<(Offset.bytes + Int(info.size))]))
    }

    func double(_ key: String) -> Double? {
        guard let (type, b) = read(key) else { return nil }
        switch type {
        case "flt " where b.count >= 4:
            return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        case "fpe2" where b.count >= 2:
            return Double((UInt16(b[0]) << 8) | UInt16(b[1])) / 4
        case "sp78" where b.count >= 2:
            return Double(Int16(bitPattern: (UInt16(b[0]) << 8) | UInt16(b[1]))) / 256
        case "ui8 " where b.count >= 1:
            return Double(b[0])
        case "ui16" where b.count >= 2:
            return Double((UInt16(b[0]) << 8) | UInt16(b[1]))
        case "ui32" where b.count >= 4:
            return Double(b.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default:
            return nil
        }
    }
}
