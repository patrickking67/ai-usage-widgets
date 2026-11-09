import AppKit

/// With the Dock icon on, its rings fill to each lane's hottest window, so the
/// Dock shows the same meter as the menu bar. Redrawn only when a ring moves
/// a whole percent. Off, or with nothing reporting, it is the bundle's icon.
@MainActor
enum DockIcon {
    static let liveKey = "dock.liveIcon"
    static var live: Bool { UserDefaults.standard.object(forKey: liveKey) as? Bool ?? true }
    private static var drawn: [Int]?

    static func update(_ board: UsageBoard?, now: Date = Date()) {
        guard NSApp.activationPolicy() == .regular else { return }
        let lanes = (board?.providers ?? []).filter { !$0.meters.isEmpty }.prefix(3)
        guard live, !lanes.isEmpty else { reset(); return }
        let rings = lanes.map { p in
            let (from, to) = colors(p.vendor)
            return IconArt.Ring(fraction: p.hottest(at: now)?.fraction(at: now) ?? 0, from: from, to: to)
        }
        let key = rings.map { Int(($0.fraction * 100).rounded()) }
        guard key != drawn, let image = IconArt.cgImage(px: 512, rings: rings) else { return }
        drawn = key
        NSApp.applicationIconImage = NSImage(cgImage: image, size: NSSize(width: 128, height: 128))
    }

    /// Back to the bundle icon; the next update draws afresh.
    static func reset() {
        guard drawn != nil else { return }
        drawn = nil
        NSApp.applicationIconImage = nil
    }

    private static func colors(_ v: Vendor) -> (NSColor, NSColor) {
        switch v {
        case .claude:  IconArt.clay
        case .codex:   IconArt.blue
        case .copilot: IconArt.violet
        default:       (NSColor(Palette.vendor(v)), NSColor(Palette.vendor(v)))
        }
    }
}
