import Foundation

/// Claude Code. Two feeds, merged by recency:
///
/// - the status line's usage.json, written on every Claude Code turn — free
///   and instant, but only while a session is running, and not every window;
/// - Anthropic's usage endpoint (`ClaudeLive`), polled when the status line
///   has gone quiet — every window, including per-model ones, plus extra spend.
///
/// Plan and account come from Anthropic's profile endpoint, for the same token
/// the limits are read with. `oauthAccount` in ~/.claude.json is only the
/// fallback: it is a cache that keeps the previous account after a switch.
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
    private var profile: ClaudeLive.Profile?
    private var nextAttempt = Date.distantPast
    private var nextProfile = Date.distantPast
    private var lastFetch = Date.distantPast
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

    /// Twenty seconds apart at most, so opening the popover repeatedly
    /// can't hammer the endpoint.
    func refreshNow() {
        guard problem != ClaudeLive.Failure.rateLimited.message else { return }
        nextAttempt = max(lastFetch.addingTimeInterval(20), .now)
        nextProfile = .distantPast
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

        // The status line can't see the model-scoped windows or the breakdown,
        // so the endpoint is polled even while it is fresh.
        refreshLive()

        var meters = lineMeters, updatedAt = lineAt, extra: ExtraSpend?, breakdown: [Share]?
        if let live {
            extra = live.extra
            breakdown = live.breakdown.isEmpty ? nil : live.breakdown
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
        let account = Local.override("claudeAccountName") ?? profile?.account
            ?? (isOrg ? (acct?["organizationName"] as? String ?? "Organization") : "Personal")
        // Individual plans carry their tier on the org (`default_claude_max_20x`)
        // with `userRateLimitTier` null, so read both.
        let tier = [acct?["userRateLimitTier"], acct?["organizationRateLimitTier"]]
            .compactMap { $0 as? String }.joined(separator: " ")
        let plan = profile?.plan ?? Self.planName(orgType: orgType, tier: tier)

        return ProviderUsage(vendor: .claude, account: account, plan: plan,
                             meters: meters, updatedAt: updatedAt, extra: extra, breakdown: breakdown)
    }

    /// From `organization_type` (`claude_team`, `claude_max`) and the rate
    /// tier, for when the profile has no display name of its own.
    nonisolated static func planName(orgType: String, tier: String) -> String {
        if orgType.contains("enterprise") { return "Enterprise" }
        if orgType.contains("team")       { return "Team" }
        if tier.contains("max_20x")       { return "Max 20x" }
        if tier.contains("max_5x")        { return "Max 5x" }
        if tier.contains("max") || orgType.contains("max") { return "Max" }
        if tier.contains("pro") || orgType.contains("pro") { return "Pro" }
        return "Free"
    }

    /// Every 60 seconds (the call takes about 0.3s); the profile hourly; half
    /// an hour after a 429; hourly while Claude Code's own login is expired
    /// (it renews itself on its next run).
    private func refreshLive() {
        guard interactive, liveEnabled, !inFlight, Date() >= nextAttempt else { return }
        inFlight = true
        nextAttempt = Date().addingTimeInterval(60)
        let wantsProfile = Date() >= nextProfile
        Task { @MainActor in
            defer { inFlight = false }
            do {
                if wantsProfile {
                    async let p = ClaudeLive.fetchProfile()
                    live = try await ClaudeLive.fetch()
                    if let p = try? await p { profile = p; nextProfile = Date().addingTimeInterval(3600) }
                } else {
                    live = try await ClaudeLive.fetch()
                }
                lastFetch = Date()
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
