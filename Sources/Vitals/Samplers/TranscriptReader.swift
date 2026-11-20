import Foundation

// MARK: - Model

/// One entry in an agent's activity log, parsed from its transcript.
struct AgentEvent: Identifiable {
    enum Kind { case prompt, command, reply, tool, subagent, compaction, apiError, hook, turn }

    var id: Int                 // sequence number within the transcript
    var time: Date
    var kind: Kind
    var title: String           // tool name, "Prompt", "Reply", …
    var text: String            // one-line summary
    var detail: String?         // full input / text, shown when the row is expanded
    var result: String?         // start of the tool result
    var duration: Double?       // tool latency, seconds
    var isError = false
    var pending = false         // tool call still waiting for its result
}

struct ToolStat: Identifiable {
    var id: String { name }
    var name: String
    var calls = 0
    var errors = 0
    var timedCalls = 0
    var totalDuration = 0.0
    var maxDuration = 0.0
    var averageDuration: Double? { timedCalls > 0 ? totalDuration / Double(timedCalls) : nil }
}

struct TokenUsage {
    var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
    var total: Int { input + output + cacheRead + cacheWrite }
    var context: Int { input + cacheRead + cacheWrite }

    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output,
                   cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
    static func - (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input - b.input, output: a.output - b.output,
                   cacheRead: a.cacheRead - b.cacheRead, cacheWrite: a.cacheWrite - b.cacheWrite)
    }
}

/// Activity counted per wall-clock minute.
struct ActivityBucket {
    var toolCalls = 0, errors = 0, prompts = 0, outputTokens = 0
}

struct SubagentActivity: Identifiable {
    var id: String
    var type: String
    var description: String
    var running: Bool
    var started: Date?
    var lastActivity: Date?
    var model: String?
    var tokens = TokenUsage()
    var toolCalls = 0
    var errors = 0
    var lastAction: String?
}

/// Everything learned from one Claude Code session's transcript.
struct AgentActivity {
    static let eventLimit = 2000

    var transcript: URL
    var transcriptBytes = 0
    var model: String?
    var models: Set<String> = []
    var gitBranch: String?
    var aiTitle: String?
    var lastPrompt: String?
    var tokens = TokenUsage()
    var contextTokens = 0
    var peakContext = 0
    var prompts = 0, replies = 0, toolCalls = 0, toolErrors = 0, apiErrors = 0, compactions = 0
    var turnDurations: [Double] = []
    var tools: [String: ToolStat] = [:]
    var minutes: [Int: ActivityBucket] = [:]       // key: minutes since 1970
    var events: [AgentEvent] = []                   // oldest first, at most `eventLimit`
    var firstEvent: Date?, lastEvent: Date?
    var costUSD: Double?                            // as reported by Claude Code itself
    var linesAdded: Int?, linesRemoved: Int?
    var subagents: [SubagentActivity] = []

    var runningSubagents: [SubagentActivity] { subagents.filter(\.running) }
    var errorCount: Int { toolErrors + apiErrors }
    var averageTurn: Double? { turnDurations.isEmpty ? nil : turnDurations.reduce(0, +) / Double(turnDurations.count) }
    var tokensIncludingSubagents: TokenUsage { subagents.reduce(tokens) { $0 + $1.tokens } }
    /// The tool call currently waiting for a result, if any.
    var inFlight: AgentEvent? { events.last(where: \.pending) }

    /// Sums of minute buckets into `count` equal buckets ending at `now`.
    func buckets(span minutes: Int, count: Int, now: Date = Date()) -> [ActivityBucket] {
        let size = max(1, minutes / count)
        let end = Int(now.timeIntervalSince1970 / 60)
        var result = [ActivityBucket](repeating: ActivityBucket(), count: count)
        for i in 0..<count {
            let first = end - (count - i) * size + 1
            for m in first..<(first + size) {
                guard let b = self.minutes[m] else { continue }
                result[i].toolCalls += b.toolCalls
                result[i].errors += b.errors
                result[i].prompts += b.prompts
                result[i].outputTokens += b.outputTokens
            }
        }
        return result
    }
}

// MARK: - Incremental parser

