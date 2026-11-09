import Foundation

/// OpenAI Codex. Two feeds, newest wins:
///
/// - `chatgpt.com/backend-api/wham/usage`, the endpoint Codex's own `/status`
///   reads, with the access token from ~/.codex/auth.json. Read only: never
///   refreshed or stored; an expired token waits for Codex to renew it.
/// - the `rate_limits` Codex records into its session rollouts
///   (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl), as fresh as the last
///   Codex turn — the fallback when the endpoint can't be reached.
///
/// Plan comes from the id_token in ~/.codex/auth.json, decoded locally. Its
/// `organizations` are OpenAI *API platform* orgs, not the ChatGPT workspace,
/// so their titles are never shown; the workspace name is not in the token
/// at all and comes from Settings.
@MainActor
final class CodexSource: ProviderSource {
    let vendor = Vendor.codex
    private(set) var problem: String?
    var onUpdate: (() -> Void)?
    /// False for offscreen `--render`: no network.
    var interactive = true

    private struct Live { var plan: String; var meters: [Meter]; var fetchedAt: TimeInterval }
    private var live: Live?
    private var nextAttempt = Date.distantPast
    private var lastFetch = Date.distantPast
    /// The ChatGPT workspace's own name, asked for hourly; the token doesn't carry it.
    private var workspace: String?
    private var nextWorkspace = Date.distantPast
    private var inFlight = false

    func refreshNow() { nextAttempt = max(lastFetch.addingTimeInterval(20), .now) }

