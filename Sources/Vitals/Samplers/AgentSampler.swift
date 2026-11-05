import Darwin
import Foundation
import IOKit

struct SubagentStatus: Identifiable {
    var id: String
    var type: String
    var description: String
}

struct AgentReading: Identifiable {
    enum Kind { case claudeCode, cliAgent, localModel }

    var id: String                 // stable across samples: "<pid>-<process start>"
    var pid: pid_t
    var kind: Kind
    var title: String
    var source: String             // "Claude app", "Terminal", "Codex", "LM Studio", …
    var project: String?           // working-folder name
    var isWorking: Bool
    var statusText: String         // "Working", "Idle", …
    var statusSince: Date?
    var started: Date?
    var cpu: Double = 0            // fraction of one core, whole process tree (can exceed 1)
    var memory: UInt64 = 0         // physical footprint of the live tree
    var gpu: Double = 0            // 0...1
    var processCount = 0
    var busiest: (command: String, cpu: Double)?
    var subagents: [SubagentStatus] = []
}

/// Finds AI agents and measures everything each one has spawned.
///
/// - Claude Code sessions (desktop app and terminal) come from Claude Code's own registry,
///   `~/.claude/sessions/<pid>.json`, which carries the title, folder and busy/idle status.
///   The format is undocumented, so every entry is checked against the live process, and
///   `claude` processes missing from the registry are still found by executable path.
/// - Other agent CLIs and local model runtimes are recognised by executable / arguments;
///   they have no status signal, so "working" is inferred from recent CPU/GPU use.
/// - CPU counts each process's own time plus the time of children it has already reaped,
///   so short-lived build and hook processes are included (sampling live processes misses them).
final class AgentSampler {
    private struct Root {
        var pid: pid_t
        var start: Int
        var kind: AgentReading.Kind
        var source: String
        var registry: RegistryEntry?
    }

    private struct RegistryEntry: Decodable {
        var pid: Int32
        var sessionId: String?
        var cwd: String?
        var name: String?
        var status: String?
        var statusUpdatedAt: Double?
        var startedAt: Double?
        var entrypoint: String?
        var procStart: String?
    }

    private struct Previous { var cpu: Double; var gpu: Double; var time: Double }

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var previous: [String: Previous] = [:]
    private var previousPerPid: [pid_t: Double] = [:]
    /// Processes first seen inside an agent's tree that later detached (re-parented to launchd).
    private var adopted: [String: [pid_t: Int]] = [:]
    private var discovered: [Root] = []
    private var lastDiscovery = -Double.infinity
    private var subagentDirs: [String: URL] = [:]
    private var subagentSearch: [String: Double] = [:]
    private var argvCache: [pid_t: (start: Int, args: [String])] = [:]

    private let ticksToSeconds: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb.denom == 0 ? 1e-9 : Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    private static let procStartFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

