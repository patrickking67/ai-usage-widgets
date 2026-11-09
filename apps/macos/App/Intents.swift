import AppIntents
import Foundation

// Shortcuts, Spotlight and Siri: check usage, set Keep Awake, open the
// dashboard. Usage is read from the board file, so nothing here makes a
// request or touches a credential.

struct GetUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Get AI Usage"
    static let description = IntentDescription("How much of each AI plan limit is used, from TokenMeter.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let now = Date()
        let lanes = (UsageStore.loadBoard()?.providers ?? []).filter { !$0.meters.isEmpty }
        let text = lanes.isEmpty ? "No limits reported yet. Open TokenMeter to start."
            : lanes.map { $0.spokenHottest(at: now) }.joined(separator: ". ")
        return .result(value: text, dialog: "\(text)")
    }
}

enum AwakeModeOption: String, AppEnum {
    case off, agents, hour, on

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Keep Awake mode"
    static let caseDisplayRepresentations: [AwakeModeOption: DisplayRepresentation] = [
        .off: "Off", .agents: "While agents work", .hour: "For 1 hour", .on: "Until turned off",
    ]
}

struct SetKeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Keep Awake"
    static let description = IntentDescription("Keep the Mac from sleeping, like caffeinate.")

    @Parameter(title: "Mode", default: .hour) var mode: AwakeModeOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let m = AwakeMode(rawValue: mode.rawValue) ?? .off
        KeepAwake.shared.set(m)
        return .result(dialog: "Keep Awake: \(m.title).")
    }
}

struct OpenDashboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Open TokenMeter Dashboard"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: AppDelegate.openDashboard, object: nil)
        return .result()
    }
}

struct TokenMeterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetUsageIntent(),
                    phrases: ["Check AI usage in \(.applicationName)", "How much is left in \(.applicationName)"],
                    shortTitle: "AI Usage", systemImageName: "gauge.with.dots.needle.67percent")
        AppShortcut(intent: SetKeepAwakeIntent(),
                    phrases: ["Keep my Mac awake with \(.applicationName)"],
                    shortTitle: "Keep Awake", systemImageName: "cup.and.saucer")
        AppShortcut(intent: OpenDashboardIntent(),
                    phrases: ["Open the \(.applicationName) dashboard"],
                    shortTitle: "Dashboard", systemImageName: "chart.bar.xaxis")
    }
}
