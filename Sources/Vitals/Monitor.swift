import Combine
import Foundation

struct Snapshot {
    var cpu = CPUReading()
    var gpu: GPUReading?
    var memory = MemoryReading()
    var network = NetworkReading()
    var disk = DiskReading()
    var power = PowerReading()
    var sensors = SensorReading()
    var processes = ProcessReading()
    var agents: [AgentReading] = []
    var uptime: TimeInterval = 0
    var thermal: ProcessInfo.ThermalState = .nominal
}

/// Fixed-length history for one metric; newest value last.
struct Series {
    static let capacity = 120
    private(set) var values: [Double] = []
    mutating func append(_ v: Double) {
        values.append(v.isFinite ? v : 0)
        if values.count > Series.capacity { values.removeFirst(values.count - Series.capacity) }
    }
    var peak: Double { values.max() ?? 0 }
}

struct History {
    var cpuUser = Series(), cpuSystem = Series()
    var gpu = Series()
    var memory = Series()
    var netDown = Series(), netUp = Series()
    var diskRead = Series(), diskWrite = Series()
    var cpuTemp = Series()
    var power = Series()
    var agentCPU: [String: Series] = [:]   // keyed by AgentReading.id

    mutating func record(_ s: Snapshot) {
        cpuUser.append(s.cpu.user)
        cpuSystem.append(s.cpu.system)
        gpu.append(s.gpu?.device ?? 0)
        memory.append(s.memory.usedFraction)
        netDown.append(s.network.downRate)
        netUp.append(s.network.upRate)
        diskRead.append(s.disk.readRate)
        diskWrite.append(s.disk.writeRate)
        if let t = s.sensors.cpu { cpuTemp.append(t) }
        if let w = s.power.systemPower { power.append(w) }
        var agents: [String: Series] = [:]
        for a in s.agents {
            var series = agentCPU[a.id] ?? Series()
            series.append(a.cpu)
            agents[a.id] = series
        }
        agentCPU = agents
    }
}

/// Samples every subsystem on a background queue and publishes snapshots on the main thread.
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var history = History()

    private let queue = DispatchQueue(label: "app.vitals.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var interval: Double = 1

    // Samplers are only touched on `queue`.
    private let cpu = CPUSampler()
    private let gpu = GPUSampler()
    private let memory = MemorySampler()
    private let network = NetworkSampler()
    private let disk = DiskSampler()
    private let processes = ProcessSampler()
    private let agents = AgentSampler()
    private let power: PowerSampler
    private let sensors: SensorSampler
    private let bootTime = Sys.bootTime

    // Slow-changing or expensive readings are refreshed less often than the tick.
    private var lastSensors = SensorReading(), lastSensorTime = -Double.infinity
    private var lastProcesses = ProcessReading(), lastProcessTime = -Double.infinity
    private static let sensorPeriod = 3.0
    private static let processPeriod = 2.0

    init() {
        let smc = SMC()
        power = PowerSampler(smc: smc)
        sensors = SensorSampler(smc: smc)
    }

    func start(interval: Double) {
        self.interval = max(0.25, interval)
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: self.interval, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        var s = Snapshot()
        s.cpu = cpu.sample()
        s.gpu = gpu.sample()
        s.memory = memory.sample()
        s.network = network.sample()
        s.disk = disk.sample()
        s.power = power.sample()
        let now = monotonicSeconds()
        if now - lastSensorTime >= SystemMonitor.sensorPeriod - 0.05 {
            lastSensors = sensors.sample()
            lastSensorTime = now
        }
        if now - lastProcessTime >= max(SystemMonitor.processPeriod, interval) - 0.05 {
            lastProcesses = processes.sample()
            lastProcessTime = now
        }
        s.sensors = lastSensors
        s.processes = lastProcesses
        s.agents = agents.sample()
        s.thermal = ProcessInfo.processInfo.thermalState
        if let bootTime { s.uptime = Date().timeIntervalSince(bootTime) }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = s
            self.history.record(s)
        }
    }
}
