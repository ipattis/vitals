import AppKit
import SwiftUI

/// The Agents tab: a fleet summary, the list of agents, and a detail pane for the selected one
/// with resources, session metrics, an activity log, tool stats, its process tree and subagents.
struct AgentsView: View {
    var s: Snapshot
    var h: History
    var interval: Double
    @Binding var selection: String?

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 800
            let explicit = s.agents.first { $0.id == selection }
            let selected = explicit ?? (wide ? s.agents.first : nil)
            if wide {
                VStack(spacing: 12) {
                    FleetCard(s: s, h: h, interval: interval, wide: true)
                    if s.agents.isEmpty {
                        EmptyAgents()
                        Spacer(minLength: 0)
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            ScrollView {
                                AgentList(agents: s.agents, h: h, selected: selected?.id) { selection = $0 }
                            }
                            .scrollIndicators(.never)
                            .frame(width: min(320, geo.size.width * 0.3))
                            ScrollView {
                                if let selected { detail(selected) }
                            }
                            .scrollIndicators(.never)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        if let explicit {
                            Button { selection = nil } label: {
                                Label("All agents", systemImage: "chevron.left").font(.system(size: 12))
                            }
                            .buttonStyle(.borderless)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            detail(explicit)
                        } else {
                            FleetCard(s: s, h: h, interval: interval, wide: false)
                            if s.agents.isEmpty { EmptyAgents() }
                            AgentList(agents: s.agents, h: h, selected: nil) { selection = $0 }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func detail(_ agent: AgentReading) -> some View {
        AgentDetail(agent: agent,
                    cpu: h.agentCPU[agent.id]?.values ?? [],
                    memory: h.agentMemory[agent.id]?.values ?? [],
                    gpu: h.agentGPU[agent.id]?.values ?? [],
                    interval: interval)
            .id(agent.id)
    }
}

/// Lets `--snapshot` open a specific detail section for visual checks.
enum SnapshotOptions {
    nonisolated(unsafe) static var section: String?
}

// MARK: - Shared bits

/// Stable colour per agent: assigned by start order, so it doesn't change as agents re-sort.
enum AgentColors {
    static let palette = [Palette.blue, Palette.orange, Palette.aqua, Palette.yellow, Palette.violet, Palette.red]
    static func color(for agent: AgentReading, in all: [AgentReading]) -> Color {
        let ordered = all.sorted { ($0.started ?? .distantPast, $0.id) < ($1.started ?? .distantPast, $1.id) }
        let i = ordered.firstIndex { $0.id == agent.id } ?? 0
        return palette[i % palette.count]
    }
}

private struct StatusDot: View {
    var working: Bool
    var size: CGFloat = 8
    var body: some View {
        Group {
            if working { Circle().fill(Palette.blue) } else { Circle().stroke(Palette.muted, lineWidth: 1.5) }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Small labelled number used in tile grids.
private struct Tile: View {
    var label: String
    var value: String
    var caption: String? = nil
    var color: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(color ?? Palette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
            // Always reserve the caption line so tiles in a row share one height.
            Text(caption ?? " ").font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.border))
        .accessibilityElement(children: .combine)
    }
}

private struct TileGrid<Content: View>: View {
    var minWidth: CGFloat = 112
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 8)], spacing: 8) { content }
    }
}

/// Row of selectable capsules.
private struct ChipPicker<T: Hashable>: View {
    var options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                Button { selection = value } label: {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .foregroundStyle(selection == value ? Palette.textPrimary : Palette.muted)
                        .background(Capsule().fill(selection == value ? Color.white.opacity(0.12) : Color.white.opacity(0.03)))
                        .overlay(Capsule().stroke(Palette.border))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
    }
}

/// Wrapping horizontal layout for metadata chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !row.items.isEmpty && row.width + spacing + size.width > width {
                let y = row.y + row.height + spacing
                rows.append(row)
                row = Row(y: y)
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

private struct MetaChip: View {
    var symbol: String
    var text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9.5)).foregroundStyle(Palette.muted)
            Text(text).font(.system(size: 11)).foregroundStyle(Palette.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .overlay(Capsule().stroke(Palette.border))
    }
}

private extension String {
    /// "global.anthropic.claude-opus-5-5" → "claude-opus-5-5".
    var shortModel: String {
        if let r = range(of: "claude-") { return String(self[r.lowerBound...]) }
        return self
    }
}

