import Foundation

/// Reads Claude plan limits straight from Anthropic, for when the status line
/// has gone quiet (no Claude Code session running) or reports only some windows.
///
/// The token is Claude Code's own, read from its Keychain item and never
/// written, refreshed or stored. Refreshing it from a second process would
/// rotate the grant and sign every Claude Code session out, so an expired
/// token is simply skipped until Claude Code renews it itself.
///
/// Without the `claude-code` user agent this endpoint answers 429, which
/// looks like a real rate limit and is not.
enum ClaudeLive {
    struct Snapshot {
        var meters: [Meter]
        var extra: ExtraSpend?
        var breakdown: [Share] = []
        var fetchedAt: TimeInterval
    }

    /// Who the token actually belongs to. `~/.claude.json` keeps the last
    /// profile Claude Code cached, which goes stale after switching accounts;
    /// this is the account the limits above are for.
    struct Profile {
        var account: String     // org name, or "Personal"
        var plan: String        // "Ultra", "Max 20x", "Team"…
    }

    enum Failure: Error {
        case noToken, denied, expired, unauthorized, rateLimited, badResponse(Int)

        var message: String {
            switch self {
            case .noToken:        return "Sign in to Claude Code to read limits directly."
            case .denied:         return "Keychain access refused."
            case .expired:        return "Waiting for Claude Code to renew its sign-in."
            case .unauthorized:   return "Claude rejected the token — open Claude Code to sign in again."
            case .rateLimited:    return "Claude usage endpoint is rate limiting; retrying later."
            case .badResponse(let s): return "Claude usage endpoint returned \(s)."
            }
        }
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    static func fetch() async throws -> Snapshot {
        decode(try await get(endpoint))
    }

    static func fetchProfile() async throws -> Profile {
        let root = try await get(profileEndpoint)
        let org = root["organization"] as? [String: Any] ?? [:]
        let type = org["organization_type"] as? String ?? ""
        let isOrg = type.contains("team") || type.contains("enterprise")
        let shown = (org["plan_display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Profile(account: isOrg ? (org["name"] as? String ?? "Organization") : "Personal",
                       plan: shown ?? ClaudeSource.planName(orgType: type, tier: org["rate_limit_tier"] as? String ?? ""))
    }

    private static func get(_ url: URL) async throws -> [String: Any] {
        let token = try await Task.detached(priority: .utility) { try readToken() }.value

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.1.316", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if status != 200 {
            // The error body names the reason (e.g. a missing scope); no secrets in it.
            let body = String(decoding: data.prefix(400), as: UTF8.self)
            log.error("live: HTTP \(status, privacy: .public): \(body, privacy: .public)")
        }
        switch status {
        case 200: break
        case 401, 403: throw Failure.unauthorized
        case 429: throw Failure.rateLimited
        default: throw Failure.badResponse(status)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badResponse(status)
        }
        return root
    }

    /// `limits` is the list the Claude app itself draws: named windows with
    /// model or surface scopes. When it is there it wins, and the top-level
    /// codename objects (`iguana_necktie`…) are ignored, since they are
    /// internal pools rather than plan windows.
    static func decode(_ root: [String: Any]) -> Snapshot {
        var snapshot = legacyDecode(root)
        if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
            var rows: [(Int, Int, Meter)] = []
            for (i, l) in limits.enumerated() {
                guard let pct = number(l["percent"]) else { continue }
                let group = (l["group"] as? String ?? "").lowercased()
                let kind = (l["kind"] as? String ?? "").lowercased()
                let weekly = group.contains("week") || kind.contains("week")
                let session = group.contains("session") || group.contains("five") || kind.contains("five")
                var label = weekly ? "Weekly" : session ? "Current"
                    : (group.isEmpty ? kind : group).replacingOccurrences(of: "_", with: " ").capitalized
                let scope = l["scope"] as? [String: Any]
                let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
                if let s = model ?? surface { label += " · \(s)" }
                let order = (weekly ? 10 : 0) + (scope == nil ? 0 : 1)
                rows.append((order, i, Meter(label: label, used: pct,
                                             resetsAt: date(l["resets_at"])?.timeIntervalSince1970,
                                             windowSeconds: weekly ? 604_800 : 18_000)))
            }
            if !rows.isEmpty {
                rows.sort { ($0.0, $0.1) < ($1.0, $1.1) }
                snapshot.meters = rows.map(\.2)
            }
        }
        if let rows = (root["seven_day_breakdown"] as? [String: Any])?["rows"] as? [[String: Any]] {
            snapshot.breakdown = rows.compactMap { r in
                guard let p = number(r["percent"]), p > 0, let name = r["display_name"] as? String else { return nil }
                return Share(label: name, percent: p)
            }.sorted { $0.percent > $1.percent }
        }
        return snapshot
    }