/// Reads a Claude Code `.jsonl` transcript incrementally: each update only parses bytes
/// appended since the previous one. The format is undocumented, so every field is optional.
final class TranscriptParser {
    private(set) var activity: AgentActivity
    private var offset: UInt64 = 0
    private var partial = Data()
    private var seq = 0
    private var pendingTools: [String: (seq: Int, name: String, time: Date)] = [:]
    private var lastMessageID: String?
    private var lastUsage = TokenUsage()

    private static let skipTypes: Set<String> = [
        "api-request", "api-request-blob", "api-request-shape", "file-history-snapshot", "file-history-delta",
        "attachment", "queue-operation", "mode", "permission-mode", "atis-latch", "tools-used", "progress",
    ]
    private static let typeKey = Data("\"type\":\"".utf8)
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    init(url: URL) { activity = AgentActivity(transcript: url) }

    func update() {
        let url = activity.transcript
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        if size < offset { reset() }                         // rewritten or truncated
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return }
        while true {
            guard let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)
            consume(chunk)
        }
        activity.transcriptBytes = Int(offset)
        prune()
    }

    private func reset() {
        let url = activity.transcript
        activity = AgentActivity(transcript: url)
        offset = 0
        partial = Data()
        seq = 0
        pendingTools = [:]
        lastMessageID = nil
        lastUsage = TokenUsage()
    }

    private func consume(_ chunk: Data) {
        var data = partial
        data.append(chunk)
        var start = data.startIndex
        while let nl = data[start...].firstIndex(of: 0x0A) {
            if nl > start { handle(line: data[start..<nl]) }
            start = data.index(after: nl)
        }
        partial = Data(data[start...])
    }

    private func handle(line: Data) {
        // Cheap pre-filter: lines whose first "type" is a known bulky, irrelevant record are skipped
        // without decoding (request blobs can be megabytes each).
        let head = line.prefix(600)
        if let r = head.range(of: TranscriptParser.typeKey) {
            let rest = head[r.upperBound...]
            if let q = rest.firstIndex(of: 0x22),
               let type = String(data: rest[rest.startIndex..<q], encoding: .utf8),
               TranscriptParser.skipTypes.contains(type) { return }
        }
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let time = (json["timestamp"] as? String).flatMap(TranscriptParser.date)
        switch json["type"] as? String {
        case "assistant": assistant(json, time: time)
        case "user": user(json, time: time)
        case "system": system(json, time: time)
        case "ai-title": activity.aiTitle = json["aiTitle"] as? String
        case "last-prompt": if let p = json["lastPrompt"] as? String { activity.lastPrompt = p }
        case "cost-state":
            if let c = json["totalCostUSD"] as? Double { activity.costUSD = c }
            activity.linesAdded = json["totalLinesAdded"] as? Int
            activity.linesRemoved = json["totalLinesRemoved"] as? Int
        default: break
        }
        if let b = json["gitBranch"] as? String, !b.isEmpty { activity.gitBranch = b }
        if let time {
            if activity.firstEvent == nil { activity.firstEvent = time }
            activity.lastEvent = max(activity.lastEvent ?? time, time)
        }
    }

    // MARK: Records

    private func assistant(_ json: [String: Any], time: Date?) {
        guard let message = json["message"] as? [String: Any] else { return }
        let time = time ?? activity.lastEvent ?? Date()
        if let model = message["model"] as? String, !model.hasPrefix("<") {
            activity.model = model
            activity.models.insert(model)
        }
        // A response is split over several lines (one per content block) that repeat its usage;
        // count each message id once, keeping the latest figures.
        let id = message["id"] as? String
        if let usage = message["usage"] as? [String: Any] {
            let u = TokenUsage(input: usage["input_tokens"] as? Int ?? 0,
                               output: usage["output_tokens"] as? Int ?? 0,
                               cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                               cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0)
            let minute = TranscriptParser.minute(time)
            if let id, id == lastMessageID {
                activity.tokens = activity.tokens - lastUsage
                activity.minutes[minute, default: .init()].outputTokens -= lastUsage.output
            } else {
                activity.replies += 1
            }
            activity.tokens = activity.tokens + u
            activity.minutes[minute, default: .init()].outputTokens += u.output
            lastUsage = u
            lastMessageID = id
            if u.context > 0 {
                activity.contextTokens = u.context
                activity.peakContext = max(activity.peakContext, u.context)
            }
        }
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                append(AgentEvent(id: 0, time: time, kind: .reply, title: "Reply", text: TranscriptParser.firstLine(text),
                                  detail: String(text.prefix(6000))))
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                let (kind, title, summary, detail) = TranscriptParser.describeTool(name, input)
                let seq = append(AgentEvent(id: 0, time: time, kind: kind, title: title, text: summary,
                                            detail: detail, pending: true))
                if let toolID = block["id"] as? String { pendingTools[toolID] = (seq, name, time) }
                activity.toolCalls += 1
                activity.tools[name, default: ToolStat(name: name)].calls += 1
                activity.minutes[TranscriptParser.minute(time), default: .init()].toolCalls += 1
            default: break
            }
        }
    }

    private func user(_ json: [String: Any], time: Date?) {
        guard let message = json["message"] as? [String: Any] else { return }
        let time = time ?? activity.lastEvent ?? Date()
        if let text = message["content"] as? String {
            prompt(text, time: time, meta: json["isMeta"] as? Bool == true)
            return
        }
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "tool_result":
                guard let toolID = block["tool_use_id"] as? String, let call = pendingTools.removeValue(forKey: toolID) else { continue }
                let isError = block["is_error"] as? Bool == true
                let duration = max(0, time.timeIntervalSince(call.time))
                var stat = activity.tools[call.name, default: ToolStat(name: call.name)]
                stat.timedCalls += 1
                stat.totalDuration += duration
                stat.maxDuration = max(stat.maxDuration, duration)
                if isError { stat.errors += 1 }
                activity.tools[call.name] = stat
                if isError {
                    activity.toolErrors += 1
                    activity.minutes[TranscriptParser.minute(time), default: .init()].errors += 1
                }
                updateEvent(call.seq) { e in
                    e.pending = false
                    e.duration = duration
                    e.isError = isError
                    e.result = TranscriptParser.resultText(block["content"]).map { String($0.prefix(1500)) }
                }
            case "text":
                prompt(block["text"] as? String ?? "", time: time, meta: json["isMeta"] as? Bool == true)
            default: break
            }
        }
    }

    private func prompt(_ raw: String, time: Date, meta: Bool) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !meta, !text.isEmpty else { return }
        if text.hasPrefix("<command-name>") {
            let name = TranscriptParser.tag("command-name", in: text) ?? "command"
            let args = TranscriptParser.tag("command-args", in: text) ?? ""
            append(AgentEvent(id: 0, time: time, kind: .command, title: "Command",
                              text: args.isEmpty ? name : "\(name) \(args)"))
            return
        }
        // Harness-injected messages (reminders, notifications, command output) are wrapped in tags.
        guard !text.hasPrefix("<") else { return }
        activity.prompts += 1
        activity.minutes[TranscriptParser.minute(time), default: .init()].prompts += 1
        append(AgentEvent(id: 0, time: time, kind: .prompt, title: "Prompt", text: TranscriptParser.firstLine(text),
                          detail: String(text.prefix(6000))))
    }

    private func system(_ json: [String: Any], time: Date?) {
        let time = time ?? activity.lastEvent ?? Date()
        switch json["subtype"] as? String {
        case "compact_boundary":
            activity.compactions += 1
            let meta = json["compactMetadata"] as? [String: Any]
            var text = "Context compacted"
            if let pre = meta?["preTokens"] as? Int, let post = meta?["postTokens"] as? Int {
                text += " · \(Fmt.tokens(pre)) → \(Fmt.tokens(post))"
            }
            if let trigger = meta?["trigger"] as? String { text += " (\(trigger))" }
            append(AgentEvent(id: 0, time: time, kind: .compaction, title: "Compaction", text: text))
        case "api_error":
            activity.apiErrors += 1
            activity.minutes[TranscriptParser.minute(time), default: .init()].errors += 1
            let error = json["error"] as? [String: Any]
            var text = "API error"
            if let status = error?["status"] as? Int { text += " \(status)" }
            if let attempt = json["retryAttempt"] as? Int, let max = json["maxRetries"] as? Int { text += " · retry \(attempt)/\(max)" }
            append(AgentEvent(id: 0, time: time, kind: .apiError, title: "API error", text: text,
                              detail: error?["message"] as? String, isError: true))
        case "turn_duration":
            guard let ms = json["durationMs"] as? Double else { return }
            activity.turnDurations.append(ms / 1000)
            if activity.turnDurations.count > 500 { activity.turnDurations.removeFirst() }
            var text = "Turn finished in \(Fmt.duration(ms / 1000))"
            if let n = json["messageCount"] as? Int { text += " · \(n) messages" }
            append(AgentEvent(id: 0, time: time, kind: .turn, title: "Turn", text: text))
        case "stop_hook_summary":
            let errors = json["hookErrors"] as? [Any] ?? []
            guard !errors.isEmpty else { return }
            append(AgentEvent(id: 0, time: time, kind: .hook, title: "Hook", text: "\(errors.count) hook error(s)",
                              detail: errors.map { "\($0)" }.joined(separator: "\n"), isError: true))
        default: break
        }
    }

    // MARK: Events

    @discardableResult
    private func append(_ event: AgentEvent) -> Int {
        var e = event
        e.id = seq
        seq += 1
        activity.events.append(e)
        if activity.events.count > AgentActivity.eventLimit + 200 {
            activity.events.removeFirst(activity.events.count - AgentActivity.eventLimit)
        }
        return e.id
    }

    private func updateEvent(_ seq: Int, _ change: (inout AgentEvent) -> Void) {
        guard let first = activity.events.first?.id else { return }
        let i = seq - first
        if activity.events.indices.contains(i) { change(&activity.events[i]) }
    }

    private func prune() {
        let cutoff = Int(Date().timeIntervalSince1970 / 60) - 24 * 60
        if activity.minutes.keys.contains(where: { $0 < cutoff }) {
            activity.minutes = activity.minutes.filter { $0.key >= cutoff }
        }
        // Tool calls interrupted by the user never get a result; stop showing them as running.
        if pendingTools.count > 200 { pendingTools.removeAll() }
    }

    // MARK: Helpers

    static func date(_ s: String) -> Date? { isoFractional.date(from: s) ?? iso.date(from: s) }
    private static func minute(_ d: Date) -> Int { Int(d.timeIntervalSince1970 / 60) }

    private static func firstLine(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return String(line.prefix(240))
    }

    private static func tag(_ name: String, in s: String) -> String? {
        guard let a = s.range(of: "<\(name)>"), let b = s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex) else { return nil }
        return s[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resultText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return text.isEmpty ? (blocks.isEmpty ? nil : "[\(blocks.count) non-text block(s)]") : text
        }
        return nil
    }

    /// Kind, title, one-line summary and full detail for a tool call.
    static func describeTool(_ name: String, _ input: [String: Any]) -> (AgentEvent.Kind, String, String, String?) {
        func str(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let detail = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }.map { String($0.prefix(6000)) }
        var title = name
        var summary: String
        var kind = AgentEvent.Kind.tool
        switch name {
        case "Bash":
            summary = str("description") ?? str("command") ?? ""
            if let c = str("command") { return (.tool, name, firstLine(summary), c) }
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            summary = (str("file_path") ?? str("notebook_path")).map { ($0 as NSString).lastPathComponent } ?? ""
            if let p = str("file_path") { return (.tool, name, summary, p + (detail.map { "\n\n" + $0 } ?? "")) }
        case "Grep", "Glob":
            summary = str("pattern") ?? ""
            if let path = str("path") { summary += "  in \((path as NSString).lastPathComponent)" }
        case "WebFetch": summary = str("url") ?? ""
        case "WebSearch": summary = str("query") ?? ""
        case "Agent", "Task":
            kind = .subagent
            title = "Subagent"
            summary = [str("subagent_type"), str("description")].compactMap { $0 }.joined(separator: " · ")
        case "Skill": summary = str("skill") ?? ""
        case "TodoWrite": summary = "\((input["todos"] as? [Any])?.count ?? 0) todos"
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.dropFirst(5).components(separatedBy: "__")
                title = parts.count >= 2 ? "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" : name
            }
            summary = input.sorted { $0.key < $1.key }.lazy.compactMap { $0.value as? String }.first ?? ""
        }
        return (kind, title, firstLine(summary), detail)
    }
}

