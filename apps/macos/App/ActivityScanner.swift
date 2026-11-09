import Foundation

/// Builds `Activity` from Claude Code transcripts, Codex rollouts and VS Code
/// (Copilot agent mode) chat sessions.
///
/// There are gigabytes of these, so every file is read once: the scanner keeps
/// each file's byte offset and hourly tallies in activity-cache.json and on
/// later runs parses only what was appended. A first run over a busy week of
/// logs takes a while; after that a pass is a few milliseconds.
///
/// Runs on its own queue, never the main thread.
final class ActivityScanner {
    private let home = UsageStore.realHome
    private let cacheURL = UsageStore.dir.appendingPathComponent("activity-cache.json")
    private let keep: TimeInterval = 31 * 86_400

    private struct Tally: Codable {
        var t = TokenBreakdown()
        var subagent: Double = 0
        var longContext: Double = 0
    }

    private struct FileState: Codable {
        var offset: UInt64 = 0
        var recentIDs: [String] = []          // Claude repeats a message across lines
        var model: String?                    // Codex: from the latest turn_context
        var lastTotal: Double = 0             // Codex: cumulative, to skip repeated events
        var tallies: [String: [String: Tally]] = [:]  // hour -> model -> tally
        var tools: [String: [String: Int]] = [:]      // hour -> "kind|name" -> calls
        var project: String?                          // from the session's working folder
    }

    // Version 2 adds each file's project; older caches are rebuilt once.
    private struct Cache: Codable {
        var version = 2
        var files: [String: FileState] = [:]
    }

    private lazy var cache: Cache = {
        guard let d = try? Data(contentsOf: cacheURL),
              let c = try? JSONDecoder().decode(Cache.self, from: d), c.version == 2 else { return Cache() }
        return c
    }()

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: Scan

    func scan(now: Date = Date()) -> Activity {
        let cutoff = now.timeIntervalSince1970 - keep
        var seen = Set<String>()

        for url in files(under: home.appendingPathComponent(".claude/projects"), newerThan: cutoff) {
            let key = "c:" + url.path
            seen.insert(key)
            let subagentFile = url.path.contains("/subagents/")
            advance(key: key, url: url) { line, state in self.claudeLine(line, &state, subagentFile) }
        }
        for url in files(under: home.appendingPathComponent(".codex/sessions"), newerThan: cutoff) {
            let key = "x:" + url.path
            seen.insert(key)
            advance(key: key, url: url) { line, state in self.codexLine(line, &state) }
        }
        for url in vscodeSessionFiles(newerThan: cutoff) {
            let key = "v:" + url.path
            seen.insert(key)
            rereadVSCode(key: key, url: url)
        }

        // Forget files that aged out or vanished, and hours past the window.
        cache.files = cache.files.filter { seen.contains($0.key) }
        let cutoffHour = Int(cutoff / 3600) * 3600
        for k in cache.files.keys {
            cache.files[k]!.tallies = cache.files[k]!.tallies.filter { (Int($0.key) ?? 0) >= cutoffHour }
            cache.files[k]!.tools = cache.files[k]!.tools.filter { (Int($0.key) ?? 0) >= cutoffHour }
        }
        save()
        return summarize(now: now)
    }

