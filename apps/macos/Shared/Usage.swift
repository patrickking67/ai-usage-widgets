import Foundation
import SwiftUI

// MARK: - Board: the one file the widget reads
//
// The menu-bar app (unsandboxed) collects from Claude Code and Codex and
// writes ~/.cache/tokenmeter/board.json (spec/board.md). The widget (sandboxed) only ever
// reads that file, so it never needs access to credentials or session logs.

/// One rate-limit window, normalised across vendors.
struct Meter: Codable, Hashable, Identifiable {
    var id: String { label }
    var label: String              // "Current", "Weekly"
    var used: Double               // 0…100
    var resetsAt: TimeInterval?    // unix seconds
    var windowSeconds: TimeInterval

    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: $0) } }

    /// A window whose reset time has passed is a fresh window, not a stuck one.
    func fraction(at now: Date) -> Double {
        if let r = resetDate, now >= r { return 0 }
        return min(max(used / 100, 0), 1)
    }

    func tint(at now: Date) -> Color {
        guard let r = resetDate else { return Palette.cyan }
        return Pace.tint(used: fraction(at: now) * 100, resetsAt: r, window: windowSeconds, now: now)
    }

    // MARK: Pace
    //
    // A bare percentage hides the question that matters: will this window
    // run out before it resets? These answer it from the rate so far.

    /// How far through the window we are, 0…1 — where even use would put the bar.
    func elapsedFraction(at now: Date) -> Double? {
        guard let r = resetDate, r > now, windowSeconds > 0 else { return nil }
        let elapsed = windowSeconds - r.timeIntervalSince(now)
        guard elapsed > 0 else { return nil }
        return min(elapsed / windowSeconds, 1)
    }

    /// The percentage at reset if the rate so far holds. Nil in the first 8%
    /// of a window, where one burst would project nonsense.
    func projectedAtReset(at now: Date) -> Double? {
        guard let e = elapsedFraction(at: now), e >= 0.08, used >= 1 else { return nil }
        return used / e
    }

    /// Used up: nothing left until the reset.
    func atLimit(at now: Date) -> Bool { fraction(at: now) >= 0.995 }

    /// "back in 4h 12m", or "back Tuesday" more than a day out.
    func backText(at now: Date) -> String? {
        guard let r = resetDate, r > now else { return nil }
        if r.timeIntervalSince(now) < 86_400 { return "back in \(r.countdown(from: now))" }
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return "back \(f.string(from: r))"
    }

    /// When this rate reaches 100%, if that lands before the reset.
    func limitDate(at now: Date) -> Date? {
        guard let r = resetDate, let e = elapsedFraction(at: now), e >= 0.08,
              used >= 1, used < 100 else { return nil }
        let perSecond = used / (e * windowSeconds)
        let hit = now.addingTimeInterval((100 - used) / perSecond)
        return hit < r ? hit : nil
    }

    /// What VoiceOver reads after the label: "38 percent used, resets in
    /// 4 hours 13 minutes, on pace for 64 percent".
    func spokenSummary(at now: Date) -> String {
        var parts = ["\(Int((fraction(at: now) * 100).rounded())) percent used"]
        if let r = resetDate, r > now {
            if windowSeconds <= 18_000 || r.timeIntervalSince(now) < 86_400 {
                parts.append("resets in \(Self.spokenDuration(r.timeIntervalSince(now)))")
            } else {
                let f = DateFormatter(); f.dateFormat = "EEEE"
                parts.append("resets \(f.string(from: r))")
            }
        } else if resetDate != nil {
            parts.append("fresh window")
        }
        if let hit = limitDate(at: now) {
            parts.append("at this rate the limit is reached in \(Self.spokenDuration(hit.timeIntervalSince(now)))")
        } else if let p = projectedAtReset(at: now) {
            parts.append("on pace for \(Int(p.rounded())) percent")
        }
        return parts.joined(separator: ", ")
    }

    /// "3 days 4 hours", "2 hours 13 minutes", "41 minutes", "less than a minute".
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let s = Int(max(seconds, 0))
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s")" }
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(unit(d, "day")) \(unit(h, "hour"))" : unit(d, "day") }
        if h > 0 { return m > 0 ? "\(unit(h, "hour")) \(unit(m, "minute"))" : unit(h, "hour") }
        return m > 0 ? unit(m, "minute") : "less than a minute"
    }

    func resetText(at now: Date) -> String {
        guard let r = resetDate, r > now else { return "Fresh Window" }
        if windowSeconds <= 18_000 || r.timeIntervalSince(now) < 86_400 {
            return "\(r.countdown(from: now)) Left"
        }
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return "Resets \(f.string(from: r))"
    }
}

