import Foundation

// MARK: - Activity: what used the limits
//
// Plan limits say how much is left; they do not say what spent it. Both
// vendors log every request's token counts locally — Claude Code in
// ~/.claude/projects transcripts, Codex in ~/.codex/sessions rollouts — so
// this is built from those, the way Claude Code's /usage panel is.
// This machine only: usage from claude.ai, chatgpt.com or other computers is
// not in these logs.

struct TokenBreakdown: Codable, Hashable {
    var input: Double = 0
    var output: Double = 0
    var cacheRead: Double = 0
    var cacheWrite: Double = 0
    var requests: Double = 0

    var total: Double { input + output + cacheRead + cacheWrite }

    /// Share of prompt tokens served from cache. Low means the cache keeps
    /// expiring between turns and the same context is paid for again.
    var cacheHit: Double? {
        // No cache figures at all (VS Code does not log them) is unknown, not 0%.
        guard cacheRead + cacheWrite > 0 else { return nil }
        let prompt = input + cacheRead + cacheWrite
        return prompt > 0 ? cacheRead / prompt : nil
    }

    static func + (a: Self, b: Self) -> Self {
        .init(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
              cacheWrite: a.cacheWrite + b.cacheWrite, requests: a.requests + b.requests)
    }
}

struct DayUsage: Codable, Hashable, Identifiable {
    var id: TimeInterval { day }
    var day: TimeInterval          // local midnight, unix seconds
    var claude: Double
    var codex: Double
    // Optional so boards written before these lanes still decode.
    var copilot: Double? = nil
    var cursor: Double? = nil
    var grok: Double? = nil
    var date: Date { Date(timeIntervalSince1970: day) }

    func tokens(_ v: Vendor) -> Double {
        switch v {
        case .claude: claude
        case .codex: codex
        case .copilot: copilot ?? 0
        case .cursor: cursor ?? 0
        case .grok: grok ?? 0
        }
    }
    var total: Double { Vendor.allCases.reduce(0) { $0 + tokens($1) } }
}

struct ModelShare: Codable, Hashable, Identifiable {
    var id: String { "\(vendor.rawValue)|\(model)" }
    var vendor: Vendor
    var model: String
    var tokens: Double

    /// "claude-opus-5-5" → "Opus 5.5"; "gpt-6-astra" → "GPT-6 Astra".
    var displayName: String {
        if vendor == .copilot, model == "auto" { return "Copilot Auto" }
        var m = model
        if m.hasPrefix("claude-") {
            m.removeFirst("claude-".count)
            m = m.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
            let parts = m.split(separator: "-")
            guard let family = parts.first else { return model }
            let version = parts.dropFirst().joined(separator: ".")
            return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " \(version)")
        }
        if m.hasPrefix("gpt-") {
            let rest = m.dropFirst(4).split(separator: "-")
            guard let v = rest.first else { return model }
            return (["GPT-\(v)"] + rest.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() })
                .joined(separator: " ")
        }
        return model
    }
}

/// One thing that drove Claude Code's work — an MCP server, a skill or a
/// subagent type — with the share of Claude tokens spent in the session-hours
/// it was active. Shares overlap, so they do not sum to 100%.
struct Driver: Codable, Hashable, Identifiable {
    var id: String { "\(kind)|\(name)" }
    var name: String
    var kind: String               // "MCP", "Skill", "Subagent"
    var calls: Int
    var share: Double
}

struct Activity: Codable, Hashable {
    var generatedAt: TimeInterval
    var days: [DayUsage]           // last 30 days, oldest first
    var models: [ModelShare]       // last 7 days, largest first
    var claude24h: TokenBreakdown
    var codex24h: TokenBreakdown
    var drivers: [Driver]          // last 24h, most calls first
    var subagentShare: Double?     // of Claude tokens, last 24h
    var longContextShare: Double?  // of Claude tokens sent with >150k context, last 24h

    var copilot24h: TokenBreakdown? = nil

    var week: [DayUsage] { Array(days.suffix(7)) }
    var weekTotal: Double { week.reduce(0) { $0 + $1.total } }
    var monthTotal: Double { days.reduce(0) { $0 + $1.total } }
    /// Vendors with any tokens in `days`, in a stable order: the chart's series.
    var vendors: [Vendor] { Vendor.allCases.filter { v in days.contains { $0.tokens(v) > 0 } } }

    /// One concrete habit worth changing, picked from the strongest signal.
    var tip: String? {
        if let l = longContextShare, l >= 0.5 {
            return "\(Int((l * 100).rounded()))% of Claude tokens ran above 150k context. Long sessions cost more even when cached — /compact mid-task and start fresh when you switch tasks."
        }
        if let s = subagentShare, s >= 0.5 {
            return "Subagents drove \(Int((s * 100).rounded()))% of Claude tokens. Each one rebuilds its own context; fewer parallel agents stretch the limit further."
        }
        if let h = claude24h.cacheHit, h < 0.7, claude24h.requests > 20 {
            return "Only \(Int((h * 100).rounded()))% of prompt tokens came from cache. Long pauses let it expire, so the same context gets paid for again."
        }
        return nil
    }
}

extension Double {
    /// 28015593 → "28.0M", 11500 → "11.5k", 144 → "144".
    var compactTokens: String {
        switch abs(self) {
        case 1e9...: return String(format: "%.1fB", self / 1e9)
        case 1e6...: return String(format: "%.1fM", self / 1e6)
        case 1e4...: return String(format: "%.1fk", self / 1e3)
        default:     return String(Int(self.rounded()))
        }
    }
}