    private func files(under root: URL, newerThan cutoff: TimeInterval, extensions: Set<String> = ["jsonl"]) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where extensions.contains(url.pathExtension) {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if let m = v?.contentModificationDate, m.timeIntervalSince1970 >= cutoff { out.append(url) }
        }
        return out
    }

    /// Reads from the stored offset in 8 MB chunks and hands over complete
    /// lines only; a half-written last line waits for the next pass.
    private func advance(key: String, url: URL, _ handle: (Data, inout FileState) -> Void) {
        var state = cache.files[key] ?? FileState()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0
        if size < state.offset { state = FileState() }          // rewritten or truncated
        guard size > state.offset, let fh = try? FileHandle(forReadingFrom: url) else {
            cache.files[key] = state; return
        }
        defer { try? fh.close() }
        try? fh.seek(toOffset: state.offset)

        var carry = Data()
        var done = false
        while !done {
            // The pool covers the read too: FileHandle hands back autoreleased
            // buffers, and without draining them each 8 MB chunk would stay
            // resident until the whole scan finished.
            autoreleasepool {
                guard let chunk = try? fh.read(upToCount: 8 << 20), !chunk.isEmpty else { done = true; return }
                carry.append(chunk)
                guard let lastNL = carry.lastIndex(of: 0x0A) else { return }
                let complete = carry[carry.startIndex...lastNL]
                for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    handle(Data(line), &state)
                }
                state.offset += UInt64(complete.count)
                carry = Data(carry[carry.index(after: lastNL)...])
            }
        }
        cache.files[key] = state
    }

    // MARK: Claude Code

    private static let assistantMarker = Data(#""type":"assistant""#.utf8)

    private func claudeLine(_ line: Data, _ s: inout FileState, _ subagentFile: Bool) {
        guard line.range(of: Self.assistantMarker) != nil,
              let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let msg = o["message"] as? [String: Any],
              let hour = hourKey(o["timestamp"]) else { return }
        if let cwd = o["cwd"] as? String { s.project = ProjectShare.name(cwd: cwd, home: home.path) }

        // Tools: every line carries different content blocks, so count them all.
        for block in msg["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
            if let d = driver(block) { s.tools[hour, default: [:]][d, default: 0] += 1 }
        }

        // Tokens: the same message repeats its usage on each of its lines.
        let id = msg["id"] as? String ?? UUID().uuidString
        guard !s.recentIDs.contains(id), let u = msg["usage"] as? [String: Any] else { return }
        s.recentIDs.append(id)
        if s.recentIDs.count > 64 { s.recentIDs.removeFirst(s.recentIDs.count - 64) }

        let model = msg["model"] as? String ?? "unknown"
        guard model != "<synthetic>" else { return }
        var t = TokenBreakdown(input: num(u["input_tokens"]), output: num(u["output_tokens"]),
                               cacheRead: num(u["cache_read_input_tokens"]),
                               cacheWrite: num(u["cache_creation_input_tokens"]), requests: 1)
        if t.total == 0 { t.requests = 0 }
        var tally = s.tallies[hour]?[model] ?? Tally()
        tally.t = tally.t + t
        if subagentFile || o["isSidechain"] as? Bool == true { tally.subagent += t.total }
        if t.input + t.cacheRead + t.cacheWrite > 150_000 { tally.longContext += t.total }
        s.tallies[hour, default: [:]][model] = tally
    }

    /// "MCP|Desktop Commander", "Skill|superpowers:writing-plans", …
    private func driver(_ block: [String: Any]) -> String? {
        guard let name = block["name"] as? String else { return nil }
        let input = block["input"] as? [String: Any] ?? [:]
        if name.hasPrefix("mcp__") {
            let parts = name.components(separatedBy: "__")
            guard parts.count >= 2 else { return nil }
            var server = parts[1]
            if server.hasPrefix("plugin_") {          // plugin_<plugin>_<server>
                server = String(server.dropFirst(7)).components(separatedBy: "_").last ?? server
            }
            // claude.ai connectors are registered under a UUID; no name to show.
            if server.range(of: #"^[0-9a-f]{8}-"#, options: .regularExpression) != nil { server = "claude.ai connector" }
            return "MCP|" + server.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        }
        switch name {
        case "Skill": return (input["skill"] as? String).map { "Skill|\($0)" }
        case "Agent", "Task": return "Subagent|" + (input["subagent_type"] as? String ?? "general-purpose")
        default: return "Tool|" + name
        }
    }

    // MARK: Codex

    private func codexLine(_ line: Data, _ s: inout FileState) {
        guard line.range(of: Data(#""token_count""#.utf8)) != nil
                || line.range(of: Data(#""turn_context""#.utf8)) != nil,
              let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let p = o["payload"] as? [String: Any] else { return }

        if o["type"] as? String == "turn_context" {
            s.model = p["model"] as? String ?? s.model
            if let cwd = p["cwd"] as? String { s.project = ProjectShare.name(cwd: cwd, home: home.path) }
            return
        }
        guard p["type"] as? String == "token_count",
              let info = p["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any],
              let hour = hourKey(o["timestamp"]) else { return }
        // Codex re-emits the same count; the running total only moves on new work.
        let total = num((info["total_token_usage"] as? [String: Any])?["total_tokens"])
        guard total > s.lastTotal else { return }
        s.lastTotal = total

        let cached = num(last["cached_input_tokens"])
        let t = TokenBreakdown(input: max(num(last["input_tokens"]) - cached, 0),
                               output: num(last["output_tokens"]), cacheRead: cached,
                               cacheWrite: num(last["cache_write_input_tokens"]), requests: 1)
        let model = s.model ?? "codex"
        var tally = s.tallies[hour]?[model] ?? Tally()
        tally.t = tally.t + t
        s.tallies[hour, default: [:]][model] = tally
    }

    // MARK: VS Code (Copilot agent mode)
    //
    // Chat sessions live per workspace in workspaceStorage/<hash>/chatSessions,
    // and for windows without a folder in globalStorage/emptyWindowChatSessions.
    // Newer builds write .jsonl: a `kind: 0` snapshot, then patches that append
    // requests or fill in fields. That is not an append-only log, so a changed
    // file is re-read whole (they are small) and requests are keyed by
    // requestId, which each carries its own prompt and completion token counts.

    private func vscodeSessionFiles(newerThan cutoff: TimeInterval) -> [URL] {
        let support = home.appendingPathComponent("Library/Application Support")
        var out: [URL] = []
        for app in ["Code", "Code - Insiders", "VSCodium"] {
            let user = support.appendingPathComponent(app).appendingPathComponent("User")
            let ws = user.appendingPathComponent("workspaceStorage")
            if let hashes = try? FileManager.default.contentsOfDirectory(at: ws, includingPropertiesForKeys: nil) {
                for h in hashes {
                    out += files(under: h.appendingPathComponent("chatSessions"), newerThan: cutoff,
                                 extensions: ["json", "jsonl"])
                }
            }
            out += files(under: user.appendingPathComponent("globalStorage/emptyWindowChatSessions"),
                         newerThan: cutoff, extensions: ["json", "jsonl"])
        }
        return out
    }

    private func rereadVSCode(key: String, url: URL) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0
        if let old = cache.files[key], old.offset == size { return }   // unchanged
        var state = FileState()
        state.offset = size
        // workspaceStorage/<hash>/workspace.json names the folder the window had open.
        let ws = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("workspace.json")
        if let d = try? Data(contentsOf: ws), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let folder = (o["folder"] as? String).flatMap(URL.init(string:)), folder.isFileURL {
            state.project = ProjectShare.name(cwd: folder.path, home: home.path)
        }
        autoreleasepool {
            guard let data = try? Data(contentsOf: url) else { return }
            var requests: [String: [String: Any]] = [:]
            func visit(_ o: Any) {
                if let d = o as? [String: Any] {
                    if let id = d["requestId"] as? String, d["timestamp"] != nil {
                        requests[id, default: [:]].merge(d) { _, new in new }
                    }
                    d.values.forEach(visit)
                } else if let a = o as? [Any] { a.forEach(visit) }
            }
            if url.pathExtension == "jsonl" {
                for line in data.split(separator: 0x0A) {
                    if let o = try? JSONSerialization.jsonObject(with: Data(line)) { visit(o) }
                }
            } else if let o = try? JSONSerialization.jsonObject(with: data) {
                visit(o)
            }
            for r in requests.values {
                let prompt = num(r["promptTokens"]), completion = num(r["completionTokens"])
                guard prompt + completion > 0, let ms = r["timestamp"].map(num), ms > 0 else { continue }
                let hour = String(Int(ms / 1000 / 3600) * 3600)
                var model = r["modelId"] as? String ?? "copilot"
                if let slash = model.firstIndex(of: "/") { model = String(model[model.index(after: slash)...]) }
                var tally = state.tallies[hour]?[model] ?? Tally()
                tally.t = tally.t + TokenBreakdown(input: prompt, output: completion, requests: 1)
                state.tallies[hour, default: [:]][model] = tally
            }
        }
        cache.files[key] = state
    }

    // MARK: Summary

    private func summarize(now: Date) -> Activity {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let dayStarts = (0..<30).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
        let monthStart = dayStarts.first!.timeIntervalSince1970
        let weekStart = dayStarts[dayStarts.count - 7].timeIntervalSince1970
        let dayAgo = now.timeIntervalSince1970 - 86_400

        var perDay: [TimeInterval: [Vendor: Double]] = [:]
        var perModel: [String: (Vendor, String, Double)] = [:]
        var last24: [Vendor: TokenBreakdown] = [:]
        var sub24 = 0.0, long24 = 0.0
        var calls: [String: Int] = [:]
        var driverTokens: [String: Double] = [:]
        var perProject: [String: [Vendor: Double]] = [:]
        var heat = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)

        for (key, f) in cache.files {
            let vendor: Vendor = key.hasPrefix("c:") ? .claude : key.hasPrefix("v:") ? .copilot : .codex
            for (h, models) in f.tallies {
                guard let hour = TimeInterval(h), hour >= monthStart else { continue }
                let day = cal.startOfDay(for: Date(timeIntervalSince1970: hour)).timeIntervalSince1970
                let when = Date(timeIntervalSince1970: hour)
                // Monday first: Calendar's weekday is 1 for Sunday.
                let weekday = (cal.component(.weekday, from: when) + 5) % 7
                let hourOfDay = cal.component(.hour, from: when)
                for (model, tally) in models {
                    perDay[day, default: [:]][vendor, default: 0] += tally.t.total
                    heat[weekday][hourOfDay] += tally.t.total
                    if hour >= weekStart {
                        perProject[f.project ?? "Other", default: [:]][vendor, default: 0] += tally.t.total
                    }
                    if hour >= weekStart {
                        let mk = "\(vendor.rawValue)|\(model)"
                        perModel[mk] = (vendor, model, (perModel[mk]?.2 ?? 0) + tally.t.total)
                    }
                    guard hour >= dayAgo - 3600 else { continue }   // the current partial hour counts
                    last24[vendor] = (last24[vendor] ?? TokenBreakdown()) + tally.t
                    if vendor == .claude { sub24 += tally.subagent; long24 += tally.longContext }
                }
            }
            // A driver is charged with every token its session spent in each
            // hour it was active. Overlapping and approximate — a session that
            // used two MCP servers counts toward both — but it points at what
            // was running while the limit went down, which call counts do not.
            for (h, tools) in f.tools where (TimeInterval(h) ?? 0) >= dayAgo - 3600 {
                let hourTokens = f.tallies[h]?.values.reduce(0) { $0 + $1.t.total } ?? 0
                for (k, n) in tools {
                    calls[k, default: 0] += n
                    driverTokens[k, default: 0] += hourTokens
                }
            }
        }

        let claude24 = last24[.claude] ?? TokenBreakdown()
        // Built-in tools (Read, Bash, …) run in nearly every session, so they
        // would all read ~100% and crowd out what is actually distinctive.
        let drivers = calls.compactMap { k, n -> Driver? in
            let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] != "Tool" else { return nil }
            let share = claude24.total > 0 ? min((driverTokens[k] ?? 0) / claude24.total, 1) : 0
            return Driver(name: parts[1], kind: parts[0], calls: n, share: share)
        }.sorted { ($0.share, $0.calls) > ($1.share, $1.calls) }

        func optional(_ v: Double?) -> Double? { (v ?? 0) > 0 ? v : nil }
        return Activity(
            generatedAt: now.timeIntervalSince1970,
            days: dayStarts.map { d in
                let t = d.timeIntervalSince1970, v = perDay[t] ?? [:]
                return DayUsage(day: t, claude: v[.claude] ?? 0, codex: v[.codex] ?? 0,
                                copilot: optional(v[.copilot]))
            },
            models: perModel.values.filter { $0.2 > 0 }
                .map { ModelShare(vendor: $0.0, model: $0.1, tokens: $0.2) }
                .sorted { $0.tokens > $1.tokens },
            claude24h: claude24, codex24h: last24[.codex] ?? TokenBreakdown(),
            drivers: Array(drivers.prefix(12)),
            subagentShare: claude24.total > 0 ? sub24 / claude24.total : nil,
            longContextShare: claude24.total > 0 ? long24 / claude24.total : nil,
            copilot24h: last24[.copilot].flatMap { $0.total > 0 ? $0 : nil },
            projects: perProject.compactMap { name, v -> ProjectShare? in
                let total = v.values.reduce(0, +)
                guard total > 0, let top = v.max(by: { $0.value < $1.value })?.key else { return nil }
                return ProjectShare(name: name, tokens: total, vendor: top)
            }.sorted { $0.tokens > $1.tokens }.prefix(12).map { $0 },
            heat: heat.joined().contains { $0 > 0 } ? heat : nil)
    }

    // MARK: helpers

    private func save() {
        try? FileManager.default.createDirectory(at: UsageStore.dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: cacheURL, options: .atomic) }
    }

    private func hourKey(_ ts: Any?) -> String? {
        guard let s = ts as? String,
              let d = iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) else { return nil }
        return String(Int(d.timeIntervalSince1970 / 3600) * 3600)
    }

    private func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return 0
    }
}