enum Vendor: String, Codable, Hashable, CaseIterable {
    case claude, codex, copilot, cursor, grok

    var displayName: String {
        switch self {
        case .claude:  return "Claude"
        case .codex:   return "Codex"
        case .copilot: return "GitHub Copilot"
        case .cursor:  return "Cursor"
        case .grok:    return "Grok"
        }
    }
    /// Full-colour app icon, where one is bundled (widget, popover).
    var appIcon: String? {
        switch self { case .claude: "ClaudeApp"; case .codex: "CodexApp"; default: nil }
    }
    /// Template glyph cut from the app icon, for widgets drawn without colour.
    var glyph: String? {
        switch self { case .claude: "ClaudeGlyph"; case .codex: "CodexGlyph"; default: nil }
    }
    /// Monochrome template mark (menu bar).
    var mark: String? {
        switch self { case .claude: "ClaudeMark"; case .codex: "OpenAIMark"; default: nil }
    }
    /// Stand-in for vendors without bundled artwork: an SF Symbol on a tinted tile.
    var symbol: String {
        switch self {
        case .claude:  "asterisk"
        case .codex:   "terminal"
        case .copilot: "chevron.left.forwardslash.chevron.right"
        case .cursor:  "cursorarrow.rays"
        case .grok:    "sparkle"
        }
    }
    /// The vendor's own usage page, opened from the popover.
    var usageURL: URL {
        switch self {
        case .claude:  URL(string: "https://claude.ai/settings/usage")!
        case .codex:   URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .copilot: URL(string: "https://github.com/settings/copilot/features")!
        case .cursor:  URL(string: "https://cursor.com/dashboard?tab=usage")!
        case .grok:    URL(string: "https://grok.com")!
        }
    }
}

struct ProviderUsage: Codable, Hashable, Identifiable {
    var id: Vendor { vendor }
    var vendor: Vendor
    var account: String            // org name, or "Personal"
    var plan: String?              // "Team", "Max 5x", "Business"…
    var meters: [Meter]
    var updatedAt: TimeInterval?   // when the vendor last reported limits
    var extra: ExtraSpend? = nil   // pay-as-you-go spend, when switched on
    /// One line for lanes without a percentage: "1,894 credits this month · no cap".
    var note: String? = nil
    /// Data source not verified on real accounts; the card says so.
    var experimental: Bool? = nil
    /// Where the weekly window went, by surface: "Cowork 46%, Claude Code 34%".
    var breakdown: [Share]? = nil

    var updated: Date? { updatedAt.map { Date(timeIntervalSince1970: $0) } }

    /// "Acme · Business", or just the plan when there is no name.
    var accountLine: String {
        [account, plan].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Codex only reports during a session, so its figure can be days old.
    /// Past six hours the number is shown, but dimmed and labelled with its age.
    func isStale(at now: Date) -> Bool {
        guard let u = updated else { return true }
        return now.timeIntervalSince(u) > 6 * 3600
    }

    /// One lane for VoiceOver: "Claude, 37 percent used" from its hottest window.
    func spokenHottest(at now: Date) -> String {
        guard let m = hottest(at: now) else { return "\(vendor.displayName), no limits reported" }
        return "\(vendor.displayName), \(Int((m.fraction(at: now) * 100).rounded())) percent used"
    }

    /// The meter closest to its limit — what the menu bar shows.
    func hottest(at now: Date) -> Meter? {
        meters.max { $0.fraction(at: now) < $1.fraction(at: now) }
    }
}

/// One surface's share of a window, as the vendor reports it.
struct Share: Codable, Hashable, Identifiable {
    var id: String { label }
    var label: String
    var percent: Double
}

/// Claude extra usage: spend beyond the plan, in dollars.
struct ExtraSpend: Codable, Hashable {
    var used: Double
    var limit: Double?

    var fraction: Double? { limit.flatMap { $0 > 0 ? min(used / $0, 1) : nil } }

