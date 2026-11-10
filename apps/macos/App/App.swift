import ServiceManagement
import SwiftUI
import WidgetKit

/// `TokenMeter --reload` pings the running menu-bar app to re-collect, nudges
/// WidgetKit, and exits without UI. The status line calls it on every change.
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--reload") {
            DistributedNotificationCenter.default().postNotificationName(
                UsageStore.refreshNotification, object: nil, userInfo: nil, deliverImmediately: true)
            WidgetCenter.shared.reloadAllTimelines()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            exit(0)
        }
        // `TokenMeter --render out.png` draws the popover offscreen, for
        // checking the design without Screen Recording permission.
        if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated {
                let c = Collector(); c.interactive = false; c.collect()
                for (suffix, dark, vibrant, tab) in [("", false, false, 0), ("-dark", true, false, 0),
                                                     ("-vibrant", true, true, 0), ("-activity", true, false, 1)] {
                    let view = PopoverView(board: c.board, now: Date(), refresh: {}, forcedTab: tab)
                        .background(dark ? Color(white: 0.12) : Color(white: 0.97))
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.forceVibrant, vibrant)
                    let r = ImageRenderer(content: view); r.scale = 2
                    let path = CommandLine.arguments[i + 1].replacingOccurrences(of: ".png", with: "\(suffix).png")
                    if let img = r.nsImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
            // Widget layouts at real sizes (medium 338×158, large 338×354).
            MainActor.assumeIsolated {
                let c = Collector(); c.interactive = false; c.collect()
                guard let a = c.board?.activity else { return }
                for (suffix, vibrant) in [("-widget", false), ("-widget-vibrant", true)] {
                    let view = VStack(spacing: 16) {
                        HStack(alignment: .top, spacing: 14) {
                            WeekChart(activity: a, height: 78).frame(maxWidth: .infinity)
                            DriversList(activity: a, limit: 4, compact: true).frame(maxWidth: .infinity)
                        }
                        .padding(16).frame(width: 338, height: 158, alignment: .topLeading)
                        .background(Color(white: vibrant ? 0.35 : 0.14), in: RoundedRectangle(cornerRadius: 20))
                        VStack(alignment: .leading, spacing: 12) {
                            WeekChart(activity: a, height: 96)
                            DriversList(activity: a, limit: 4, compact: true)
                            ModelsList(activity: a, limit: 3)
                                Spacer(minLength: 0)
                        }
                        .padding(16).frame(width: 338, height: 354, alignment: .topLeading)
                        .background(Color(white: vibrant ? 0.35 : 0.14), in: RoundedRectangle(cornerRadius: 20))
                    }
                    .padding(12).background(Color(red: 0.16, green: 0.24, blue: 0.36))
                    .environment(\.colorScheme, .dark).environment(\.forceVibrant, vibrant)
                    let r = ImageRenderer(content: view); r.scale = 2
                    let path = CommandLine.arguments[i + 1].replacingOccurrences(of: ".png", with: "\(suffix).png")
                    if let img = r.nsImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
            // Rings widget, small 158×158 and medium 338×158, colour and vibrant.
            MainActor.assumeIsolated {
                let c = Collector(); c.interactive = false; c.collect()
                let now = Date()
                for (suffix, vibrant) in [("-rings", false), ("-rings-vibrant", true)] {
                    let view = HStack(spacing: 16) {
                        RingStack(providers: ringLanes(c.board, limit: 3), now: now)
                            .padding(16).frame(width: 158, height: 158)
                            .background(Color(white: vibrant ? 0.35 : 0.14), in: RoundedRectangle(cornerRadius: 20))
                        RingRow(providers: ringLanes(c.board, limit: 4), now: now)
                            .padding(16).frame(width: 338, height: 158)
                            .background(Color(white: vibrant ? 0.35 : 0.14), in: RoundedRectangle(cornerRadius: 20))
                    }
                    .padding(12).background(Color(red: 0.16, green: 0.24, blue: 0.36))
                    .environment(\.colorScheme, .dark).environment(\.forceVibrant, vibrant)
                    let r = ImageRenderer(content: view); r.scale = 2
                    let path = CommandLine.arguments[i + 1].replacingOccurrences(of: ".png", with: "\(suffix).png")
                    if let img = r.nsImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
            // Dashboard, light and dark, for the site and README.
            MainActor.assumeIsolated {
                let c = Collector(); c.interactive = false; c.collect()
                guard let b = c.board else { return }
                for (suffix, dark) in [("-dashboard", false), ("-dashboard-dark", true)] {
                    let view = HStack(alignment: .top, spacing: 0) {
                        LimitsColumn(board: b, problems: [:], now: Date()).padding(20).frame(width: 340)
                            .background(dark ? Color(white: 0.15) : Color(white: 0.95))
                        if let a = b.activity {
                            ActivityDashboard(activity: a, span: 30).padding(24).frame(width: 760)
                        }
                    }
                    .background(dark ? Color(white: 0.11) : .white)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    let r = ImageRenderer(content: view); r.scale = 2
                    let path = CommandLine.arguments[i + 1].replacingOccurrences(of: ".png", with: "\(suffix).png")
                    if let img = r.nsImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
            exit(0)
        }
        // One copy only: the login agent and a double-click can both start it.
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != me }) {
            exit(0)
        }
        TokenMeterApp.main()
    }
}

/// `tokenmeter://dashboard` (the Claude Code status line links it) and
/// `tokenmeter://refresh`. The menu-bar label, always alive, does the opening.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openDashboard = Notification.Name("tokenmeter.openDashboard")
    static let refresh = Notification.Name("tokenmeter.refresh")

    /// Any web page can open a tokenmeter:// link, so refreshes from one are
    /// limited to one a minute and can't be used to drive vendor requests.
    private var lastLinkRefresh = Date.distantPast

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "tokenmeter" {
            switch url.host {
            case "refresh":
                guard Date().timeIntervalSince(lastLinkRefresh) >= 60 else { continue }
                lastLinkRefresh = Date()
                NotificationCenter.default.post(name: Self.refresh, object: nil)
            default:        NotificationCenter.default.post(name: Self.openDashboard, object: nil)
            }
        }
    }
}

