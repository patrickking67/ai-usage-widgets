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
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralPane: View {
    @ObservedObject var collector: Collector
    @State private var loginItem = LoginItem.isEnabled
    @State private var loginError: String?
    @AppStorage(Alerts.enabledKey) private var alerts = true
    @AppStorage(DockPolicy.key) private var showInDock = false
    @AppStorage(DockIcon.liveKey) private var liveDock = true
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $loginItem)
                    .onChange(of: loginItem) { _, on in loginError = LoginItem.setEnabled(on) }
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
                Toggle("Show in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, _ in DockPolicy.apply() }
                Toggle("Show usage in the Dock icon", isOn: $liveDock)
                    .onChange(of: liveDock) { _, _ in DockIcon.reset(); DockIcon.update(UsageStore.loadBoard()) }
                    .padding(.leading, 12)
            } footer: {
                Text("TokenMeter lives in the menu bar. With the Dock icon on, the dashboard also shows up in ⌘-Tab.")
            }
            Section {
                Picker("Keep the Mac awake", selection: Binding(get: { awake.mode }, set: { awake.set($0) })) {
                    ForEach(AwakeMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Keep the screen on too", isOn: $awake.screenOn)
            } header: {
                Text("Keep Awake")
            } footer: {
                Text("While agents work means Claude Code or Codex wrote a session in the last five minutes. The cup in the popover does the same.")
            }
            Section("Notifications") {
                Toggle("Notify me", isOn: $alerts)
                    .onChange(of: alerts) { _, on in if on { Alerts.shared.requestPermission() } }
                ForEach(Alerts.Kind.allCases, id: \.self) { k in
                    Toggle(k.title, isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: k.key) as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: k.key) }))
                        .disabled(!alerts)
                        .padding(.leading, 12)
                }
            }
            Section("Menu bar") {
                Picker("Show", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: MenuBarPrefs.styleKey) ?? MenuBarPrefs.logo },
                    set: { UserDefaults.standard.set($0, forKey: MenuBarPrefs.styleKey) })) {
                    Text("Rings logo").tag(MenuBarPrefs.logo)
                    Text("Percentages").tag("percent")
                }
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
        case .codex:   "The usage endpoint Codex's own /status reads, using Codex's sign-in (read only), with the rate limits in ~/.codex/sessions as the fallback."
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
        if wanted {
            NSApp.activate()
            DockIcon.reset()
            DockIcon.update(UsageStore.loadBoard())
        }
    }
}

private struct AboutPane: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("TokenMeter").font(.title2.weight(.semibold))
            Text(version).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Plan limits for Claude, Codex, Copilot, Cursor and Grok. Reads your tools' own sign-ins, writes nothing back, and sends nothing anywhere else.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
            HStack(spacing: 14) {
                Link("Source on GitHub", destination: URL(string: "https://github.com/patrickking67/ai-usage-widgets")!)
                Button("Show board file") { NSWorkspace.shared.activateFileViewerSelecting([UsageStore.boardURL]) }
                    .buttonStyle(.link)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}