// MARK: - Store

/// Keeps one parser per live Claude Code session and refreshes them on a background queue,
/// so a large transcript never stalls the sampling tick. Readers get the latest finished parse.
final class TranscriptStore {
    private let queue = DispatchQueue(label: "app.vitals.transcripts", qos: .utility)
    private let lock = NSLock()
    private var latest: [String: AgentActivity] = [:]
    private var inFlight = Set<String>()

    // Touched only on `queue`.
    private var parsers: [String: TranscriptParser] = [:]
    private var subParsers: [String: [String: TranscriptParser]] = [:]
    private var paths: [String: URL] = [:]
    private var lastSearch: [String: Date] = [:]
    private var lastRefresh: [String: Date] = [:]

    private let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    /// Latest parsed activity for a session; schedules a refresh in the background.
    func activity(session: String, cwd: String?) -> AgentActivity? {
        lock.lock()
        let current = latest[session]
        let start = inFlight.insert(session).inserted
        lock.unlock()
        if start {
            queue.async { [self] in
                let result = refresh(session: session, cwd: cwd)
                lock.lock()
                if let result { latest[session] = result }
                inFlight.remove(session)
                lock.unlock()
            }
        }
        return current
    }

    /// Drops state for sessions that are no longer running.
    func retain(_ sessions: Set<String>) {
        lock.lock()
        latest = latest.filter { sessions.contains($0.key) }
        lock.unlock()
        queue.async { [self] in
            parsers = parsers.filter { sessions.contains($0.key) }
            subParsers = subParsers.filter { sessions.contains($0.key) }
            paths = paths.filter { sessions.contains($0.key) }
        }
    }

