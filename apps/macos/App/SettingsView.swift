import ServiceManagement
import SwiftUI

/// ⌘, — everything that used to crowd the popover footer, plus per-lane control.
struct SettingsView: View {
    @ObservedObject var collector: Collector

    var body: some View {
        TabView {
            GeneralPane(collector: collector)
                .tabItem { Label("General", systemImage: "gearshape") }
            LanesPane(collector: collector)
                .tabItem { Label("Lanes", systemImage: "square.stack.3d.up") }
            AdvancedPane(collector: collector)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralPane: View {
    @ObservedObject var collector: Collector
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @AppStorage(Alerts.enabledKey) private var alerts = true
    @AppStorage(DockPolicy.key) private var showInDock = false

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $loginItem)
                    .onChange(of: loginItem) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    }
                Toggle("Show in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, _ in DockPolicy.apply() }
            } footer: {
                Text("TokenMeter lives in the menu bar. With the Dock icon on, the dashboard also shows up in ⌘-Tab.")
            }
            Section("Alerts") {
                Toggle("Notify at 80% and 95%, and when a hot window resets", isOn: $alerts)
                    .onChange(of: alerts) { _, on in if on { Alerts.shared.requestPermission() } }
            }
            Section("Menu bar") {
                ForEach(Vendor.allCases, id: \.self) { v in
                    Toggle(isOn: Binding(
                        get: { MenuBarPrefs.shows(v) },
                        set: { UserDefaults.standard.set($0, forKey: MenuBarPrefs.key(v)); collector.collect() })) {
                        HStack(spacing: 6) { VendorIcon(vendor: v, size: 14); Text(v.displayName) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LanesPane: View {
    @ObservedObject var collector: Collector

    var body: some View {
        Form {
            ForEach(collector.sources, id: \.vendor) { source in
                LaneSection(source: source, collector: collector)
            }
            Section {
                Text("Microsoft 365 Copilot has no per-user usage or limit source outside tenant-admin reports, so it has no lane.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LaneSection: View {
    let source: any ProviderSource
    @ObservedObject var collector: Collector
    @State private var name = ""

    private var vendor: Vendor { source.vendor }
    private var nameKey: String { "\(vendor.rawValue)AccountName" }
    private var provider: ProviderUsage? { collector.board?.providers.first { $0.vendor == vendor } }

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { Prefs.isEnabled(vendor) },
                set: { UserDefaults.standard.set($0, forKey: Prefs.enabledKey(vendor)); collector.collect() })) {
                HStack(spacing: 8) {
                    VendorIcon(vendor: vendor, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(vendor.displayName)
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            TextField("Account name", text: $name, prompt: Text(provider?.account ?? "Personal"))
                .onSubmit(saveName)
                .onChange(of: name) { _, _ in saveName() }
                .help("Shown on the card. Codex and Copilot cannot read your workspace name, so set it here.")
            Text(sourceNote).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { name = UserDefaults.standard.string(forKey: nameKey) ?? "" }
    }

    private func saveName() {
        let v = name.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { UserDefaults.standard.removeObject(forKey: nameKey) } else { UserDefaults.standard.set(v, forKey: nameKey) }
        collector.collect()
    }

    private var status: String {
        if !source.isInstalled { return "Not found on this Mac" }
        if let p = collector.problems[vendor] { return p }
        guard let p = provider else { return "Waiting for data" }
        let when = p.updated.map { "updated \($0.ago(from: Date()))" } ?? "no report yet"
        return [p.accountLine, when].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var sourceNote: String {
        switch vendor {
        case .claude:  "Status line feed plus Anthropic's usage endpoint, using Claude Code's own sign-in (read only)."
        case .codex:   "Rate limits Codex records in ~/.codex/sessions after each turn."
        case .copilot: "GitHub's Copilot quota endpoint, via the gh CLI's sign-in. VS Code agent sessions feed Activity."
        case .cursor:  "Cursor's usage endpoint, via Cursor's local sign-in."
        case .grok:    "xAI usage, where available."
        }
    }
}

private struct AdvancedPane: View {
    @ObservedObject var collector: Collector
    @AppStorage(ClaudeSource.liveEnabledKey) private var liveClaude = true

    var body: some View {
        Form {
            Section("Claude") {
                Toggle("Read Claude limits directly", isOn: $liveClaude)
                    .onChange(of: liveClaude) { _, _ in collector.refreshNow() }
                Text("When the status line is quiet, ask Anthropic for every window using Claude Code's sign-in. Read only: the token is never refreshed, written or stored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Board") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([UsageStore.boardURL]) }
                }
                LabeledContent("Contract") { Text("spec/board.md · v1").foregroundStyle(.secondary) }
                Button("Rescan logs now") { collector.refreshNow() }
            }
        }
        .formStyle(.grouped)
    }
}

/// Menu-bar app by default; a Dock icon on request, or while the dashboard is open.
enum DockPolicy {
    static let key = "showInDock"
    @MainActor static var dashboardOpen = false

    @MainActor static func apply() {
        let wanted = UserDefaults.standard.bool(forKey: key) || dashboardOpen
        NSApp.setActivationPolicy(wanted ? .regular : .accessory)
        if wanted { NSApp.activate() }
    }
}