struct TokenMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var collector = Collector()
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    init() {
        LoginItem.setUpOnLaunch()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(board: collector.board, now: now, refresh: collector.refreshNow,
                        problems: collector.problems)
                .onAppear { collector.refreshLimits(); now = Date() }
        } label: {
            MenuBarLabel(board: collector.board, now: now)
                .task {
                    collector.start()
                    KeepAwake.shared.onTimerEnded = { Alerts.shared.post("Keep Awake ended", "Your Mac can sleep again.") }
                    KeepAwake.shared.start()
                    DockPolicy.apply()
                }
                .onReceive(tick) { now = $0 }
                .modifier(URLRouter(refresh: collector.refreshNow))
        }
        .menuBarExtraStyle(.window)

        Window("TokenMeter", id: "dashboard") {
            DashboardView(collector: collector)
        }
        .defaultSize(width: 1120, height: 760)
        .keyboardShortcut("d", modifiers: [.command, .shift])

        Settings {
            SettingsView(collector: collector)
        }
    }
}

private struct URLRouter: ViewModifier {
    var refresh: () -> Void
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openDashboard)) { _ in
                openWindow(id: "dashboard")
                NSApp.activate()
            }
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.refresh)) { _ in refresh() }
    }
}

/// `✳ 37%  ◎ 99%` — each vendor's mark with its hottest window.
struct MenuBarLabel: View {
    var board: UsageBoard?
    var now: Date
    @AppStorage(MenuBarPrefs.styleKey) private var style = MenuBarPrefs.logo
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        let lanes = (board?.providers ?? []).filter { !$0.meters.isEmpty && MenuBarPrefs.shows($0.vendor) }
        Group {
            if style == MenuBarPrefs.logo {
                Image(nsImage: MenuBarGlyph.image(
                    fractions: lanes.map { $0.hottest(at: now)?.fraction(at: now) ?? 0 },
                    awake: awake.holding ? .holding : awake.mode == .off ? .off : .armed))
            } else {
                percentages
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("TokenMeter")
        .accessibilityValue((lanes.map { $0.spokenHottest(at: now) } + (awake.holding ? ["keeping the Mac awake"] : []))
            .joined(separator: "; "))
    }

    /// The older label: each vendor's mark with its hottest window.
    private var percentages: some View {
        HStack(spacing: 6) {
            // Lanes without a percentage (an uncapped Copilot seat) live in the
            // popover only; the menu bar is for what can run out.
            let providers = (board?.providers ?? []).filter { !$0.meters.isEmpty && MenuBarPrefs.shows($0.vendor) }
            if !providers.isEmpty {
                ForEach(providers) { p in
                    VendorMark(vendor: p.vendor)
                    if let m = p.hottest(at: now) {
                        Text("\(Int((m.fraction(at: now) * 100).rounded()))%").monospacedDigit()
                    }
                    // On course to run out before reset: worth a glance now,
                    // not when the number finally reads 100.
                    if !p.isStale(at: now), p.meters.contains(where: { $0.limitDate(at: now) != nil }) {
                        Image(systemName: "flame.fill")
                    }
                }
            } else {
                VendorMark(vendor: .claude)
            }
            if awake.mode != .off { Image(systemName: awake.holding ? "cup.and.saucer.fill" : "cup.and.saucer") }
        }
    }
}

struct PopoverView: View {
    var board: UsageBoard?
    var now: Date
    var refresh: () -> Void
    var problems: [Vendor: String] = [:]
    @AppStorage(Alerts.enabledKey) private var alerts = true
    @AppStorage("popoverTab") private var tab = 0
    @Environment(\.openWindow) private var openWindow
    var forcedTab: Int? = nil        // --render

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Usage").font(.system(size: 15, weight: .semibold))
                Spacer()
                if let forcedTab {
                    // Offscreen render: native controls draw as placeholders.
                    HStack(spacing: 0) {
                        ForEach(["Limits", "Activity"].indices, id: \.self) { i in
                            Text(["Limits", "Activity"][i]).font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(i == forcedTab ? Color.primary.opacity(0.14) : .clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    .padding(2).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                } else {
                    Picker("View", selection: $tab) {
                        Text("Limits").tag(0)
                        Text("Activity").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    KeepAwakeMenu()
                    Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                        .accessibilityLabel("Refresh limits")
                }
            }

            if forcedTab == 1 {
                ActivityPanel(activity: board?.activity)   // offscreen render can't draw a ScrollView
            } else if (forcedTab ?? tab) == 1 {
                ScrollView {
                    ActivityPanel(activity: board?.activity).padding(.trailing, 6)
                }
                .frame(maxHeight: 560)
                .scrollIndicators(.never)
            } else {
                limits
            }

            if forcedTab == nil { footer }
        }
        .padding(18)
        .frame(width: 360)
        .onAppear { if alerts { Alerts.shared.requestPermission() } }
    }

    @ViewBuilder private var limits: some View {
            if let providers = board?.providers, !providers.isEmpty {
                ForEach(providers) { p in
                    ProviderCard(provider: p, now: now, linksOut: true)
                    if let problem = problems[p.vendor] {
                        Label(problem, systemImage: "exclamationmark.circle")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .padding(.top, -6)
                    }
                    if p.id != providers.last?.id { Divider() }
                }
            } else {
                Text("Waiting for Claude Code, Codex or Copilot to report limits.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if let line = summary {
                Text(line).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            HStack(spacing: 14) {
                Button {
                    openWindow(id: "dashboard")
                    NSApp.activate()
                } label: { Label("Dashboard", systemImage: "chart.bar.xaxis") }
                    .keyboardShortcut("d")
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .keyboardShortcut(",")
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless).font(.system(size: 11))
        }
    }
}

extension PopoverView {
    /// "Today 1.2B tokens · 9.4B this week, up 12% · updated 20s ago".
    var summary: String? {
        guard let board else { return nil }
        var parts: [String] = []
        if let a = board.activity, let today = a.days.last {
            parts.append("Today \(today.total.compactTokens)")
            var week = "\(a.weekTotal.compactTokens) this week"
            if let w = a.weekOverWeek, abs(w) >= 0.01 { week += ", \(w > 0 ? "up" : "down") \(Int((abs(w) * 100).rounded()))%" }
            parts.append(week)
        }
        let ago = Date(timeIntervalSince1970: board.generatedAt).ago(from: now)
        parts.append(ago == "Live" ? "updated just now" : "updated \(ago)")
        return parts.joined(separator: " · ")
    }
}

/// The cup in the popover header: Keep Awake's modes, and whether the screen
/// stays on too. Filled while the Mac is being kept awake.
struct KeepAwakeMenu: View {
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        Menu {
            Picker("Keep Awake", selection: Binding(get: { awake.mode }, set: { awake.set($0) })) {
                ForEach(AwakeMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Keep the screen on too", isOn: $awake.screenOn)
        } label: {
            Image(systemName: awake.holding ? "cup.and.saucer.fill" : "cup.and.saucer")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel("Keep Awake")
        .accessibilityValue(help)
    }

    private var help: String {
        switch awake.mode {
        case .off:    return "Keep Awake is off"
        case .on:     return "Keeping the Mac awake until turned off"
        case .hour:   return awake.until.map { "Keeping the Mac awake until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Keep Awake"
        case .agents: return awake.holding ? "Keeping the Mac awake while agents work" : "Will keep the Mac awake when an agent starts working"
        }
    }
}