    /// Before `limits`: any top-level object with a `utilization` is a window,
    /// so a window Anthropic adds later still shows up.
    private static func legacyDecode(_ root: [String: Any]) -> Snapshot {
        let known: [String: (label: String, span: TimeInterval, order: Int)] = [
            "five_hour": ("Current", 18_000, 0),
            "seven_day": ("Weekly", 604_800, 1),
            "seven_day_opus": ("Weekly · Opus", 604_800, 2),
            "seven_day_sonnet": ("Weekly · Sonnet", 604_800, 3),
        ]
        var rows: [(Int, String, Meter)] = []
        var extra: ExtraSpend?

        for (key, value) in root {
            guard let obj = value as? [String: Any] else { continue }
            if key == "extra_usage" {
                if obj["is_enabled"] as? Bool == true, let used = number(obj["used_credits"]) {
                    extra = ExtraSpend(used: used, limit: number(obj["monthly_limit"]))
                }
                continue
            }
            guard let used = number(obj["utilization"]) else { continue }
            if known[key] == nil { log.info("live: unnamed window \(key, privacy: .public)") }
            let k = known[key] ?? (key.replacingOccurrences(of: "_", with: " ").capitalized,
                                   key.hasPrefix("five") ? 18_000 : 604_800, 9)
            rows.append((k.order, key, Meter(label: k.label, used: used,
                                             resetsAt: date(obj["resets_at"])?.timeIntervalSince1970,
                                             windowSeconds: k.span)))
        }
        rows.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        return Snapshot(meters: rows.map(\.2), extra: extra, fetchedAt: Date().timeIntervalSince1970)
    }

    // MARK: Token (read only)
    //
    // WHY /usr/bin/security AND NOT SecItemCopyMatching
    //
    // Claude Code stores and reads its "Claude Code-credentials" item through
    // Apple's `security` tool, so that tool is what the item's access list
    // trusts. Reading it with SecItemCopyMatching from this app raises a
    // Keychain prompt, and the grant does not survive Claude Code updating the
    // item after each token refresh. Asking the same trusted tool Claude Code
    // uses reads it with no prompt at all.
    //
    // A `claude setup-token` token is no substitute: it is inference-only, and
    // the usage endpoint requires the `user:profile` scope.
    //
    // Nothing here writes, refreshes or stores the token.

    private static func readToken() throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-a", NSUserName(), "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { throw Failure.noToken }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw Failure.noToken }

        // `security -w` prints the secret as text, or as hex when it holds
        // bytes it will not print raw.
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = raw.hasPrefix("{") ? Data(raw.utf8) : hexData(raw)
        guard let bytes,
              let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { throw Failure.noToken }
        if let exp = number(oauth["expiresAt"]), exp / 1000 < Date().timeIntervalSince1970 {
            throw Failure.expired
        }
        return token
    }

    private static func hexData(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var d = Data(capacity: s.count / 2), i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        return d
    }

    // MARK: helpers

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