    private func refresh(session: String, cwd: String?) -> AgentActivity? {
        if let last = lastRefresh[session], Date().timeIntervalSince(last) < 0.9 { return nil }
        lastRefresh[session] = Date()
        guard let url = transcript(session: session, cwd: cwd) else { return nil }
        let parser: TranscriptParser
        if let p = parsers[session], p.activity.transcript == url { parser = p } else {
            parser = TranscriptParser(url: url)
            parsers[session] = parser
        }
        parser.update()
        var activity = parser.activity
        activity.subagents = subagents(session: session, dir: url.deletingPathExtension().appendingPathComponent("subagents"))
        return activity
    }

    private func transcript(session: String, cwd: String?) -> URL? {
        if let url = paths[session], FileManager.default.fileExists(atPath: url.path) { return url }
        // Claude Code names the project folder after the working directory, non-alphanumerics → "-".
        if let cwd {
            let encoded = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            let url = projects.appendingPathComponent(encoded).appendingPathComponent("\(session).jsonl")
            if FileManager.default.fileExists(atPath: url.path) { paths[session] = url; return url }
        }
        if let last = lastSearch[session], Date().timeIntervalSince(last) < 15 { return nil }
        lastSearch[session] = Date()
        for dir in (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            let url = dir.appendingPathComponent("\(session).jsonl")
            if FileManager.default.fileExists(atPath: url.path) { paths[session] = url; return url }
        }
        return nil
    }