private struct EmptyAgents: View {
    var body: some View {
        Card(title: "No agents running", symbol: "sparkles") { EmptyView() } content: {
            Text("Vitals detects Claude Code sessions (app and terminal), Codex, Gemini CLI, Cursor Agent, Aider, OpenCode, Goose, Amp, and local model runtimes (LM Studio, Ollama). Claude Code sessions also get a full activity log, token and tool metrics, and subagent tracking from their transcripts.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Fleet summary

private struct FleetCard: View {
    var s: Snapshot
    var h: History
    var interval: Double
    var wide: Bool

    var body: some View {
        let agents = s.agents
        let working = agents.filter(\.isWorking).count
        let cpu = agents.reduce(0) { $0 + $1.cpu }
        let memory = agents.reduce(UInt64(0)) { $0 + $1.memory }
        let hour = fleetBuckets()
        let calls = hour.reduce(0) { $0 + $1.toolCalls }
        let errors = hour.reduce(0) { $0 + $1.errors }
        let output = agents.reduce(0) { $0 + ($1.activity?.tokensIncludingSubagents.output ?? 0) }
        let subagents = agents.reduce(0) { $0 + $1.subagents.count }
        let cores = max(1, s.cpu.cores.count)

        Card(title: "Agent fleet", symbol: "sparkles") {
            HeroValue(value: "\(working)", caption: "working · \(agents.count) total")
        } content: {
            TileGrid(minWidth: 108) {
                Tile(label: "Agent CPU", value: Fmt.percent(cpu), caption: "\(Fmt.percent(cpu / Double(cores))) of machine")
                Tile(label: "Agent memory", value: Fmt.memory(memory),
                     caption: s.memory.total > 0 ? "\(Fmt.percent(Double(memory) / Double(s.memory.total))) of RAM" : nil)
                Tile(label: "Processes", value: "\(agents.reduce(0) { $0 + $1.processCount })")
                Tile(label: "Subagents", value: "\(subagents)", caption: "running")
                Tile(label: "Tool calls", value: "\(calls)", caption: "last hour")
                Tile(label: "Errors", value: "\(errors)", caption: "last hour",
                     color: errors > 0 ? Palette.Status.critical : nil)
                Tile(label: "Output tokens", value: Fmt.tokens(output), caption: "live sessions")
            }
            let charts = Group {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "CPU by agent · 2 min")
                    AreaChart(series: cpuSeries(), range: 0...max(1, h.agentsTotalCPU.peak * 1.1), stacked: true,
                              height: 70, interval: interval, format: Fmt.percent)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Tool calls per minute · 1 h")
                    BarChart(series: [ChartSeries(label: "Calls", values: hour.map { Double($0.toolCalls - min($0.toolCalls, $0.errors)) }, color: Palette.blue),
                                      ChartSeries(label: "Errors", values: hour.map { Double($0.errors) }, color: Palette.Status.critical)],
                             height: 70, format: { "\(Int($0))" },
                             footer: { "\(60 - $0)m ago" })
                }
            }
            if wide {
                HStack(alignment: .top, spacing: 16) { charts }
            } else {
                VStack(alignment: .leading, spacing: 12) { charts }
            }
        }
    }

    private func fleetBuckets() -> [ActivityBucket] {
        var total = [ActivityBucket](repeating: ActivityBucket(), count: 60)
        let now = Date()
        for a in s.agents {
            guard let activity = a.activity else { continue }
            for (i, b) in activity.buckets(span: 60, count: 60, now: now).enumerated() {
                total[i].toolCalls += b.toolCalls
                total[i].errors += b.errors
                total[i].prompts += b.prompts
                total[i].outputTokens += b.outputTokens
            }
        }
        return total
    }

    /// Top five agents by recent CPU, the rest folded into "Other".
    private func cpuSeries() -> [ChartSeries] {
        func recent(_ a: AgentReading) -> Double {
            let values: [Double] = h.agentCPU[a.id]?.values ?? []
            return values.suffix(20).reduce(0, +)
        }
        let ranked = s.agents.sorted { recent($0) > recent($1) }
        var series: [ChartSeries] = ranked.prefix(5).map { a in
            ChartSeries(label: String(a.title.prefix(16)), values: h.agentCPU[a.id]?.values ?? [],
                        color: AgentColors.color(for: a, in: s.agents))
        }
        let rest = ranked.dropFirst(5)
        if !rest.isEmpty {
            var other = [Double](repeating: 0, count: Series.capacity)
            for a in rest {
                let v = h.agentCPU[a.id]?.values ?? []
                for (back, x) in v.reversed().enumerated() { other[Series.capacity - 1 - back] += x }
            }
            let length = rest.map { h.agentCPU[$0.id]?.values.count ?? 0 }.max() ?? 0
            series.append(ChartSeries(label: "Other", values: Array(other.suffix(length)), color: Palette.muted))
        }
        return series
    }
}

// MARK: - Agent list

private struct AgentList: View {
    var agents: [AgentReading]
    var h: History
    var selected: String?
    var select: (String) -> Void

    var body: some View {
        let working = agents.filter(\.isWorking)
        let idle = agents.filter { !$0.isWorking }
        VStack(alignment: .leading, spacing: 6) {
            if !working.isEmpty {
                SectionLabel(text: "Working · \(working.count)").padding(.leading, 4)
                ForEach(working) { row($0) }
            }
            if !idle.isEmpty {
                SectionLabel(text: "Idle · \(idle.count)").padding(.leading, 4).padding(.top, working.isEmpty ? 0 : 6)
                ForEach(idle) { row($0) }
            }
        }
    }

    private func row(_ a: AgentReading) -> some View {
        Button { select(a.id) } label: {
            AgentRow(agent: a, cpu: h.agentCPU[a.id]?.values ?? [], color: AgentColors.color(for: a, in: agents),
                     selected: a.id == selected)
        }
        .buttonStyle(.plain)
    }
}

private struct AgentRow: View {
    var agent: AgentReading
    var cpu: [Double]
    var color: Color
    var selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StatusDot(working: agent.isWorking, size: 7)
                    Text(agent.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(agent.isWorking ? Palette.textPrimary : Palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Fmt.percent(agent.cpu))
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Palette.textPrimary)
                }
                HStack(spacing: 6) {
                    Text(subtitle).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(Fmt.memory(agent.memory)).monospacedDigit().fixedSize()
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.muted)
                if let now = nowLine {
                    Text(now)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Sparkline(values: cpu, color: color, range: 0...max(1, (cpu.max() ?? 0) * 1.1))
                    .frame(height: 18)
            }
        }
        .padding(.vertical, 8)
        .padding(.trailing, 10)
        .padding(.leading, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Color.white.opacity(0.09) : Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(selected ? Color.white.opacity(0.25) : Palette.border))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var subtitle: String {
        var parts = [agent.statusText]
        if let since = agent.statusSince ?? agent.started { parts[0] += " \(Fmt.ago(since))" }
        parts.append(agent.source)
        if let p = agent.project, p != agent.title { parts.append(p) }
        return parts.joined(separator: " · ")
    }

