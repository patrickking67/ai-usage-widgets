import Foundation

/// GitHub Copilot, including VS Code agent mode.
///
/// Limits come from `GET /copilot_internal/user`, the endpoint Copilot's own
/// editor extensions poll. It accepts the GitHub CLI's login, so this asks
/// `gh` to make the request: the token stays inside gh and is never seen,
/// stored or logged here. No gh, or not signed in: the lane stays hidden.
///
/// Seats come in two shapes. Metered seats have a monthly premium-request
/// allowance (`premium_interactions.percent_remaining`), shown as a meter
/// that resets on `quota_reset_date`. Business/Enterprise seats billed by
/// usage report `unlimited: true` with a running `credits_used` instead —
/// nothing to run out of, so that becomes the card's note, not a bar.
@MainActor
final class CopilotSource: ProviderSource {
    let vendor = Vendor.copilot
    private(set) var problem: String?
    var onUpdate: (() -> Void)?
    var interactive = true

    private var snapshot: ProviderUsage?
    private var nextAttempt = Date.distantPast
    private var inFlight = false

    /// Where gh is installed by Homebrew, the system, and the user-level
    /// managers (pixi, Nix, `~/.local/bin`). A GUI app gets launchd's bare
    /// PATH, so these are looked up directly rather than through PATH.
    nonisolated static func ghCandidates(home: String) -> [String] {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh",
         "\(home)/.pixi/bin/gh", "\(home)/.local/bin/gh", "\(home)/.nix-profile/bin/gh",
         "/run/current-system/sw/bin/gh"]
    }
    private var gh: String? {
        Self.ghCandidates(home: UsageStore.realHome.path).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isInstalled: Bool { gh != nil }

    func refreshNow() { nextAttempt = .distantPast }

    func usage(now: Date) -> ProviderUsage? {
        if !interactive, snapshot == nil, let gh, case .success(let json) = Self.fetch(gh: gh) {
            // --render: one synchronous read so the preview has the lane.
            snapshot = Self.decode(json, override: Local.override("copilotAccountName"))
        }
        refresh()
        return snapshot
    }

    /// Every ten minutes: the allowance is monthly, so nothing moves faster.
    private func refresh() {
        guard interactive, let gh, !inFlight, Date() >= nextAttempt else { return }
        inFlight = true
        nextAttempt = Date().addingTimeInterval(600)
        Task { @MainActor in
            defer { inFlight = false }
            let result = await Task.detached(priority: .utility) { Self.fetch(gh: gh) }.value
            switch result {
            case .success(let json):
                snapshot = Self.decode(json, override: Local.override("copilotAccountName"))
                problem = nil
            case .failure(let message):
                log.error("copilot: \(message, privacy: .public)")
                problem = snapshot == nil ? nil : message   // never set up: stay hidden, not red
                nextAttempt = Date().addingTimeInterval(1800)
            }
            onUpdate?()
        }
    }

    enum FetchResult { case success([String: Any]), failure(String) }

    nonisolated static func fetch(gh: String) -> FetchResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gh)
        proc.arguments = ["api", "/copilot_internal/user"]
        // A GUI app has launchd's bare PATH; gh wants a HOME for its config.
        let dir = (gh as NSString).deletingLastPathComponent
        proc.environment = ["HOME": UsageStore.realHome.path, "PATH": "\(dir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                            "GH_PROMPT_DISABLED": "1", "NO_COLOR": "1"]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out; proc.standardError = err
        do { try proc.run() } catch { return .failure("gh could not start") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let why = String(decoding: err.fileHandleForReading.readDataToEndOfFile().prefix(200), as: UTF8.self)
            return .failure("gh api exited \(proc.terminationStatus): \(why)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure("unreadable response")
        }
        return .success(json)
    }

    nonisolated static func decode(_ root: [String: Any], override: String?, now: Date = Date()) -> ProviderUsage {
        let plan = (root["copilot_plan"] as? String).map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
        let orgs = root["organization_login_list"] as? [String] ?? []
        let account = override ?? orgs.first ?? ((root["enterprise_list"] as? [Any])?.isEmpty == false ? "" : "Personal")

        var meters: [Meter] = []
        var note: String?
        let premium = (root["quota_snapshots"] as? [String: Any])?["premium_interactions"] as? [String: Any]
        let resetAt = (root["quota_reset_date"] as? String).flatMap(Self.day)
        if let p = premium {
            if p["unlimited"] as? Bool == true {
                let credits = Local.number(p["credits_used"]) ?? 0
                note = "\(Self.grouped(credits)) premium credits this month · no cap"
            } else if let left = Local.number(p["percent_remaining"]) {
                let entitlement = Local.number(p["entitlement"]) ?? 0
                meters.append(Meter(label: entitlement > 0 ? "Premium · \(Int(entitlement))/mo" : "Premium requests",
                                    used: max(0, min(100, 100 - left)),
                                    resetsAt: resetAt?.timeIntervalSince1970,
                                    windowSeconds: 30 * 86_400))
                if p["overage_permitted"] as? Bool == true, let over = Local.number(p["overage_count"]), over > 0 {
                    note = "\(Self.grouped(over)) requests over the allowance"
                }
            }
        }
        let stamp = (premium?["timestamp_utc"] as? String).flatMap { ISO8601DateFormatter.lenient($0) }
        return ProviderUsage(vendor: .copilot, account: account, plan: plan, meters: meters,
                             updatedAt: (stamp ?? now).timeIntervalSince1970, note: note)
    }

    /// "2026-10-01" → local midnight that day.
    nonisolated private static func day(_ s: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.date(from: s)
    }

    nonisolated private static func grouped(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? String(Int(v))
    }
}

extension ISO8601DateFormatter {
    /// With or without fractional seconds.
    static func lenient(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