    private func subagents(session: String, dir: URL) -> [SubagentActivity] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var known = subParsers[session] ?? [:]
        var result: [SubagentActivity] = []
        for meta in files where meta.lastPathComponent.hasSuffix(".meta.json") {
            let id = String(meta.lastPathComponent.dropLast(".meta.json".count))
            let transcript = dir.appendingPathComponent(id + ".jsonl")
            guard let data = try? Data(contentsOf: meta),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let parser = known[id] ?? TranscriptParser(url: transcript)
            known[id] = parser
            parser.update()
            let a = parser.activity
            let modified = (try? transcript.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            // Older versions never wrote "finished"; only trust recently written transcripts.
            let running = json["finished"] as? Bool != true && modified.map { Date().timeIntervalSince($0) < 600 } == true
            let last = a.events.last
            result.append(SubagentActivity(
                id: id,
                type: json["agentType"] as? String ?? "agent",
                description: json["description"] as? String ?? "",
                running: running,
                started: a.firstEvent,
                lastActivity: a.lastEvent ?? modified,
                model: a.model ?? json["pickedEffortModel"] as? String,
                tokens: a.tokens,
                toolCalls: a.toolCalls,
                errors: a.errorCount,
                lastAction: last.map { "\($0.title): \($0.text)" }))
        }
        subParsers[session] = known
        return result.sorted { a, b in
            if a.running != b.running { return a.running }
            return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
        }
    }
}