    private var nowLine: String? {
        guard agent.isWorking, let a = agent.activity else { return agent.busiest.map { "▸ \($0.command)" } }
        if let e = a.inFlight { return "▸ \(e.title): \(e.text)" }
        if !a.runningSubagents.isEmpty { return "▸ \(a.runningSubagents.count) subagent(s) running" }
        return a.events.last.map { "▸ \($0.title): \($0.text)" }
    }
}

// MARK: - Detail

private enum DetailSection: String, CaseIterable, Hashable {
    case overview, log, tools, processes, subagents
}

private struct AgentDetail: View {
    var agent: AgentReading
    var cpu: [Double]
    var memory: [Double]
    var gpu: [Double]
    var interval: Double
    @State private var section = DetailSection(rawValue: SnapshotOptions.section ?? "") ?? .overview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailHeader(agent: agent)
            ChipPicker(options: sections, selection: $section)
            switch section {
            case .overview: OverviewSection(agent: agent, cpu: cpu, memory: memory, gpu: gpu, interval: interval) { section = $0 }
            case .log: if let a = agent.activity { LogSection(activity: a) }
            case .tools: if let a = agent.activity { ToolsSection(activity: a) }
            case .processes: ProcessesSection(agent: agent)
            case .subagents: if let a = agent.activity { SubagentsSection(activity: a) }
            }
        }
    }

    private var sections: [(DetailSection, String)] {
        var result: [(DetailSection, String)] = [(.overview, "Overview")]
        if let a = agent.activity {
            result.append((.log, "Log · \(a.events.count)"))
            result.append((.tools, "Tools · \(a.tools.count)"))
        }
        result.append((.processes, "Processes · \(agent.processCount)"))
        if let a = agent.activity, !a.subagents.isEmpty {
            result.append((.subagents, "Subagents · \(a.subagents.count)"))
        }
        return result
    }
}

