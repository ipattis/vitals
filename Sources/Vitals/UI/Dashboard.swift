import SwiftUI

struct DashboardView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var settings: AppSettings

    var body: some View {
        let s = monitor.snapshot
        let h = monitor.history
        VStack(spacing: 0) {
            HeaderBar(snapshot: s, settings: settings)
            ScrollView {
                MasonryLayout(minColumnWidth: 340, spacing: 12) {
                    AgentsCard(s: s, h: h, interval: settings.interval)
                    CPUCard(s: s, h: h, interval: settings.interval)
                    GPUCard(s: s, h: h, interval: settings.interval)
                    MemoryCard(s: s, h: h, interval: settings.interval)
                    NetworkCard(s: s, h: h, interval: settings.interval)
                    DiskCard(s: s, h: h, interval: settings.interval)
                    SensorsCard(s: s, h: h, interval: settings.interval)
                    if s.power.hasBattery || s.power.systemPower != nil {
                        PowerCard(s: s, h: h, interval: settings.interval)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.never)
        }
        .background(Palette.page)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Header

private struct HeaderBar: View {
    var snapshot: Snapshot
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            Text("Vitals").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.textPrimary)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
            Spacer()
            Menu {
                Picker("Update every", selection: $settings.interval) {
                    Text("0.5 seconds").tag(0.5)
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
                .pickerStyle(.inline)
            } label: {
                Label(settings.interval < 1 ? "0.5s" : "\(Int(settings.interval))s", systemImage: "timer")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(Palette.textSecondary)
            .help("Update interval")

            Button {
                settings.alwaysOnTop.toggle()
            } label: {
                Image(systemName: settings.alwaysOnTop ? "pin.fill" : "pin")
                    .foregroundStyle(settings.alwaysOnTop ? Palette.textPrimary : Palette.textSecondary)
            }
            .buttonStyle(.borderless)
            .help(settings.alwaysOnTop ? "Stop keeping the window on top" : "Keep the window on top of other windows")
        }
        .padding(.leading, 80)   // room for the traffic-light buttons
        .padding(.trailing, 16)
        .frame(height: 38)
    }

    private var subtitle: String {
        var parts = [Sys.modelName]
        if let gpu = snapshot.gpu { parts.append(gpu.name) }
        parts.append(Fmt.memory(snapshot.memory.total))
        parts.append("up \(Fmt.uptime(snapshot.uptime))")
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - CPU

private struct CPUCard: View {
    var s: Snapshot
    var h: History
    var interval: Double

    var body: some View {
        Card(title: "CPU", symbol: "cpu") {
            HeroValue(value: Fmt.percent(s.cpu.total))
        } content: {
            AreaChart(series: [ChartSeries(label: "System", values: h.cpuSystem.values, color: Palette.orange),
                               ChartSeries(label: "User", values: h.cpuUser.values, color: Palette.blue)],
                      stacked: true, interval: interval, format: Fmt.percent)
            HStack(spacing: 14) {
                LegendItem(color: Palette.blue, label: "User", value: Fmt.percent(s.cpu.user))
                LegendItem(color: Palette.orange, label: "System", value: Fmt.percent(s.cpu.system))
                Spacer()
                Text("Idle \(Fmt.percent(1 - s.cpu.total))").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            }
            CoreBars(cores: s.cpu.cores, kinds: s.cpu.coreKinds)
            VStack(spacing: 5) {
                StatRow(label: "Load average", value: s.cpu.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
                StatRow(label: "Processes", value: "\(s.processes.count)")
                if let t = s.sensors.cpu { StatRow(label: "Temperature", value: Fmt.temperature(t)) }
                HStack {
                    Text("Thermal state").foregroundStyle(Palette.textSecondary).font(.system(size: 12))
                    Spacer()
                    StatusBadge(level: thermalLevel, text: thermalText)
                }
            }
            SectionLabel(text: "Top processes")
            ProcessList(items: s.processes.topCPU) { Fmt.percent($0.cpu) }
        }
    }

    private var thermalLevel: StatusLevel {
        switch s.thermal {
        case .nominal: .good
        case .fair: .warning
        case .serious: .serious
        case .critical: .critical
        @unknown default: .good
        }
    }

    private var thermalText: String {
        switch s.thermal {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Throttling"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

// MARK: - GPU

private struct GPUCard: View {
    var s: Snapshot
    var h: History
    var interval: Double

    var body: some View {
        Card(title: "GPU", symbol: "square.stack.3d.up.fill") {
            HeroValue(value: s.gpu.map { Fmt.percent($0.device) } ?? "—")
        } content: {
            AreaChart(series: [ChartSeries(label: "GPU", values: h.gpu.values, color: Palette.violet)],
                      interval: interval, format: Fmt.percent)
            if let g = s.gpu {
                VStack(spacing: 5) {
                    StatRow(label: "Renderer", value: Fmt.percent(g.renderer))
                    StatRow(label: "Tiler", value: Fmt.percent(g.tiler))
                    StatRow(label: "Memory in use", value: Fmt.memory(g.memoryInUse))
                    if let t = s.sensors.gpu { StatRow(label: "Temperature", value: Fmt.temperature(t)) }
                    StatRow(label: "Model", value: g.coreCount.map { "\(g.name) · \($0)-core" } ?? g.name)
                }
            } else {
                Text("No GPU statistics available").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
        }
    }
}

// MARK: - Memory

private struct MemoryCard: View {
    var s: Snapshot
    var h: History
    var interval: Double

    var body: some View {
        let m = s.memory
        Card(title: "Memory", symbol: "memorychip") {
            HeroValue(value: Fmt.memory(m.used), caption: "of \(Fmt.memory(m.total))")
        } content: {
            AreaChart(series: [ChartSeries(label: "Used", values: h.memory.values, color: Palette.aqua)],
                      interval: interval, format: Fmt.percent)
            SegmentedBar(segments: [.init(value: Double(m.app), color: Palette.blue),
                                    .init(value: Double(m.wired), color: Palette.orange),
                                    .init(value: Double(m.compressed), color: Palette.aqua),
                                    .init(value: Double(m.cached), color: Palette.yellow)],
                         total: Double(m.total))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                GridRow {
                    StatRow(label: "App", value: Fmt.memory(m.app), dot: Palette.blue)
                    StatRow(label: "Wired", value: Fmt.memory(m.wired), dot: Palette.orange)
                }
                GridRow {
                    StatRow(label: "Compressed", value: Fmt.memory(m.compressed), dot: Palette.aqua)
                    StatRow(label: "Cached", value: Fmt.memory(m.cached), dot: Palette.yellow)
                }
            }
            VStack(spacing: 6) {
                HStack {
                    Text("Pressure").foregroundStyle(Palette.textSecondary).font(.system(size: 12))
                    Spacer()
                    StatusBadge(level: pressureLevel, text: "\(pressureText) · \(Fmt.percent(m.pressure))")
                }
                MeterBar(fraction: m.pressure, color: pressureLevel.color)
                StatRow(label: "Free", value: Fmt.memory(m.free))
                StatRow(label: "Swap used", value: m.swapTotal == 0 ? "None" : "\(Fmt.memory(m.swapUsed)) of \(Fmt.memory(m.swapTotal))")
            }
            SectionLabel(text: "Top processes")
            ProcessList(items: s.processes.topMemory) { Fmt.memory($0.memory) }
        }
    }

    private var pressureLevel: StatusLevel {
        switch s.memory.pressureLevel {
        case .normal: .good
        case .warning: .warning
        case .critical: .critical
        }
    }

    private var pressureText: String {
        switch s.memory.pressureLevel {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

// MARK: - Network

private struct NetworkCard: View {
    var s: Snapshot
    var h: History
    var interval: Double

    var body: some View {
        let n = s.network
        Card(title: "Network", symbol: "network") {
            HStack(spacing: 12) {
                HeroValue(value: "↓ " + Fmt.rate(n.downRate))
            }
        } content: {
            MirrorChart(top: ChartSeries(label: "Down", values: h.netDown.values, color: Palette.blue),
                        bottom: ChartSeries(label: "Up", values: h.netUp.values, color: Palette.orange),
                        interval: interval, format: Fmt.rate)
            HStack(spacing: 14) {
                LegendItem(color: Palette.blue, label: "Download", value: Fmt.rate(n.downRate))
                LegendItem(color: Palette.orange, label: "Upload", value: Fmt.rate(n.upRate))
            }
            VStack(spacing: 5) {
                ForEach(n.interfaces) { iface in
                    StatRow(label: iface.displayName + (iface.isPrimary ? " (primary)" : ""), value: iface.ipv4)
                }
                if n.interfaces.isEmpty {
                    StatRow(label: "Status", value: "Offline")
                }
                StatRow(label: "Downloaded this session", value: Fmt.storage(n.sessionDown))
                StatRow(label: "Uploaded this session", value: Fmt.storage(n.sessionUp))
            }
        }
    }
}

// MARK: - Disk

private struct DiskCard: View {
    var s: Snapshot
    var h: History
    var interval: Double

    var body: some View {
        let d = s.disk
        Card(title: "Disk", symbol: "internaldrive") {
            HeroValue(value: d.volumes.first(where: \.isRoot).map { Fmt.percent($0.usedFraction) } ?? "—",
                      caption: "used")
        } content: {
            MirrorChart(top: ChartSeries(label: "Read", values: h.diskRead.values, color: Palette.blue),
                        bottom: ChartSeries(label: "Write", values: h.diskWrite.values, color: Palette.orange),
                        floor: 100_000, interval: interval, format: Fmt.rate)
            HStack(spacing: 14) {
                LegendItem(color: Palette.blue, label: "Read", value: Fmt.rate(d.readRate))
                LegendItem(color: Palette.orange, label: "Write", value: Fmt.rate(d.writeRate))
                Spacer()
                Text("\(Int(d.readOps + d.writeOps)) IOPS").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(d.volumes) { v in
                    VStack(alignment: .leading, spacing: 4) {
                        StatRow(label: v.name, value: "\(Fmt.storage(v.available)) free of \(Fmt.storage(v.total))")
                        MeterBar(fraction: v.usedFraction, color: v.usedFraction > 0.9 ? Palette.Status.warning : Palette.blue)
                    }
                }
            }
        }
    }
}

// MARK: - Sensors

private struct SensorsCard: View {
    var s: Snapshot
    var h: History
    var interval: Double
    @State private var showAll = false

    var body: some View {
        let t = s.sensors
        Card(title: "Sensors", symbol: "thermometer.medium") {
            HeroValue(value: Fmt.temperature(t.cpu), caption: t.cpu == nil ? nil : "CPU")
        } content: {
            if !h.cpuTemp.values.isEmpty {
                AreaChart(series: [ChartSeries(label: "CPU", values: h.cpuTemp.values, color: Palette.red)],
                          range: 20...max(100, h.cpuTemp.peak + 5), height: 56, interval: interval,
                          format: { Fmt.temperature($0) })
            }
            VStack(spacing: 5) {
                if let v = t.cpu { StatRow(label: "CPU die (average)", value: Fmt.temperature(v)) }
                if let v = t.cpuMax { StatRow(label: "CPU die (hottest)", value: Fmt.temperature(v)) }
                if let v = t.gpu { StatRow(label: "GPU", value: Fmt.temperature(v)) }
                if let v = t.ssd { StatRow(label: "SSD", value: Fmt.temperature(v)) }
                if let v = t.battery ?? s.power.batteryTemperature { StatRow(label: "Battery", value: Fmt.temperature(v)) }
            }
            if !t.fans.isEmpty {
                SectionLabel(text: "Fans")
                VStack(spacing: 7) {
                    ForEach(t.fans) { fan in
                        VStack(spacing: 4) {
                            StatRow(label: t.fans.count == 1 ? "Fan" : "Fan \(fan.id + 1)",
                                    value: fan.rpm < 1 ? "Off" : "\(Int(fan.rpm.rounded())) rpm")
                            MeterBar(fraction: fan.maxRPM > 0 ? fan.rpm / fan.maxRPM : 0, color: Palette.red, height: 4)
                        }
                    }
                }
            }
            if !t.all.isEmpty {
                DisclosureGroup(isExpanded: $showAll) {
                    VStack(spacing: 4) {
                        ForEach(t.all, id: \.name) { sensor in
                            StatRow(label: sensor.name, value: String(format: "%.1f°C", sensor.value))
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("All sensors (\(t.all.count))").font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
                }
                .tint(Palette.muted)
            }
            if t.cpu == nil && t.fans.isEmpty && t.all.isEmpty {
                Text("No sensors readable on this Mac").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
        }
    }
}

// MARK: - Power

private struct PowerCard: View {
    var s: Snapshot
    var h: History
    var interval: Double

    var body: some View {
        let p = s.power
        Card(title: p.hasBattery ? "Battery & Power" : "Power", symbol: batterySymbol) {
            HeroValue(value: p.systemPower != nil ? Fmt.watts(p.systemPower) : Fmt.percent(p.level),
                      caption: p.systemPower != nil ? "system" : stateText)
        } content: {
            if !h.power.values.isEmpty {
                AreaChart(series: [ChartSeries(label: "System", values: h.power.values, color: Palette.yellow)],
                          range: 0...max(20, h.power.peak * 1.15), height: 56, interval: interval,
                          format: { Fmt.watts($0) })
            }
            VStack(spacing: 5) {
                if let w = p.systemPower { StatRow(label: "System power", value: Fmt.watts(w), dot: Palette.yellow) }
                if let w = p.adapterWatts, p.isPluggedIn { StatRow(label: "Power adapter", value: "\(w) W") }
            }
            if p.hasBattery {
                SectionLabel(text: "Battery")
                VStack(spacing: 5) {
                    HStack {
                        Text("Charge").foregroundStyle(Palette.textSecondary).font(.system(size: 12))
                        Spacer()
                        StatusBadge(level: batteryLevel, text: "\(Fmt.percent(p.level)) · \(stateText)")
                    }
                    MeterBar(fraction: p.level, color: batteryLevel.color)
                        .padding(.bottom, 2)
                    if let m = p.minutesRemaining {
                        StatRow(label: p.isCharging ? "Time to full" : "Time remaining", value: Fmt.minutes(m))
                    }
                    if let w = p.batteryPower, abs(w) >= 0.1 {
                        StatRow(label: w > 0 ? "Charging at" : "Battery drain", value: Fmt.watts(abs(w)))
                    }
                    if let hlth = p.health { StatRow(label: "Health (max capacity)", value: Fmt.percent(hlth)) }
                    if let c = p.cycleCount { StatRow(label: "Cycle count", value: "\(c)") }
                }
            }
        }
    }

    private var stateText: String {
        let p = s.power
        if p.isCharging { return "charging" }
        if p.isPluggedIn { return p.isFullyCharged ? "charged" : "on AC" }
        return "on battery"
    }

    private var batteryLevel: StatusLevel {
        let p = s.power
        if p.isPluggedIn || p.level > 0.2 { return .good }
        return p.level > 0.1 ? .warning : .critical
    }

    private var batterySymbol: String {
        let p = s.power
        guard p.hasBattery else { return "bolt.fill" }
        if p.isCharging || p.isPluggedIn { return "battery.100percent.bolt" }
        switch p.level {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
