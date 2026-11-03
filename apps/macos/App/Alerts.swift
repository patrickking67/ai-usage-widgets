import Foundation
import UserNotifications

/// Notifies at 80% and 95% of a window, and again when a window that was
/// nearly spent resets — the moment you can go back to work.
///
/// Each alert is keyed to one window instance (vendor, meter, reset time), so
/// it fires once per window rather than every 20 seconds, and survives a
/// relaunch because the keys persist in UserDefaults.
@MainActor
final class Alerts {
    static let shared = Alerts()

    static let enabledKey = "alertsEnabled"
    private let firedKey = "alertsFired"
    private let watchKey = "alertsWatching"   // "vendor|label" -> resetsAt of a hot window
    private let defaults = UserDefaults.standard

    var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(_ board: UsageBoard, now: Date = Date()) {
        guard isEnabled else { return }
        var fired = Set(defaults.stringArray(forKey: firedKey) ?? [])
        var watching = defaults.dictionary(forKey: watchKey) as? [String: Double] ?? [:]

        for p in board.providers {
            for m in p.meters {
                let slot = "\(p.vendor.rawValue)|\(m.label)"

                // A watched hot window whose reset has passed: it's clear now.
                // Checked even for stale providers — the reset time is known,
                // so Codex at 99% four days ago still gets its all-clear.
                if let r = watching[slot], r <= now.timeIntervalSince1970 {
                    post("\(p.vendor.displayName) \(m.label.lowercased()) limit reset",
                         "You're clear to use \(p.vendor.displayName) again.")
                    watching[slot] = nil
                }

                guard !p.isStale(at: now), let r = m.resetsAt, r > now.timeIntervalSince1970 else { continue }
                let used = m.fraction(at: now) * 100
                if used >= 90 { watching[slot] = r }

                for threshold in [95, 80] where used >= Double(threshold) {
                    let key = "\(slot)|\(Int(r))|\(threshold)"
                    if fired.contains(key) { break }
                    // Crossing 95 marks 80 as fired too, so a jump never double-posts.
                    [80, 95].filter { $0 <= threshold }.forEach { fired.insert("\(slot)|\(Int(r))|\($0)") }
                    let body = m.limitDate(at: now).map { "At this pace you'll hit the limit \(Self.relative($0, now)). \(m.resetText(at: now))." }
                        ?? "\(m.resetText(at: now))."
                    post("\(p.vendor.displayName) \(m.label.lowercased()) at \(Int(used.rounded()))%", body)
                    break
                }
            }
        }

        // Keys for windows that reset over a week ago can go.
        let cutoff = now.timeIntervalSince1970 - 8 * 86_400
        fired = fired.filter { k in Double(k.split(separator: "|").dropLast().last ?? "").map { $0 > cutoff } ?? false }
        defaults.set(Array(fired), forKey: firedKey)
        defaults.set(watching, forKey: watchKey)
    }

    private func post(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private static func relative(_ d: Date, _ now: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: now)
    }
}