private struct DetailHeader: View {
    var agent: AgentReading

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                StatusDot(working: agent.isWorking, size: 10)
                Text(agent.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).frame(height: 20)
                    .foregroundStyle(agent.isWorking ? Color.white : Palette.textSecondary)
                    .background(Capsule().fill(agent.isWorking ? Palette.blue : Color.white.opacity(0.07)))
                    .fixedSize()
                Spacer(minLength: 8)
                actions
            }
            FlowLayout(spacing: 6) {
                MetaChip(symbol: "app.connected.to.app.below.fill", text: agent.source)
                if let p = agent.project { MetaChip(symbol: "folder", text: p) }
                if let b = agent.activity?.gitBranch { MetaChip(symbol: "arrow.triangle.branch", text: b) }
                if let m = agent.activity?.model { MetaChip(symbol: "cpu", text: m.shortModel) }
                if let started = agent.started { MetaChip(symbol: "clock", text: "up \(Fmt.ago(started))") }
                MetaChip(symbol: "number", text: "pid \(agent.pid)")
                if let v = agent.version { MetaChip(symbol: "shippingbox", text: "v\(v)") }
            }
            if let now = nowText {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Now").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.muted)
                    Text(now).font(.system(size: 12)).foregroundStyle(Palette.textPrimary).lineLimit(2)
                }
            }
            if let prompt = agent.activity?.lastPrompt ?? agent.activity?.events.last(where: { $0.kind == .prompt })?.text {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Last prompt").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.muted)
                    Text(prompt).font(.system(size: 12)).foregroundStyle(Palette.textSecondary).lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.border))
    }

    private var status: String {
        guard let since = agent.statusSince else { return agent.statusText }
        return "\(agent.statusText) · \(Fmt.ago(since))"
    }

    private var nowText: String? {
        guard agent.isWorking else { return nil }
        if let e = agent.activity?.inFlight {
            return "\(e.title): \(e.text)  ·  \(Fmt.duration(Date().timeIntervalSince(e.time)))"
        }
        if let running = agent.activity?.runningSubagents, !running.isEmpty {
            return running.map { "\($0.type): \($0.description)" }.joined(separator: ", ")
        }
        return agent.busiest.map { "\($0.command) · \(Fmt.percent($0.cpu)) CPU" }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 2) {
            if let url = agent.activity?.transcript {
                iconButton("doc.text.magnifyingglass", "Reveal transcript in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            if let cwd = agent.cwd {
                iconButton("folder", "Open working folder") { NSWorkspace.shared.open(URL(fileURLWithPath: cwd)) }
            }
            if let session = agent.sessionId {
                iconButton("doc.on.doc", "Copy session ID (\(session))") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session, forType: .string)
                }
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Palette.textSecondary).frame(width: 26, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: Overview

private struct OverviewSection: View {
    var agent: AgentReading
    var cpu: [Double]
    var memory: [Double]
    var gpu: [Double]
    var interval: Double
    var open: (DetailSection) -> Void
    @State private var span = 60

    var body: some View {
        VStack(spacing: 12) {
            resources
            if let a = agent.activity {
                session(a)
                activityCard(a)
                if !a.tools.isEmpty { topTools(a) }
            } else {
                Card(title: "Session", symbol: "text.alignleft") { EmptyView() } content: {
                    Text("\(agent.source) doesn't publish a session log Vitals can read, so only resource use is shown. Activity logs, token and tool metrics are available for Claude Code sessions.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var resources: some View {
        Card(title: "Resources", symbol: "gauge.with.dots.needle.33percent") {
            HeroValue(value: Fmt.percent(agent.cpu), caption: "CPU")
        } content: {
            TileGrid {
                Tile(label: "CPU", value: Fmt.percent(agent.cpu), caption: "peak \(Fmt.percent(cpu.max() ?? 0))")
                Tile(label: "Memory", value: Fmt.memory(agent.memory), caption: "peak \(Fmt.memory(UInt64(memory.max() ?? 0)))")
                Tile(label: "GPU", value: Fmt.percent(agent.gpu), caption: "peak \(Fmt.percent(gpu.max() ?? 0))")
                Tile(label: "Processes", value: "\(agent.processCount)")
            }
            SectionLabel(text: "CPU · whole process tree")
            AreaChart(series: [ChartSeries(label: "CPU", values: cpu, color: Palette.blue)],
                      range: 0...max(1, (cpu.max() ?? 0) * 1.1), height: 64, interval: interval, format: Fmt.percent)
            SectionLabel(text: "Memory")
            AreaChart(series: [ChartSeries(label: "Memory", values: memory, color: Palette.aqua)],
                      range: 0...max(1, (memory.max() ?? 0) * 1.25), height: 48, interval: interval,
                      format: { Fmt.memory(UInt64(max(0, $0))) })
            if (gpu.max() ?? 0) > 0.005 {
                SectionLabel(text: "GPU")
                AreaChart(series: [ChartSeries(label: "GPU", values: gpu, color: Palette.violet)],
                          range: 0...max(0.1, (gpu.max() ?? 0) * 1.1), height: 40, interval: interval, format: Fmt.percent)
            }
            if let b = agent.busiest {
                StatRow(label: "Busiest: \(b.command)", value: Fmt.percent(b.cpu)).help(b.command)
            }
        }
    }

    private func session(_ a: AgentActivity) -> some View {
        let all = a.tokensIncludingSubagents
        return Card(title: "Session", symbol: "text.alignleft") {
            if let cost = a.costUSD { HeroValue(value: Fmt.usd(cost), caption: "reported cost") }
        } content: {
            TileGrid {
                Tile(label: "Prompts", value: "\(a.prompts)")
                Tile(label: "Responses", value: "\(a.replies)")
                Tile(label: "Tool calls", value: "\(a.toolCalls)")
                Tile(label: "Errors", value: "\(a.errorCount)",
                     caption: a.apiErrors > 0 ? "\(a.toolErrors) tool · \(a.apiErrors) API" : "tool results",
                     color: a.errorCount > 0 ? Palette.Status.critical : nil)
                Tile(label: "Context", value: Fmt.tokens(a.contextTokens), caption: "peak \(Fmt.tokens(a.peakContext))")
                Tile(label: "Output tokens", value: Fmt.tokens(a.tokens.output),
                     caption: all.output != a.tokens.output ? "\(Fmt.tokens(all.output)) incl. subagents" : nil)
                Tile(label: "Avg turn", value: a.averageTurn.map(Fmt.duration) ?? "—",
                     caption: a.turnDurations.last.map { "last \(Fmt.duration($0))" })
                Tile(label: "Compactions", value: "\(a.compactions)")
                if let added = a.linesAdded, let removed = a.linesRemoved {
                    Tile(label: "Lines changed", value: "+\(added) −\(removed)")
                }
                if !a.subagents.isEmpty {
                    Tile(label: "Subagents", value: "\(a.subagents.count)", caption: "\(a.runningSubagents.count) running")
                }
            }
            SectionLabel(text: "Tokens · \(Fmt.tokens(a.tokens.total)) total")
            SegmentedBar(segments: [.init(value: Double(a.tokens.input), color: Palette.blue),
                                    .init(value: Double(a.tokens.cacheRead), color: Palette.aqua),
                                    .init(value: Double(a.tokens.cacheWrite), color: Palette.yellow),
                                    .init(value: Double(a.tokens.output), color: Palette.violet)],
                         total: Double(max(1, a.tokens.total)))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                GridRow {
                    StatRow(label: "Input", value: Fmt.tokens(a.tokens.input), dot: Palette.blue)
                    StatRow(label: "Cache read", value: Fmt.tokens(a.tokens.cacheRead), dot: Palette.aqua)
                }
                GridRow {
                    StatRow(label: "Cache write", value: Fmt.tokens(a.tokens.cacheWrite), dot: Palette.yellow)
                    StatRow(label: "Output", value: Fmt.tokens(a.tokens.output), dot: Palette.violet)
                }
            }
            VStack(spacing: 5) {
                if a.models.count > 1 {
                    StatRow(label: "Models", value: a.models.map(\.shortModel).sorted().joined(separator: ", "))
                }
                if let first = a.firstEvent { StatRow(label: "First activity", value: "\(Fmt.ago(first)) ago") }
                if let last = a.lastEvent { StatRow(label: "Last activity", value: Fmt.ago(last) == "now" ? "now" : "\(Fmt.ago(last)) ago") }
                StatRow(label: "Transcript", value: Fmt.storage(UInt64(a.transcriptBytes)))
            }
        }
    }

    private func activityCard(_ a: AgentActivity) -> some View {
        let count = 60
        let buckets = a.buckets(span: span, count: count)
        let size = span / count
        let footer: (Int) -> String = { i in
            let back = (count - i) * size
            return size == 1 ? "\(back)m ago" : "\(back - size)–\(back)m ago"
        }
        return Card(title: "Activity", symbol: "chart.bar.xaxis") {
            ChipPicker(options: [(60, "1h"), (360, "6h"), (1440, "24h")], selection: $span)
        } content: {
            SectionLabel(text: "Tool calls · \(buckets.reduce(0) { $0 + $1.toolCalls }) · per \(size == 1 ? "minute" : "\(size) min")")
            BarChart(series: [ChartSeries(label: "OK", values: buckets.map { Double($0.toolCalls - min($0.toolCalls, $0.errors)) }, color: Palette.blue),
                              ChartSeries(label: "Errors", values: buckets.map { Double($0.errors) }, color: Palette.Status.critical)],
                     height: 64, format: { "\(Int($0))" }, footer: footer)
            SectionLabel(text: "Output tokens · \(Fmt.tokens(buckets.reduce(0) { $0 + $1.outputTokens }))")
            BarChart(series: [ChartSeries(label: "Output", values: buckets.map { Double(max(0, $0.outputTokens)) }, color: Palette.violet)],
                     height: 48, format: { Fmt.tokens(Int($0)) }, footer: footer)
            SectionLabel(text: "Prompts · \(buckets.reduce(0) { $0 + $1.prompts })")
            BarChart(series: [ChartSeries(label: "Prompts", values: buckets.map { Double($0.prompts) }, color: Palette.aqua)],
                     height: 24, format: { "\(Int($0))" }, footer: footer)
            HStack {
                Text(span >= 60 && span % 60 == 0 ? "−\(span / 60)h" : "−\(span)m")
                Spacer()
                Text("now")
            }
            .font(.system(size: 9.5)).foregroundStyle(Palette.muted)
        }
    }

    private func topTools(_ a: AgentActivity) -> some View {
        let tools = a.tools.values.sorted { $0.calls > $1.calls }
        let peak = max(1, tools.first?.calls ?? 1)
        return Card(title: "Top tools", symbol: "wrench.and.screwdriver") {
            Button("All \(tools.count) →") { open(.tools) }.buttonStyle(.borderless).font(.system(size: 11))
        } content: {
            VStack(spacing: 7) {
                ForEach(tools.prefix(6)) { t in
                    VStack(spacing: 3) {
                        StatRow(label: t.name, value: "\(t.calls)" + (t.errors > 0 ? " · \(t.errors) err" : ""))
                        MeterBar(fraction: Double(t.calls) / Double(peak), color: Palette.blue, height: 4)
                    }
                }
            }
        }
    }
}

// MARK: Log

private enum LogFilter: Hashable { case all, prompts, replies, tools, errors }

private struct LogSection: View {
    var activity: AgentActivity
    @State private var filter = LogFilter.all
    @State private var query = ""
    @State private var expanded = Set<Int>()
    private let limit = 400

    var body: some View {
        let events = filtered()
        Card(title: "Activity log", symbol: "list.bullet.rectangle") {
            Text("\(events.count) of \(activity.events.count)").font(.system(size: 11)).foregroundStyle(Palette.muted)
        } content: {
            HStack(spacing: 8) {
                ChipPicker(options: [(.all, "All"), (.prompts, "Prompts"), (.replies, "Replies"),
                                     (.tools, "Tools"), (.errors, "Errors")], selection: $filter)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                    TextField("Filter", text: $query).textFieldStyle(.plain).font(.system(size: 11.5))
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: 170, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.border))
            }
            if events.isEmpty {
                Text("Nothing matches.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(events.prefix(limit)) { e in
                    LogRow(event: e, expanded: expanded.contains(e.id)) {
                        if expanded.contains(e.id) { expanded.remove(e.id) } else { expanded.insert(e.id) }
                    }
                    Divider().overlay(Palette.grid)
                }
            }
            if events.count > limit {
                Text("Showing the newest \(limit). Narrow the filter to see older entries, or reveal the transcript.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }

    private func filtered() -> [AgentEvent] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return activity.events.reversed().filter { e in
            switch filter {
            case .all: break
            case .prompts: guard e.kind == .prompt || e.kind == .command else { return false }
            case .replies: guard e.kind == .reply else { return false }
            case .tools: guard e.kind == .tool || e.kind == .subagent else { return false }
            case .errors: guard e.isError else { return false }
            }
            guard !q.isEmpty else { return true }
            return e.title.lowercased().contains(q) || e.text.lowercased().contains(q)
                || (e.detail?.lowercased().contains(q) ?? false) || (e.result?.lowercased().contains(q) ?? false)
        }
    }
}

private struct LogRow: View {
    var event: AgentEvent
    var expanded: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.clock(event.time)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.muted)
                    Image(systemName: symbol).font(.system(size: 10.5)).foregroundStyle(color).frame(width: 14)
                    Text(event.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(event.isError ? Palette.Status.critical : Palette.textPrimary)
                        .lineLimit(1)
                        .frame(minWidth: 64, alignment: .leading)
                        .fixedSize()
                    Text(event.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(expanded ? nil : 1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailing
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                if let d = event.detail, d != event.text { block(d, label: nil) }
                if let r = event.result, !r.isEmpty { block(r, label: event.isError ? "Error" : "Result") }
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if event.pending {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(Fmt.duration(Date().timeIntervalSince(event.time)))
            }
            .font(.system(size: 10.5)).foregroundStyle(Palette.blue).monospacedDigit().fixedSize()
        } else if let d = event.duration {
            Text(Fmt.duration(d))
                .font(.system(size: 10.5)).monospacedDigit().fixedSize()
                .foregroundStyle(d > 60 ? Palette.Status.warning : Palette.muted)
        }
    }

    private func block(_ text: String, label: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label { Text(label.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Palette.muted) }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
                .lineLimit(40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
        }
        .padding(.leading, 22)
        .padding(.bottom, 6)
    }

    private var symbol: String {
        switch event.kind {
        case .prompt: "person.fill"
        case .command: "terminal"
        case .reply: "text.bubble"
        case .tool: event.isError ? "xmark.octagon.fill" : "wrench.and.screwdriver"
        case .subagent: "arrow.triangle.branch"
        case .compaction: "arrow.down.right.and.arrow.up.left"
        case .apiError: "exclamationmark.icloud"
        case .hook: "link"
        case .turn: "flag.checkered"
        }
    }

    private var color: Color {
        if event.isError { return Palette.Status.critical }
        switch event.kind {
        case .prompt, .command: return Palette.aqua
        case .reply: return Palette.violet
        case .tool: return Palette.blue
        case .subagent: return Palette.orange
        case .compaction: return Palette.yellow
        case .apiError, .hook: return Palette.Status.critical
        case .turn: return Palette.muted
        }
    }
}

// MARK: Tools

private struct ToolsSection: View {
    var activity: AgentActivity

    var body: some View {
        let tools = activity.tools.values.sorted { $0.calls != $1.calls ? $0.calls > $1.calls : $0.name < $1.name }
        let peak = max(1, tools.first?.calls ?? 1)
        Card(title: "Tools", symbol: "wrench.and.screwdriver") {
            Text("\(activity.toolCalls) calls · \(activity.toolErrors) errors").font(.system(size: 11)).foregroundStyle(Palette.muted)
        } content: {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    header("Tool")
                    header("Calls").gridColumnAlignment(.trailing)
                    header("Errors").gridColumnAlignment(.trailing)
                    header("Avg").gridColumnAlignment(.trailing)
                    header("Max").gridColumnAlignment(.trailing)
                }
                ForEach(tools) { t in
                    GridRow {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.name).font(.system(size: 12)).foregroundStyle(Palette.textPrimary).lineLimit(1).truncationMode(.middle)
                            MeterBar(fraction: Double(t.calls) / Double(peak), color: Palette.blue, height: 3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        cell("\(t.calls)")
                        cell(t.errors > 0 ? "\(t.errors) · \(Fmt.percent(Double(t.errors) / Double(max(1, t.calls))))" : "—",
                             color: t.errors > 0 ? Palette.Status.critical : Palette.muted)
                        cell(t.averageDuration.map(Fmt.duration) ?? "—")
                        cell(t.timedCalls > 0 ? Fmt.duration(t.maxDuration) : "—",
                             color: t.maxDuration > 60 ? Palette.Status.warning : Palette.textSecondary)
                    }
                }
            }
            Text("Duration is the time from the tool call to its result, including any permission prompt.")
                .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
        }
    }

    private func header(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundStyle(Palette.muted)
    }

    private func cell(_ s: String, color: Color = Palette.textSecondary) -> some View {
        Text(s).font(.system(size: 12)).monospacedDigit().foregroundStyle(color).lineLimit(1).fixedSize()
    }
}

// MARK: Processes

private struct ProcessesSection: View {
    var agent: AgentReading

    var body: some View {
        Card(title: "Process tree", symbol: "point.3.connected.trianglepath.dotted") {
            Text("\(agent.processCount) processes · \(Fmt.percent(agent.cpu)) · \(Fmt.memory(agent.memory))")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        } content: {
            if agent.processes.isEmpty {
                Text("Measuring…").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            VStack(spacing: 6) {
                ForEach(agent.processes) { p in
                    HStack(spacing: 8) {
                        Image(systemName: p.isRoot ? "sparkles" : "terminal")
                            .font(.system(size: 10)).foregroundStyle(p.isRoot ? Palette.blue : Palette.muted).frame(width: 14)
                        Text(p.command).font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                            .lineLimit(1).truncationMode(.middle).help(p.command)
                        if p.isRoot {
                            Text("agent").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Palette.blue)
                        }
                        Spacer(minLength: 8)
                        Text("\(p.pid)").font(.system(size: 10.5)).foregroundStyle(Palette.muted).monospacedDigit()
                        Text(Fmt.percent(p.cpu)).font(.system(size: 12)).foregroundStyle(Palette.textPrimary).monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                        Text(Fmt.memory(p.memory)).font(.system(size: 12)).foregroundStyle(Palette.textPrimary).monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }
            if agent.processCount > agent.processes.count {
                Text("Busiest \(agent.processes.count) of \(agent.processCount). Totals include processes the agent started that have since detached, and the CPU time of children that already exited.")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Subagents

private struct SubagentsSection: View {
    var activity: AgentActivity

    var body: some View {
        Card(title: "Subagents", symbol: "arrow.triangle.branch") {
            Text("\(activity.runningSubagents.count) running · \(activity.subagents.count) total")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        } content: {
            VStack(spacing: 0) {
                ForEach(activity.subagents) { sub in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            StatusDot(working: sub.running, size: 7)
                            Text(sub.type).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textPrimary)
                            Text(sub.description).font(.system(size: 12)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(sub.running ? "running" : "done \(Fmt.ago(sub.lastActivity))")
                                .font(.system(size: 10.5)).foregroundStyle(sub.running ? Palette.blue : Palette.muted).fixedSize()
                        }
                        Text(stats(sub)).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
                            .padding(.leading, 14)
                        if let last = sub.lastAction {
                            Text(last).font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                                .padding(.leading, 14)
                        }
                    }
                    .padding(.vertical, 7)
                    Divider().overlay(Palette.grid)
                }
            }
        }
    }

    private func stats(_ s: SubagentActivity) -> String {
        var parts: [String] = []
        if let m = s.model { parts.append(m.shortModel) }
        parts.append("\(Fmt.tokens(s.tokens.output)) out")
        parts.append("\(s.toolCalls) tool calls")
        if s.errors > 0 { parts.append("\(s.errors) errors") }
        if let start = s.started, let end = s.lastActivity { parts.append(Fmt.duration(end.timeIntervalSince(start))) }
        return parts.joined(separator: " · ")
    }
}
