import Foundation
import WidgetKit
import os

let log = Logger(subsystem: "com.patrickking.tokenmeter", category: "collector")

/// Gathers every lane into one `UsageBoard` and writes it for the widget, the
/// Windows-style CLI readers and the Claude Code plugin. Runs only in the
/// (unsandboxed) menu-bar app; the vendor specifics live in `Providers/`.
@MainActor
final class Collector: ObservableObject {
    @Published private(set) var board: UsageBoard?
    /// Per-lane reason data is missing or degraded. Shown under that card.
    @Published private(set) var problems: [Vendor: String] = [:]

    /// False for offscreen `--render`: no network, no Keychain, no notifications.
    var interactive = true {
        didSet {
            claude.interactive = interactive; codex.interactive = interactive; copilot.interactive = interactive
            cursor.interactive = interactive; grok.interactive = interactive
        }
    }

    let claude = ClaudeSource()
    let codex = CodexSource()
    let copilot = CopilotSource()
    let cursor = CursorSource()
    let grok = GrokSource()
    private(set) lazy var sources: [any ProviderSource] = [claude, codex, copilot, cursor, grok]

    private var timer: Timer?
    private var activity: Activity?
    private let scanner = ActivityScanner()
    private let scanQueue = DispatchQueue(label: "tokenmeter.activity", qos: .utility)
    private var scanning = false
    private var lastScan = Date.distantPast
    private var lastWrite = Date.distantPast

    init() {
        Prefs.migrateLegacyDefaults()
        for s in sources { s.onUpdate = { [weak self] in self?.collect() } }
    }

    func start() {
        collect()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.collect() }
        }
        // `TokenMeter --reload` (run by the status line) pings this.
        DistributedNotificationCenter.default().addObserver(
            forName: UsageStore.refreshNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.collect() } }
    }

    /// The refresh button: re-read everything now, skipping polling intervals
    /// but not a vendor's back-off.
    func refreshNow() {
        sources.forEach { $0.refreshNow() }
        lastScan = .distantPast
        collect()
    }

    /// Opening the popover: re-ask the vendors (each source throttles itself)
    /// without restarting the activity scan.
    func refreshLimits() {
        sources.forEach { $0.refreshNow() }
        collect()
    }

    func collect() {
        // --render with $TOKENMETER_BOARD: draw a given board (the site's demo
        // screenshots) instead of this machine's.
        if !interactive, let path = ProcessInfo.processInfo.environment["TOKENMETER_BOARD"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let fixed = try? JSONDecoder().decode(UsageBoard.self, from: data) {
            board = fixed
            return
        }
        scanActivityIfDue()
        let now = Date()
        let enabled: [any ProviderSource] = sources.filter { Prefs.isEnabled($0.vendor) }
        let next = UsageBoard(generatedAt: now.timeIntervalSince1970,
                              providers: enabled.compactMap { $0.usage(now: now) },
                              activity: activity)
        problems = Dictionary(uniqueKeysWithValues: enabled.compactMap { s in s.problem.map { (s.vendor, $0) } })
        // Compare without the timestamp so an unchanged board is not rewritten.
        let changed = next.providers != board?.providers || next.activity != board?.activity
        board = next
        if interactive { Alerts.shared.evaluate(next); DockIcon.update(next, now: now) }
        // Rewritten unchanged every five minutes too, so readers can tell a
        // quiet board from an app that has stopped (UsageBoard.isStale).
        let heartbeat = now.timeIntervalSince(lastWrite) >= 300
        guard changed || heartbeat else { return }
        write(next)
        lastWrite = now
        if changed { WidgetCenter.shared.reloadAllTimelines() }
    }

    private func write(_ board: UsageBoard) {
        try? FileManager.default.createDirectory(at: UsageStore.dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(board) else { return }
        try? data.write(to: UsageStore.boardURL, options: .atomic)
    }

    // MARK: Activity

    /// Every five minutes on its own queue; the first pass over a month of logs
    /// takes a while, later ones only read what was appended.
    private func scanActivityIfDue() {
        guard interactive || activity == nil, !scanning,
              Date().timeIntervalSince(lastScan) >= 300 else { return }
        scanning = true
        lastScan = Date()
        let scanner = scanner
        if !interactive {
            // --render: synchronous, so the preview has the data.
            activity = scanner.scan(); scanning = false; return
        }
        scanQueue.async {
            let result = scanner.scan()
            Task { @MainActor in
                self.activity = result
                self.scanning = false
                self.collect()
            }
        }
    }
}

/// Preferences shared by the Settings window and the collector.
enum Prefs {
    static func enabledKey(_ v: Vendor) -> String { "provider.\(v.rawValue).enabled" }
    static func isEnabled(_ v: Vendor) -> Bool {
        UserDefaults.standard.object(forKey: enabledKey(v)) as? Bool ?? true
    }

    /// The app was ClaudeUsage (com.patrickking.claudeusage) before the rename;
    /// carry over what was set there once, without overwriting anything newer.
    static func migrateLegacyDefaults() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedLegacyDefaults"),
              let old = UserDefaults(suiteName: "com.patrickking.claudeusage") else { return }
        for key in ["codexAccountName", "claudeAccountName", "claudeLiveEnabled", "alertsEnabled", "popoverTab"]
        where d.object(forKey: key) == nil {
            if let v = old.object(forKey: key) { d.set(v, forKey: key) }
        }
        d.set(true, forKey: "migratedLegacyDefaults")
    }
}
