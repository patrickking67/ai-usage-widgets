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
        TokenMeterApp.main()
    }
}

/// `tokenmeter://dashboard` (the Claude Code status line links it) and
/// `tokenmeter://refresh`. The menu-bar label, always alive, does the opening.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openDashboard = Notification.Name("tokenmeter.openDashboard")
    static let refresh = Notification.Name("tokenmeter.refresh")

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "tokenmeter" {
            switch url.host {
            case "refresh": NotificationCenter.default.post(name: Self.refresh, object: nil)
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
        // First launch: register as a login item so the menu bar survives reboots.
        if SMAppService.mainApp.status == .notRegistered { try? SMAppService.mainApp.register() }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(board: collector.board, now: now, refresh: collector.refreshNow,
                        problems: collector.problems)
                .onAppear { collector.refreshLimits(); now = Date() }
        } label: {
            MenuBarLabel(board: collector.board, now: now)
                .task { collector.start(); DockPolicy.apply() }
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

    var body: some View {
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
                    Picker("", selection: $tab) {
                        Text("Limits").tag(0)
                        Text("Activity").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh")
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
            HStack(spacing: 14) {
                Button {
                    openWindow(id: "dashboard")
                    NSApp.activate()
                } label: { Label("Dashboard", systemImage: "chart.bar.xaxis") }
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless).font(.system(size: 11))
        }
    }
}
