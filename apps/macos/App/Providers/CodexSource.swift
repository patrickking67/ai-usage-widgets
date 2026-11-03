import Foundation

/// OpenAI Codex. Codex publishes no usage endpoint, but it records the
/// `rate_limits` object the API returned into its own session rollouts
/// (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl). Those are the API's own
/// figures, as fresh as the last Codex turn — hence the freshness badge.
///
/// Plan comes from the id_token in ~/.codex/auth.json, decoded locally. Its
/// `organizations` are OpenAI *API platform* orgs, not the ChatGPT workspace,
/// so their titles are never shown; the workspace name is not in the token
/// at all and comes from Settings.
@MainActor
final class CodexSource: ProviderSource {
    let vendor = Vendor.codex
    let problem: String? = nil
    var onUpdate: (() -> Void)?

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
        let account = Local.override("codexAccountName") ?? (isWorkspace ? "" : "Personal")

        var meters: [Meter] = []
        var updated: Double?
        if let (limits, mtime) = latestLimits(now: now) {
            updated = mtime
            for key in ["primary", "secondary"] {
                guard let w = limits[key] as? [String: Any], let used = Local.number(w["used_percent"]) else { continue }
                let minutes = Local.number(w["window_minutes"]) ?? 0
                let resets = Local.number(w["resets_at"]) ?? Local.number(w["resets_in_seconds"]).map { mtime + $0 }
                let label = minutes >= 10_000 ? "Weekly" : minutes <= 300 ? "Current" : "\(Int(minutes / 60))h"
                meters.append(Meter(label: label, used: used, resetsAt: resets, windowSeconds: minutes * 60))
            }
            meters.sort { $0.windowSeconds < $1.windowSeconds }
        }
        return ProviderUsage(vendor: .codex, account: account, plan: plan, meters: meters, updatedAt: updated)
    }

    static func planName(_ raw: String) -> String? {
        if raw.isEmpty { return nil }
        for (needle, name) in [("enterprise", "Enterprise"), ("business", "Business"), ("team", "Team"),
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
            guard let tail = Local.readTail(file, bytes: 768 * 1024) else { continue }
            for line in tail.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let limits = Local.findKey("rate_limits", in: obj) as? [String: Any],
                      limits["primary"] is [String: Any] else { continue }
                return (limits, mtime.timeIntervalSince1970)
            }
        }
        return nil
    }
}