    func sample() -> [AgentReading] {
        let now = monotonicSeconds()
        var roots = registryRoots()
        if now - lastDiscovery > 5 {
            discovered = discoverRoots(excluding: Set(roots.map(\.pid)))
            lastDiscovery = now
        }
        let known = Set(roots.map(\.pid))
        roots += discovered.filter { !known.contains($0.pid) && AgentSampler.startTime($0.pid) == $0.start }

        let gpuByPid = AgentSampler.gpuTimes()
        var readings: [AgentReading] = []
        var seenPids: [pid_t: Double] = [:]
        var liveIDs = Set<String>()

        for root in roots {
            let id = "\(root.pid)-\(root.start)"
            liveIDs.insert(id)
            var members = AgentSampler.tree(of: root.pid)
            // Keep counting processes the agent started that have since detached.
            var keep: [pid_t: Int] = [:]
            for (pid, start) in adopted[id] ?? [:] where AgentSampler.startTime(pid) == start {
                keep[pid] = start
                if !members.contains(pid), AgentSampler.parent(of: pid) == 1 {
                    members += AgentSampler.tree(of: pid)
                }
            }
            var cpuTotal = 0.0, gpuTotal = 0.0
            var memory: UInt64 = 0
            var count = 0
            var busiest: (pid: pid_t, delta: Double)?
            for pid in members {
                guard let u = AgentSampler.rusage(pid) else { continue }
                count += 1
                let t = Double(u.ri_user_time + u.ri_system_time + u.ri_child_user_time + u.ri_child_system_time) * ticksToSeconds
                cpuTotal += t
                memory += u.ri_phys_footprint
                gpuTotal += Double(gpuByPid[pid] ?? 0) / 1e9
                seenPids[pid] = t
                if pid != root.pid, let before = previousPerPid[pid], t - before > (busiest?.delta ?? 0) {
                    busiest = (pid, t - before)
                }
                if pid != root.pid, keep[pid] == nil, let s = AgentSampler.startTime(pid) { keep[pid] = s }
            }
            adopted[id] = keep

            var r = AgentReading(id: id, pid: root.pid, kind: root.kind, title: root.source, source: root.source,
                                 project: nil, isWorking: false, statusText: "Idle", statusSince: nil,
                                 started: Date(timeIntervalSince1970: TimeInterval(root.start)))
            r.memory = memory
            r.processCount = count
            if let p = previous[id] {
                let dt = now - p.time
                if dt > 0 {
                    r.cpu = max(0, cpuTotal - p.cpu) / dt
                    r.gpu = min(1, max(0, gpuTotal - p.gpu) / dt)
                    if let b = busiest, b.delta / dt >= 0.02 {
                        r.busiest = (AgentSampler.describe(b.pid, cache: &argvCache), b.delta / dt)
                    }
                }
            }
            previous[id] = Previous(cpu: cpuTotal, gpu: gpuTotal, time: now)

            if let reg = root.registry {
                if let cwd = reg.cwd { r.project = (cwd as NSString).lastPathComponent }
                r.title = reg.name?.isEmpty == false ? reg.name! : (r.project ?? "Claude Code")
                switch reg.status?.lowercased() {
                case "busy"?: r.isWorking = true; r.statusText = "Working"
                case "idle"?, nil: r.statusText = "Idle"
                case let other?: r.statusText = other.capitalized
                }
                if let ms = reg.statusUpdatedAt { r.statusSince = Date(timeIntervalSince1970: ms / 1000) }
                if let ms = reg.startedAt { r.started = Date(timeIntervalSince1970: ms / 1000) }
                if let session = reg.sessionId { r.subagents = runningSubagents(session: session, now: now) }
                if !r.subagents.isEmpty { r.isWorking = true; r.statusText = "Working" }
            } else {
                if let cwd = AgentSampler.cwd(of: root.pid) {
                    let name = (cwd as NSString).lastPathComponent
                    if cwd != "/" && cwd != home.path { r.project = name }
                }
                r.title = r.project.map { root.kind == .localModel ? root.source : $0 } ?? root.source
                r.isWorking = r.cpu > 0.05 || r.gpu > 0.05
                r.statusText = r.isWorking ? "Active" : "Idle"
            }
            readings.append(r)
        }

        previousPerPid = seenPids
        previous = previous.filter { liveIDs.contains($0.key) }
        adopted = adopted.filter { liveIDs.contains($0.key) }
        argvCache = argvCache.filter { seenPids[$0.key] != nil }

        return readings.sorted { a, b in
            if a.isWorking != b.isWorking { return a.isWorking }
            return (a.statusSince ?? a.started ?? .distantPast) > (b.statusSince ?? b.started ?? .distantPast)
        }
    }

    // MARK: Claude Code registry

