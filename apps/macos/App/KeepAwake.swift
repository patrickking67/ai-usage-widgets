import Foundation
import IOKit.pwr_mgt

/// Keep Awake: stops the Mac idle-sleeping, like `caffeinate -i`, so a long
/// agent run isn't cut off. Optionally keeps the screen on too (`caffeinate -d`).
/// The power assertion belongs to this process, so quitting releases it.
enum AwakeMode: String, CaseIterable, Identifiable {
    case off, agents, hour, on
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:    "Off"
        case .agents: "While agents work"
        case .hour:   "For 1 hour"
        case .on:     "Until turned off"
        }
    }
}

@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    /// How recently Claude Code or Codex must have written a session file
    /// for "While agents work" to count them as working.
    nonisolated static let agentQuiet: TimeInterval = 300

    @Published private(set) var mode: AwakeMode
    @Published private(set) var until: Date?
    @Published private(set) var holding = false
    @Published var screenOn: Bool {
        didSet { UserDefaults.standard.set(screenOn, forKey: "awake.screen"); release(); evaluate() }
    }

    /// Set by the app: say so when "For 1 hour" runs out.
    var onTimerEnded: (() -> Void)?
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    private init() {
        let d = UserDefaults.standard
        mode = AwakeMode(rawValue: d.string(forKey: "awake.mode") ?? "") ?? .off
        until = (d.object(forKey: "awake.until") as? Double).map { Date(timeIntervalSince1970: $0) }
        screenOn = d.bool(forKey: "awake.screen")
    }

    func start() {
        evaluate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in KeepAwake.shared.evaluate() }
        }
    }

    func set(_ mode: AwakeMode) {
        self.mode = mode
        until = mode == .hour ? Date().addingTimeInterval(3600) : nil
        UserDefaults.standard.set(mode.rawValue, forKey: "awake.mode")
        UserDefaults.standard.set(until?.timeIntervalSince1970, forKey: "awake.until")
        evaluate()
    }

    func evaluate(now: Date = Date()) {
        if mode == .hour, let until, now >= until {
            set(.off)
            onTimerEnded?()
            return
        }
        let last = mode == .agents ? Self.lastAgentWrite(now: now) : nil
        let want = Self.shouldHold(mode: mode, until: until, lastAgentWrite: last, now: now)
        if want, !holding {
            let type = (screenOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                                 : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
            holding = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                  "TokenMeter Keep Awake" as CFString, &assertion) == kIOReturnSuccess
        } else if !want, holding {
            release()
        }
    }

    private func release() {
        guard holding else { return }
        IOPMAssertionRelease(assertion)
        holding = false
    }

    nonisolated static func shouldHold(mode: AwakeMode, until: Date?, lastAgentWrite: Date?, now: Date) -> Bool {
        switch mode {
        case .off:    return false
        case .on:     return true
        case .hour:   return until.map { now < $0 } ?? false
        case .agents: return lastAgentWrite.map { now.timeIntervalSince($0) < agentQuiet } ?? false
        }
    }

    /// Newest session file Claude Code or Codex wrote. Only Claude project
    /// folders touched in the last three days are opened, so this stays cheap.
    nonisolated static func lastAgentWrite(now: Date) -> Date? {
        let fm = FileManager.default, home = UsageStore.realHome
        let since = now.addingTimeInterval(-3 * 86_400)
        func mtime(_ u: URL) -> Date? { try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        func newest(in dir: URL) -> Date? {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
                .filter { $0.pathExtension == "jsonl" }.compactMap(mtime).max()
        }
        var dirs: [URL] = []
        let projects = home.appendingPathComponent(".claude/projects")
        for d in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where (mtime(d) ?? .distantPast) > since { dirs.append(d) }
        let cal = Calendar.current
        for back in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            dirs.append(home.appendingPathComponent(".codex/sessions")
                .appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!)))
        }
        return dirs.compactMap(newest).max()
    }
}