    var text: String {
        let used = Self.money(used)
        return limit.map { "\(used) of \(Self.money($0))" } ?? used
    }

    static func money(_ v: Double) -> String {
        v.rounded() == v ? "$\(Int(v))" : String(format: "$%.2f", v)
    }
}

struct UsageBoard: Codable, Hashable {
    var generatedAt: TimeInterval
    var providers: [ProviderUsage]
    var activity: Activity? = nil

    /// The app rewrites the board at least every five minutes while it runs,
    /// so an older one means it isn't running and every number is frozen.
    func isStale(at now: Date) -> Bool { now.timeIntervalSince1970 - generatedAt > 15 * 60 }

    static let placeholder: UsageBoard = {
        let now = Date().timeIntervalSince1970
        return UsageBoard(generatedAt: now, providers: [
            .init(vendor: .claude, account: "Personal", plan: "Max 5x", meters: [
                .init(label: "Current", used: 37, resetsAt: now + 14_400, windowSeconds: 18_000),
                .init(label: "Weekly", used: 38, resetsAt: now + 400_000, windowSeconds: 604_800)],
                  updatedAt: now),
            .init(vendor: .codex, account: "Personal", plan: "Plus", meters: [
                .init(label: "Weekly", used: 22, resetsAt: now + 300_000, windowSeconds: 604_800)],
                  updatedAt: now)])
    }()
}

enum UsageStore {
    /// The real home directory. Inside the widget's sandbox,
    /// `FileManager.homeDirectoryForCurrentUser` points into the container.
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var dir: URL { realHome.appendingPathComponent(".cache/tokenmeter", isDirectory: true) }
    static var boardURL: URL { dir.appendingPathComponent("board.json") }

    static func loadBoard() -> UsageBoard? {
        guard let data = try? Data(contentsOf: boardURL) else { return nil }
        return try? JSONDecoder().decode(UsageBoard.self, from: data)
    }

    static let refreshNotification = Notification.Name("com.patrickking.tokenmeter.refresh")
}

// MARK: - Presentation helpers

enum Palette {
    static let cyan  = Color(red: 0.49, green: 0.81, blue: 1.00)
    static let amber = Color(red: 0.88, green: 0.69, blue: 0.41)
    static let red   = Color(red: 0.97, green: 0.46, blue: 0.56)
    static let clay  = Color(red: 0.85, green: 0.47, blue: 0.34)

    static func vendor(_ v: Vendor) -> Color {
        switch v {
        case .claude:  clay
        case .codex:   Color(red: 0.30, green: 0.52, blue: 0.98)
        case .copilot: Color(red: 0.55, green: 0.36, blue: 0.96)
        case .cursor:  Color(red: 0.42, green: 0.45, blue: 0.50)
        case .grok:    Color(red: 0.20, green: 0.78, blue: 0.62)
        }
    }
}

/// Which lanes appear in the menu bar; all by default. Set in Settings.
enum MenuBarPrefs {
    /// "logo" (rings, the default) or "percent" (vendor marks and numbers).
    static let styleKey = "menuBar.style"
    static let logo = "logo"
    static func key(_ v: Vendor) -> String { "menuBar.\(v.rawValue)" }
    static func shows(_ v: Vendor) -> Bool {
        UserDefaults.standard.object(forKey: key(v)) as? Bool ?? true
    }
}

enum Pace {
    /// Colour by projection, not by the raw number: 60% used with ten minutes
    /// left is fine; 60% used ten minutes into a five-hour window is not.
    /// Mirrors pace_colour() in ~/.claude/statusline.sh.
    static func tint(used: Double, resetsAt: Date, window: TimeInterval, now: Date) -> Color {
        let left = max(resetsAt.timeIntervalSince(now), 0)
        let elapsed = max(window - left, 60)
        let projected = used * window / elapsed
        if used >= 90 || projected >= 130 { return Palette.red }
        if used >= 70 || projected >= 100 { return Palette.amber }
        return Palette.cyan
    }
}

extension Date {
    /// "2h 13m" / "41m" / "3d 4h" / "now"
    func countdown(from now: Date) -> String {
        let s = Int(max(timeIntervalSince(now), 0))
        if s < 60 { return "now" }
        let h = s / 3600, m = (s % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    func ago(from now: Date) -> String {
        let s = Int(now.timeIntervalSince(self))
        if s < 120 { return "Live" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }
}
