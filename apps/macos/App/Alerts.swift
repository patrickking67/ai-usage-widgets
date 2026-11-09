import Foundation
import UserNotifications

/// Notifies when a window is on pace to run out early, at 80% and 95%, when
/// it is used up (with when it comes back), and when a window that was nearly
/// spent resets: the moment you can go back to work. Clicking one opens the
/// dashboard.
///
/// Each alert is keyed to one window instance (vendor, meter, reset time), so
/// it fires once per window rather than every 20 seconds, and survives a
/// relaunch because the keys persist in UserDefaults.
@MainActor
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Alerts()

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

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

                for threshold in [100, 95, 80] where used >= Double(threshold) - (threshold == 100 ? 0.5 : 0) {
                    let key = "\(slot)|\(Int(r))|\(threshold)"
                    if fired.contains(key) { break }
                    // Crossing a higher mark marks the lower ones too, so a jump never double-posts.
                    [80, 95, 100, -1].filter { $0 <= threshold }.forEach { fired.insert("\(slot)|\(Int(r))|\($0)") }
                    if threshold == 100 {
                        let back = Date(timeIntervalSince1970: r)
                        post("\(p.vendor.displayName) \(m.label.lowercased()) limit reached",
                             "It comes back \(back.formatted(.dateTime.weekday(.wide).hour().minute())).")
                        break
                    }
                    let body = m.limitDate(at: now).map { "At this pace you'll hit the limit \(Self.relative($0, now)). \(m.resetText(at: now))." }
                        ?? "\(m.resetText(at: now))."
                    post("\(p.vendor.displayName) \(m.label.lowercased()) at \(Int(used.rounded()))%", body)
                    break
                }

                // Running hot well before 80%: on course to run out before the
                // reset. Once per window; -1 is the pace slot.
                let paceKey = "\(slot)|\(Int(r))|-1"
                if used >= 40, used < 80, !fired.contains(paceKey), let hit = m.limitDate(at: now) {
                    fired.insert(paceKey)
                    post("\(p.vendor.displayName) \(m.label.lowercased()) is running hot",
                         "\(Int(used.rounded()))% used. At this pace you'll hit the limit \(Self.relative(hit, now)), before it resets.")
                }
            }
        }

        // Keys for windows that reset over a week ago can go.
        let cutoff = now.timeIntervalSince1970 - 8 * 86_400
        fired = fired.filter { k in Double(k.split(separator: "|").dropLast().last ?? "").map { $0 > cutoff } ?? false }
        defaults.set(Array(fired), forKey: firedKey)
        defaults.set(watching, forKey: watchKey)
    }

    /// Clicking a notification opens the dashboard.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        Task { @MainActor in NotificationCenter.default.post(name: AppDelegate.openDashboard, object: nil) }
        done()
    }

    /// Shown even while the popover or dashboard is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func post(_ title: String, _ body: String) {
        guard isEnabled else { return }
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
