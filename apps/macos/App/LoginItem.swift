import Foundation
import os
import ServiceManagement

private let loginLog = Logger(subsystem: "com.patrickking.tokenmeter", category: "login")

/// Open at login, so the menu bar and the widgets' data survive a restart.
///
/// `SMAppService.mainApp` is the system's own login item. Registering used to
/// be tried only when its status read `.notRegistered`, so a copy reporting
/// any other status was never registered and didn't come back after a
/// restart. Now it is registered once on first launch and the status checked
/// afterwards; if that fails, a per-user LaunchAgent does the job instead,
/// which also brings the app back after a crash, but not after Quit.
enum LoginItem {
    static let label = "com.patrickking.tokenmeter"
    static var agentURL: URL {
        UsageStore.realHome.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// On by default, once; after that the Settings toggle decides. A login
    /// agent written for an older copy of the app is pointed at this one.
    static func setUpOnLaunch() {
        let key = "loginItemConfigured"
        if UserDefaults.standard.bool(forKey: key) {
            if FileManager.default.fileExists(atPath: agentURL.path) { writeAgent() }
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        setEnabled(true)
    }

    /// Returns nil when it worked, or the reason it didn't.
    @discardableResult
    static func setEnabled(_ on: Bool) -> String? {
        guard on else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: agentURL)
            return nil
        }
        do {
            try SMAppService.mainApp.register()
            // Registered isn't always enabled: check, rather than trust the lack of an error.
            if [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) {
                try? FileManager.default.removeItem(at: agentURL)
                return nil
            }
            loginLog.error("login item: status \(SMAppService.mainApp.status.rawValue, privacy: .public) after register; using a launch agent")
        } catch {
            loginLog.error("login item: \(error.localizedDescription, privacy: .public); using a launch agent")
        }
        return writeAgent() ? nil : "Couldn't write \(agentURL.path)."
    }

    @discardableResult
    private static func writeAgent() -> Bool {
        guard let exe = Bundle.main.executableURL?.path,
              let data = try? PropertyListSerialization.data(fromPropertyList: agentPlist(executable: exe),
                                                             format: .xml, options: 0) else { return false }
        if (try? Data(contentsOf: agentURL)) == data { return true }
        do {
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: agentURL, options: .atomic)
            return true
        } catch {
            loginLog.error("login agent: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Starts with the user's GUI session. `KeepAlive.SuccessfulExit = false`
    /// restarts a crash but leaves a deliberate Quit (exit 0) alone.
    nonisolated static func agentPlist(executable: String) -> [String: Any] {
        ["Label": label,
         "ProgramArguments": [executable],
         "RunAtLoad": true,
         "KeepAlive": ["SuccessfulExit": false],
         "LimitLoadToSessionType": "Aqua",
         "ProcessType": "Interactive"]
    }
}