    private var dir: URL { Local.home.appendingPathComponent(".codex") }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: dir.path) }

    func usage(now: Date) -> ProviderUsage? {
        guard isInstalled else { return nil }

        var isWorkspace = false, plan: String? = nil
        if let auth = Local.json(dir.appendingPathComponent("auth.json")),
           let tokens = auth["tokens"] as? [String: Any],
           let idToken = tokens["id_token"] as? String,
           let claims = Local.jwtClaims(idToken)?["https://api.openai.com/auth"] as? [String: Any] {
            let raw = claims["chatgpt_plan_type"] as? String ?? ""
            plan = Self.planName(raw)
            isWorkspace = ["business", "team", "enterprise", "edu"].contains(where: raw.contains)
        }

        refreshLive()
        var meters: [Meter] = []
        var updated: Double?
        let rollout = latestLimits(now: now)
        if let live, live.fetchedAt >= (rollout?.1 ?? 0) {
            plan = Self.planName(live.plan) ?? plan
            isWorkspace = ["business", "team", "enterprise", "edu"].contains(where: live.plan.contains)
            meters = live.meters
            updated = live.fetchedAt
        } else if let (limits, mtime) = rollout {
            updated = mtime
            meters = Self.rolloutMeters(limits, mtime: mtime)
        }
        let account = Local.override("codexAccountName") ?? (isWorkspace ? (workspace ?? "") : "Personal")
        return ProviderUsage(vendor: .codex, account: account, plan: plan, meters: meters, updatedAt: updated)
    }

    nonisolated static func label(windowSeconds s: Double) -> String {
        s >= 600_000 ? "Weekly" : s <= 18_000 ? "Current" : "\(Int(s / 3600))h"
    }

    /// Every 60 seconds; hourly while the token is expired or refused.
    private func refreshLive() {
        guard interactive, !inFlight, Date() >= nextAttempt,
              let tokens = Local.json(dir.appendingPathComponent("auth.json"))?["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return }
        inFlight = true
        nextAttempt = Date().addingTimeInterval(60)
        let accountID = tokens["account_id"] as? String
        let wantsWorkspace = Date() >= nextWorkspace
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let acct = tokens["account_id"] as? String { req.setValue(acct, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.setValue("codex_cli_rs/0.166.0", forHTTPHeaderField: "User-Agent")
        Task { @MainActor in
            defer { inFlight = false }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard status == 200, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    log.error("codex live: HTTP \(status, privacy: .public)")
                    if status == 401 || status == 403 {
                        problem = "Waiting for Codex to renew its sign-in; showing its last session."
                        nextAttempt = Date().addingTimeInterval(3600)
                    }
                    onUpdate?(); return
                }
                let decoded = Self.decodeLive(root)
                if wantsWorkspace {
                    var w = req
                    w.url = URL(string: "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27")
                    if let (d, r) = try? await URLSession.shared.data(for: w), (r as? HTTPURLResponse)?.statusCode == 200,
                       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        workspace = Self.workspaceName(o, accountID: accountID)
                        nextWorkspace = Date().addingTimeInterval(3600)
                    }
                }
                lastFetch = Date()
                live = Live(plan: decoded.plan, meters: decoded.meters, fetchedAt: lastFetch.timeIntervalSince1970)
                problem = nil
                onUpdate?()
            } catch {
                log.error("codex live: \(error.localizedDescription, privacy: .public)")   // offline: try next round
            }
        }
    }

    /// The selected workspace's name from `accounts/check`; nil for a personal
    /// account or one without a name.
    nonisolated static func workspaceName(_ root: [String: Any], accountID: String?) -> String? {
        guard let id = accountID,
              let acct = ((root["accounts"] as? [String: Any])?[id] as? [String: Any])?["account"] as? [String: Any],
              acct["structure"] as? String == "workspace",
              let name = (acct["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return name
    }

    /// The `wham/usage` response: `plan_type` and up to two windows under
    /// `rate_limit`, shortest first.
    nonisolated static func decodeLive(_ root: [String: Any]) -> (plan: String, meters: [Meter]) {
        var meters: [Meter] = []
        let rl = root["rate_limit"] as? [String: Any]
        for key in ["primary_window", "secondary_window"] {
            guard let w = rl?[key] as? [String: Any], let used = Local.number(w["used_percent"]) else { continue }
            let span = Local.number(w["limit_window_seconds"]) ?? 0
            meters.append(Meter(label: label(windowSeconds: span), used: used,
                                resetsAt: Local.number(w["reset_at"]), windowSeconds: span))
        }
        meters.sort { $0.windowSeconds < $1.windowSeconds }
        return (root["plan_type"] as? String ?? "", meters)
    }

    /// A rollout's `rate_limits` object. `resets_at` is absolute; older
    /// Codex builds wrote `resets_in_seconds`, relative to the file's mtime.
    nonisolated static func rolloutMeters(_ limits: [String: Any], mtime: Double) -> [Meter] {
        var meters: [Meter] = []
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any], let used = Local.number(w["used_percent"]) else { continue }
            let minutes = Local.number(w["window_minutes"]) ?? 0
            let resets = Local.number(w["resets_at"]) ?? Local.number(w["resets_in_seconds"]).map { mtime + $0 }
            meters.append(Meter(label: label(windowSeconds: minutes * 60), used: used,
                                resetsAt: resets, windowSeconds: minutes * 60))
        }
        return meters.sorted { $0.windowSeconds < $1.windowSeconds }
    }

    nonisolated static func planName(_ raw: String) -> String? {
        if raw.isEmpty { return nil }
        for (needle, name) in [("promax", "Pro Max"), ("enterprise", "Enterprise"), ("business", "Business"), ("team", "Team"),
                               ("edu", "Edu"), ("pro", "Pro"), ("plus", "Plus"), ("free", "Free")]
        where raw.contains(needle) { return name }
        return raw.capitalized
    }

    /// Newest rollouts from the last eight day-directories, then the last line
    /// carrying a non-null `primary` window. Some turns log `rate_limits: null`,
    /// so up to five files are tried.
    private func latestLimits(now: Date) -> ([String: Any], Double)? {
        let fm = FileManager.default, cal = Calendar.current
        let sessions = dir.appendingPathComponent("sessions")
        var candidates: [(URL, Date)] = []
        for back in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let d = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            guard let files = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                candidates.append((f, m))
            }
        }
        for (file, mtime) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(5) {
            guard let tail = Local.readTail(file, bytes: 768 * 1024),
                  let limits = Self.lastLimits(inRollout: tail) else { continue }
            return (limits, mtime.timeIntervalSince1970)
        }
        return nil
    }

    /// The last `rate_limits` object in a rollout's text with a non-null
    /// `primary` window. Lines that do not parse (a tail cut mid-line) are skipped.
    nonisolated static func lastLimits(inRollout text: String) -> [String: Any]? {
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let limits = Local.findKey("rate_limits", in: obj) as? [String: Any],
                  limits["primary"] is [String: Any] else { continue }
            return limits
        }
        return nil
    }
}
