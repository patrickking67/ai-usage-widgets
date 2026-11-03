import Foundation

/// Claude Code. Two feeds, merged by recency:
///
/// - the status line's usage.json, written on every Claude Code turn — free
///   and instant, but only while a session is running, and not every window;
/// - Anthropic's usage endpoint (`ClaudeLive`), polled when the status line
///   has gone quiet — every window, including per-model ones, plus extra spend.
///
/// Plan and account come from `oauthAccount` in ~/.claude.json: profile
/// metadata, no secrets.
@MainActor
final class ClaudeSource: ProviderSource {
    let vendor = Vendor.claude
    private(set) var problem: String?
    var onUpdate: (() -> Void)?
    /// False for offscreen `--render`: no network.
    var interactive = true

    static let liveEnabledKey = "claudeLiveEnabled"
    private var liveEnabled: Bool { UserDefaults.standard.object(forKey: Self.liveEnabledKey) as? Bool ?? true }

    private var live: ClaudeLive.Snapshot?
    private var nextAttempt = Date.distantPast
    private var inFlight = false

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Local.home.appendingPathComponent(".claude.json").path)
    }

    /// The status line writes here. The legacy path is from before the
    /// rename and is still what older status-line scripts write.
    private var statusLineFeeds: [URL] {
        [UsageStore.dir.appendingPathComponent("usage.json"),
         Local.home.appendingPathComponent(".cache/claude-usage/usage.json")]
    }

    func refreshNow() {
        if problem != ClaudeLive.Failure.rateLimited.message { nextAttempt = .distantPast }
    }

    func usage(now: Date) -> ProviderUsage? {
        let acct = Local.json(Local.home.appendingPathComponent(".claude.json"))?["oauthAccount"] as? [String: Any]
        // Newest status-line feed wins.
        let usage = statusLineFeeds.compactMap { Local.json($0) }
            .max { (Local.number($0["updated_at"]) ?? 0) < (Local.number($1["updated_at"]) ?? 0) }
        guard acct != nil || usage != nil || live != nil else { return nil }

        var lineMeters: [Meter] = []
        for (key, label, span) in [("five_hour", "Current", 18_000.0), ("seven_day", "Weekly", 604_800.0)] {
            if let w = usage?[key] as? [String: Any], let used = Local.number(w["used_percentage"]) {
                lineMeters.append(Meter(label: label, used: used,
                                        resetsAt: Local.number(w["resets_at"]), windowSeconds: span))
            }
        }
        let lineAt = Local.number(usage?["updated_at"])

        let lineAge = now.timeIntervalSince1970 - (lineAt ?? 0)
        if lineAge > 180 || lineMeters.count < 2 { refreshLive() }

        var meters = lineMeters, updatedAt = lineAt, extra: ExtraSpend?
        if let live {
            extra = live.extra
            if live.fetchedAt >= (lineAt ?? 0) {
                meters = live.meters
                updatedAt = live.fetchedAt
            } else {
                let fresh = Set(lineMeters.map(\.label))
                meters = lineMeters + live.meters.filter { !fresh.contains($0.label) }
            }
        }

        let orgType = acct?["organizationType"] as? String ?? ""
        let isOrg = orgType.contains("team") || orgType.contains("enterprise")
        let account = Local.override("claudeAccountName")
            ?? (isOrg ? (acct?["organizationName"] as? String ?? "Organization") : "Personal")

        // Individual plans carry their tier on the org (`default_claude_max_20x`)
        // with `userRateLimitTier` null, so read both before falling back to
        // `organizationType` (`claude_max`, `claude_pro`).
        let tier = [acct?["userRateLimitTier"], acct?["organizationRateLimitTier"]]
            .compactMap { $0 as? String }.joined(separator: " ")
        let plan: String
        if orgType.contains("enterprise")      { plan = "Enterprise" }
        else if orgType.contains("team")       { plan = "Team" }
        else if tier.contains("max_20x")       { plan = "Max 20x" }
        else if tier.contains("max_5x")        { plan = "Max 5x" }
        else if tier.contains("max") || orgType.contains("max") { plan = "Max" }
        else if tier.contains("pro") || orgType.contains("pro") { plan = "Pro" }
        else                                   { plan = "Free" }

        return ProviderUsage(vendor: .claude, account: account, plan: plan,
                             meters: meters, updatedAt: updatedAt, extra: extra)
    }

    /// At most every three minutes; half an hour after a 429; hourly while
    /// Claude Code's own login is expired (it renews itself on its next run).
    private func refreshLive() {
        guard interactive, liveEnabled, !inFlight, Date() >= nextAttempt else { return }
        inFlight = true
        nextAttempt = Date().addingTimeInterval(180)
        Task { @MainActor in
            defer { inFlight = false }
            do {
                live = try await ClaudeLive.fetch()
                log.info("claude live: ok, \(self.live?.meters.count ?? 0, privacy: .public) windows")
                problem = nil
                onUpdate?()
            } catch let f as ClaudeLive.Failure {
                log.error("claude live: \(String(describing: f), privacy: .public)")
                problem = f.message
                if case .rateLimited = f { nextAttempt = Date().addingTimeInterval(1800) }
                if case .expired = f { nextAttempt = Date().addingTimeInterval(3600) }
                onUpdate?()
            } catch {
                log.error("claude live: \(error.localizedDescription, privacy: .public)")
                problem = nil   // offline: stay quiet, try again next round
            }
        }
    }
}
