import SwiftUI

/// Active AI agents, each with the CPU / memory / GPU used by everything it has spawned.
struct AgentsCard: View {
    var s: Snapshot
    var h: History
    var interval: Double

    var body: some View {
        let working = s.agents.filter(\.isWorking)
        let idle = s.agents.filter { !$0.isWorking }
        Card(title: "Agents", symbol: "sparkles") {
            HeroValue(value: "\(working.count)", caption: s.agents.isEmpty ? "working" : "working · \(s.agents.count) total")
        } content: {
            if s.agents.isEmpty {
                Text("No agents running. Vitals detects Claude Code sessions (app and terminal), Codex, Gemini CLI, Cursor Agent, Aider, OpenCode, Goose, and local model runtimes (LM Studio, Ollama).")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(working) { agent in
                AgentTile(agent: agent, history: h.agentCPU[agent.id]?.values ?? [], interval: interval)
            }
            if !idle.isEmpty {
                if !working.isEmpty { SectionLabel(text: "Idle") }
                VStack(spacing: 6) {
                    ForEach(idle) { IdleAgentRow(agent: $0) }
                }
            }
        }
    }
}

private struct StatusDot: View {
    var working: Bool
    var body: some View {
        Group {
            if working {
                Circle().fill(Palette.blue)
            } else {
                Circle().stroke(Palette.muted, lineWidth: 1.5)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

private struct AgentTile: View {
    var agent: AgentReading
    var history: [Double]
    var interval: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                StatusDot(working: true)
                Text(agent.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(agent.source)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)

            AreaChart(series: [ChartSeries(label: "CPU", values: history, color: Palette.blue)],
                      range: 0...max(1, (history.max() ?? 0) * 1.1), height: 30,
                      interval: interval, format: Fmt.percent)

            HStack(spacing: 0) {
                metric("CPU", Fmt.percent(agent.cpu))
                metric("Memory", Fmt.memory(agent.memory))
                metric("GPU", Fmt.percent(agent.gpu))
            }

            if let busiest = agent.busiest {
                HStack(spacing: 6) {
                    Text("Busiest").foregroundStyle(Palette.muted)
                    Text(busiest.command)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(Fmt.percent(busiest.cpu)).foregroundStyle(Palette.textPrimary).monospacedDigit()
                }
                .font(.system(size: 11))
                .help(busiest.command)
            }

            if !agent.subagents.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(agent.subagents) { sub in
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.turn.down.right").foregroundStyle(Palette.muted)
                            Text(sub.type).foregroundStyle(Palette.textSecondary)
                            Text(sub.description).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        .font(.system(size: 11))
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.border))
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = [agent.statusText]
        if let p = agent.project { parts.append(p) }
        if let since = agent.statusSince ?? agent.started {
            parts.append(Fmt.uptime(Date().timeIntervalSince(since)))
        }
        parts.append(agent.processCount == 1 ? "1 process" : "\(agent.processCount) processes")
        if !agent.subagents.isEmpty {
            parts.append(agent.subagents.count == 1 ? "1 subagent" : "\(agent.subagents.count) subagents")
        }
        return parts.joined(separator: " · ")
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.textPrimary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IdleAgentRow: View {
    var agent: AgentReading

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(working: false)
            Text(agent.title).foregroundStyle(Palette.textSecondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(trailing).foregroundStyle(Palette.muted).monospacedDigit().lineLimit(1).fixedSize()
        }
        .font(.system(size: 12))
        .help([agent.source, agent.project].compactMap { $0 }.joined(separator: " · "))
    }

    private var trailing: String {
        var parts: [String] = []
        if let since = agent.statusSince { parts.append("\(agent.statusText.lowercased()) \(Fmt.uptime(Date().timeIntervalSince(since)))") }
        parts.append(Fmt.memory(agent.memory))
        return parts.joined(separator: " · ")
    }
}
