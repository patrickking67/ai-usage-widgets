import Foundation

/// Grok, through xAI's Grok Build CLI (`grok`) and its SuperGrok pool. The
/// CLI keeps its sign-in in ~/.grok/auth.json; this reads it (never writes or
/// refreshes it — `grok` rotates it under a file lock) and asks the same
/// billing endpoint `grok` calls for `/usage`.
///
/// Verified against xAI's CLI source, not a live account: experimental.
@MainActor
final class GrokSource: ProviderSource {
    let vendor = Vendor.grok
    var onUpdate: (() -> Void)?
    var interactive = true
    private let lane = RemoteLane(name: "grok")
    var problem: String? { lane.problem }

    nonisolated private static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["GROK_HOME"] { return URL(fileURLWithPath: custom) }
        return UsageStore.realHome.appendingPathComponent(".grok")
    }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: Self.home.appendingPathComponent("auth.json").path) }

    func refreshNow() { lane.refreshNow() }

    func usage(now: Date) -> ProviderUsage? {
        guard isInstalled else { return nil }
        lane.poll(interactive: interactive, onUpdate: onUpdate) {
            guard let cred = Self.credential(), let key = cred["key"] as? String, !key.isEmpty else {
                throw LaneError(message: "Run `grok login` to show SuperGrok usage.", retryAfter: 3600)
            }
            if let exp = Local.time(cred["expires_at"]), exp < Date().timeIntervalSince1970 {
                throw LaneError(message: "Waiting for grok to renew its sign-in.", retryAfter: 3600)
            }
            func request(_ path: String) -> URLRequest {
                var r = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com\(path)")!, timeoutInterval: 20)
                r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                r.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
                if let uid = cred["user_id"] as? String { r.setValue(uid, forHTTPHeaderField: "x-userid") }
                r.setValue("1.0.0", forHTTPHeaderField: "x-grok-client-version")
                r.setValue("application/json", forHTTPHeaderField: "Accept")
                return r
            }
            let billing = try await Local.getJSON(request("/v1/billing?format=credits"), vendor: "Grok")
            let settings = try? await Local.getJSON(request("/v1/settings"), vendor: "Grok")
            return await Self.decode(billing: billing, settings: settings,
                                     team: cred["team_name"] as? String,
                                     override: Local.override("grokAccountName"))
        }
        return lane.snapshot
    }

    /// SuperGrok OIDC first, then the legacy sign-in; never the plain API key.
    nonisolated private static func credential() -> [String: Any]? {
        guard let all = Local.json(home.appendingPathComponent("auth.json")) else { return nil }
        for prefix in ["https://auth.x.ai::", "https://accounts.x.ai/sign-in"] {
            if let hit = all.first(where: { $0.key.hasPrefix(prefix) })?.value as? [String: Any] { return hit }
        }
        return nil
    }

    nonisolated static func decode(billing: [String: Any], settings: [String: Any]?,
                                   team: String?, override: String?) -> ProviderUsage {
        let config = billing["config"] as? [String: Any] ?? billing
        func cents(_ k: String) -> Double? {
            guard let o = config[k] as? [String: Any] else { return nil }
            return (Local.number(o["val"]) ?? 0) / 100     // proto3 omits zeros
        }
        var used = Local.number(config["creditUsagePercent"])
        if used == nil, let u = cents("used"), let l = cents("monthlyLimit"), l > 0 { used = u / l * 100 }

        let period = config["currentPeriod"] as? [String: Any]
        let weekly = (period?["type"] as? String)?.contains("WEEKLY") == true
        let start = Local.time(period?["start"] ?? config["billingPeriodStart"])
        let end = Local.time(period?["end"] ?? config["billingPeriodEnd"])
        let window = (start != nil && end != nil && end! > start!) ? end! - start! : (weekly ? 604_800 : 30 * 86_400)

        var meters: [Meter] = []
        if let used {    // unknown is not 0%: no figure, no meter
            meters.append(Meter(label: weekly ? "Weekly" : "Monthly", used: used, resetsAt: end, windowSeconds: window))
        }
        var extra: ExtraSpend?
        if let cap = cents("onDemandCap"), cap > 0 { extra = ExtraSpend(used: cents("onDemandUsed") ?? 0, limit: cap) }

        let plan = settings?["subscription_tier_display"] as? String
            ?? config["subscriptionTier"] as? String ?? "SuperGrok"
        return ProviderUsage(vendor: .grok, account: override ?? team ?? "Personal", plan: plan,
                             meters: meters, updatedAt: Date().timeIntervalSince1970, extra: extra,
                             experimental: true)
    }
}