    private func registryRoots() -> [Root] {
        let dir = home.appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var roots: [Root] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(RegistryEntry.self, from: data),
                  let start = AgentSampler.startTime(entry.pid) else { continue }   // process gone: stale file
            // Guard against a recycled pid: the recorded start must match the live process.
            if let text = entry.procStart?.replacingOccurrences(of: "  ", with: " "),
               let recorded = AgentSampler.procStartFormat.date(from: text) {
                guard abs(recorded.timeIntervalSince1970 - Double(start)) <= 2 else { continue }
            } else if !(AgentSampler.path(of: entry.pid) ?? "").lowercased().contains("claude") {
                continue
            }
            let source: String
            switch entry.entrypoint {
            case "claude-desktop": source = "Claude app"
            case "cli": source = "Terminal"
            case let e? where e.contains("vscode"): source = "VS Code"
            case let e? where e.contains("jetbrains"): source = "JetBrains"
            case let e?: source = e
            case nil: source = "Claude Code"
            }
            roots.append(Root(pid: entry.pid, start: start, kind: .claudeCode, source: source, registry: entry))
        }
        return roots
    }

    private func runningSubagents(session: String, now: Double) -> [SubagentStatus] {
        if subagentDirs[session] == nil, now - (subagentSearch[session] ?? -.infinity) > 15 {
            subagentSearch[session] = now
            let projects = home.appendingPathComponent(".claude/projects")
            for project in (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
                let candidate = project.appendingPathComponent(session).appendingPathComponent("subagents")
                if FileManager.default.fileExists(atPath: candidate.path) { subagentDirs[session] = candidate; break }
            }
        }
        guard let dir = subagentDirs[session],
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        var result: [SubagentStatus] = []
        for meta in files where meta.lastPathComponent.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: meta),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["finished"] as? Bool) != true else { continue }
            // Older versions never wrote "finished"; only trust recently active transcripts.
            let transcript = dir.appendingPathComponent(meta.lastPathComponent.replacingOccurrences(of: ".meta.json", with: ".jsonl"))
            let modified = (try? transcript.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, Date().timeIntervalSince(modified) < 600 else { continue }
            result.append(SubagentStatus(id: meta.lastPathComponent,
                                         type: json["agentType"] as? String ?? "agent",
                                         description: json["description"] as? String ?? ""))
        }
        return result
    }

    // MARK: Other agents

    private func discoverRoots(excluding registered: Set<pid_t>) -> [Root] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var found: [Root] = []
        for pid in pids.prefix(n) where pid > 1 && !registered.contains(pid) {
            guard let path = AgentSampler.path(of: pid), let start = AgentSampler.startTime(pid),
                  let (kind, source) = classify(pid: pid, path: path, start: start) else { continue }
            found.append(Root(pid: pid, start: start, kind: kind, source: source, registry: nil))
        }
        // An agent launched by another agent (e.g. Claude running `codex`) belongs to its parent.
        let roots = Set(found.map(\.pid)).union(registered)
        return found.filter { r in
            var p = AgentSampler.parent(of: r.pid)
            var hops = 0
            while let q = p, q > 1, hops < 64 {
                if roots.contains(q) { return false }
                p = AgentSampler.parent(of: q)
                hops += 1
            }
            return true
        }
    }

    private func classify(pid: pid_t, path: String, start: Int) -> (AgentReading.Kind, String)? {
        let exe = (path as NSString).lastPathComponent
        if path.contains("/.local/share/claude/versions/") || path.hasSuffix("claude.app/Contents/MacOS/claude") || exe == "claude" {
            return (.claudeCode, "Claude Code")
        }
        switch exe {
        case "codex": return (.cliAgent, "Codex")
        case "cursor-agent": return (.cliAgent, "Cursor Agent")
        case "opencode": return (.cliAgent, "OpenCode")
        case "goose": return (.cliAgent, "Goose")
        case "aider": return (.cliAgent, "Aider")
        case "LM Studio" where path.contains("LM Studio.app/Contents/MacOS/"): return (.localModel, "LM Studio")
        case "Ollama" where path.contains("Ollama.app/Contents/MacOS/"): return (.localModel, "Ollama")
        case "ollama":
            // `ollama serve` is the runtime; plain `ollama run` clients are its children or short-lived.
            return arguments(pid, start: start).contains("serve") ? (.localModel, "Ollama") : nil
        default: break
        }
        // Script-based CLIs run under node / python: inspect their arguments.
        guard ["node", "bun", "python", "python3", "deno"].contains(where: { exe.hasPrefix($0) }) else { return nil }
        let args = arguments(pid, start: start).dropFirst().prefix(2).joined(separator: " ")
        if args.contains("@google/gemini-cli") || args.hasSuffix("/bin/gemini") { return (.cliAgent, "Gemini CLI") }
        if args.contains("@openai/codex") || args.hasSuffix("/bin/codex") { return (.cliAgent, "Codex") }
        if args.contains("@sourcegraph/amp") || args.hasSuffix("/bin/amp") { return (.cliAgent, "Amp") }
        if args.contains("@anthropic-ai/claude-code") { return (.claudeCode, "Claude Code") }
        if args.contains("/bin/aider") || args.hasSuffix(" -m aider") { return (.cliAgent, "Aider") }
        return nil
    }

    private func arguments(_ pid: pid_t, start: Int) -> [String] {
        if let cached = argvCache[pid], cached.start == start { return cached.args }
        let args = AgentSampler.argv(pid)
        argvCache[pid] = (start, args)
        return args
    }

    // MARK: Process helpers

    private static func tree(of root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var stack = [root]
        var buffer = [pid_t](repeating: 0, count: 256)
        while let pid = stack.popLast(), result.count < 4096 {
            result.append(pid)
            let n = Int(proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size)))
            if n > 0 { stack += buffer.prefix(min(n, buffer.count)).filter { $0 > 0 } }
        }
        return result
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func startTime(_ pid: pid_t) -> Int? { bsdInfo(pid).map { Int($0.pbi_start_tvsec) } }
    static func parent(of pid: pid_t) -> pid_t? { bsdInfo(pid).map { pid_t($0.pbi_ppid) } }

    private static func rusage(_ pid: pid_t) -> rusage_info_v2? {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return ok == 0 ? info : nil
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    private static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// Command-line arguments via KERN_PROCARGS2 (works for the current user's processes).
    private static func argv(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }   // executable path
        while i < size, buffer[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc, i < size {
            let begin = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[begin..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// Short, human-readable description of a process for the "busiest" line.
    private static func describe(_ pid: pid_t, cache: inout [pid_t: (start: Int, args: [String])]) -> String {
        var nameBuffer = [CChar](repeating: 0, count: 256)
        let name = proc_name(pid, &nameBuffer, 256) > 0 ? String(cString: nameBuffer) : "pid \(pid)"
        let runners: Set<String> = ["node", "bun", "python", "python3", "xargs", "npm", "npx", "sh", "zsh", "bash", "env", "deno"]
        guard runners.contains(name) else { return name }
        let start = startTime(pid) ?? 0
        let args: [String]
        if let c = cache[pid], c.start == start { args = c.args } else { args = argv(pid); cache[pid] = (start, args) }
        var words = Array(args.dropFirst())
        // Claude Code wraps tool commands as: zsh -c "source <snapshot> … && eval '<command>' …"
        if ["sh", "zsh", "bash"].contains(name), let script = words.last {
            if let r = script.range(of: "eval '") {
                let rest = script[r.upperBound...]
                return String((rest.split(separator: "'").first ?? Substring(rest)).prefix(60))
            }
            return "shell command"
        }
        words = words.filter { !$0.hasPrefix("-") }.map { $0.contains("/") ? ($0 as NSString).lastPathComponent : $0 }
        let text = ([name] + words.prefix(4)).joined(separator: " ")
        return String(text.prefix(60))
    }

    /// Accumulated GPU time (seconds × 1e9) per pid, from the Metal driver's per-client stats.
    private static func gpuTimes() -> [pid_t: UInt64] {
        var result: [pid_t: UInt64] = [:]
        IOKitUtil.forEachService("AGXDeviceUserClient") { client in
            guard let creator = IOKitUtil.property(client, "IOUserClientCreator") as? String,
                  let token = creator.split(separator: ",").first?.split(separator: " ").last,
                  let pid = pid_t(token),
                  let usage = IOKitUtil.property(client, "AppUsage") as? [[String: Any]] else { return }
            for entry in usage {
                result[pid, default: 0] += (entry["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0
            }
        }
        return result
    }
}
