import Foundation
import SQLite3

/// Cursor. Its sign-in lives in Cursor's own settings database
/// (globalStorage/state.vscdb, key `cursorAuth/accessToken`), opened here
/// read-only. The dashboard's `usage-summary` endpoint takes that token as the
/// web session cookie and reports the month's included-usage pool as a
/// percentage, plus on-demand spend in cents.
///
/// Undocumented and unverified on a real account from here: marked experimental.
@MainActor
final class CursorSource: ProviderSource {
    let vendor = Vendor.cursor
    var onUpdate: (() -> Void)?
    var interactive = true
    private let lane = RemoteLane(name: "cursor")
    var problem: String? { lane.problem }

    nonisolated private static var db: URL {
        UsageStore.realHome.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: Self.db.path) }

    func refreshNow() { lane.refreshNow() }

    func usage(now: Date) -> ProviderUsage? {
        guard isInstalled else { return nil }
        lane.poll(interactive: interactive, onUpdate: onUpdate) {
            guard let token = Self.readKey("cursorAuth/accessToken"),
                  let sub = Local.jwtClaims(token)?["sub"] as? String else {
                throw LaneError(message: "Sign in to Cursor to show its usage.", retryAfter: 3600)
            }
            // `sub` is "auth0|user_…"; the cookie wants the part after the pipe.
            let user = sub.split(separator: "|").last.map(String.init) ?? sub
            var req = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!, timeoutInterval: 20)
            req.setValue("WorkosCursorSessionToken=\(user)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let root = try await Local.getJSON(req, vendor: "Cursor")
            let hint = Self.readKey("cursorAuth/stripeMembershipType")
            return await Self.decode(root, planHint: hint, override: Local.override("cursorAccountName"))
        }
        return lane.snapshot
    }

    nonisolated static func decode(_ root: [String: Any], planHint: String?, override: String?) -> ProviderUsage {
        let membership = root["membershipType"] as? String ?? planHint
        let plan = membership.map { m -> String in
            switch m {
            case "pro_plus": "Pro+"
            case "ultra": "Ultra"
            default: m.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
        let isTeam = (root["limitType"] as? String) == "team"
        let individual = root["individualUsage"] as? [String: Any]
        let start = Local.time(root["billingCycleStart"]), end = Local.time(root["billingCycleEnd"])

        var meters: [Meter] = []
        var note: String?
        if root["isUnlimited"] as? Bool == true {
            note = "Unlimited plan"
        } else if let planUsage = individual?["plan"] as? [String: Any],
                  let pct = Local.number(planUsage["totalPercentUsed"])
                    ?? { () -> Double? in
                        guard let u = Local.number(planUsage["used"]), let l = Local.number(planUsage["limit"]), l > 0 else { return nil }
                        return u / l * 100
                    }() {
            // Either end of the cycle can be missing; fall back to a month.
            let span = start.flatMap { s in end.map { $0 - s } }.flatMap { $0 > 0 ? $0 : nil } ?? 30 * 86_400
            meters.append(Meter(label: "Monthly", used: pct, resetsAt: end, windowSeconds: span))
        }
        let onDemand = (individual?["onDemand"] as? [String: Any])
            ?? ((root["teamUsage"] as? [String: Any])?["onDemand"] as? [String: Any])
        var extra: ExtraSpend?
        if let od = onDemand, od["enabled"] as? Bool != false, let used = Local.number(od["used"]), used > 0 {
            extra = ExtraSpend(used: used / 100, limit: Local.number(od["limit"]).map { $0 / 100 })
        }
        return ProviderUsage(vendor: .cursor, account: override ?? (isTeam ? "Team" : "Personal"), plan: plan,
                             meters: meters, updatedAt: Date().timeIntervalSince1970, extra: extra,
                             note: note, experimental: true)
    }

    /// One value from Cursor's ItemTable, opened read-only (WAL-safe).
    nonisolated static func readKey(_ key: String) -> String? {
        var handle: OpaquePointer?
        let uri = "file:\(db.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? db.path)?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle); return nil
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 500)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT value FROM ItemTable WHERE key = ?1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        var v = String(cString: c)
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }   // JSON-quoted
        return v.isEmpty ? nil : v
    }
}
