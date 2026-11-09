import XCTest

/// Pure decisions behind Open at login and Keep Awake. Nothing here writes a
/// launch agent or takes a power assertion.
final class LoginItemTests: XCTestCase {
    func testAgentRestartsACrashButNotAQuit() throws {
        let p = LoginItem.agentPlist(executable: "/Applications/TokenMeter.app/Contents/MacOS/TokenMeter")
        XCTAssertEqual(p["Label"] as? String, "com.patrickking.tokenmeter")
        XCTAssertEqual(p["ProgramArguments"] as? [String], ["/Applications/TokenMeter.app/Contents/MacOS/TokenMeter"])
        XCTAssertEqual(p["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((p["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
        XCTAssertEqual(p["LimitLoadToSessionType"] as? String, "Aqua", "GUI sessions only, never at the login window")
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0))
    }
}

final class KeepAwakeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOffAndOn() {
        XCTAssertFalse(KeepAwake.shouldHold(mode: .off, until: nil, lastAgentWrite: now, now: now))
        XCTAssertTrue(KeepAwake.shouldHold(mode: .on, until: nil, lastAgentWrite: nil, now: now))
    }

    func testHourEndsAtItsDeadline() {
        let until = now.addingTimeInterval(60)
        XCTAssertTrue(KeepAwake.shouldHold(mode: .hour, until: until, lastAgentWrite: nil, now: now))
        XCTAssertFalse(KeepAwake.shouldHold(mode: .hour, until: until, lastAgentWrite: nil, now: until))
        XCTAssertFalse(KeepAwake.shouldHold(mode: .hour, until: nil, lastAgentWrite: nil, now: now))
    }

    func testAgentsHoldOnlyWhileSessionsAreBeingWritten() {
        let recent = now.addingTimeInterval(-KeepAwake.agentQuiet + 5)
        let quiet = now.addingTimeInterval(-KeepAwake.agentQuiet - 5)
        XCTAssertTrue(KeepAwake.shouldHold(mode: .agents, until: nil, lastAgentWrite: recent, now: now))
        XCTAssertFalse(KeepAwake.shouldHold(mode: .agents, until: nil, lastAgentWrite: quiet, now: now))
        XCTAssertFalse(KeepAwake.shouldHold(mode: .agents, until: nil, lastAgentWrite: nil, now: now))
    }
}

final class CopilotLookupTests: XCTestCase {
    func testGhIsFoundInUserLevelManagersToo() {
        let c = CopilotSource.ghCandidates(home: "/Users/someone")
        XCTAssertEqual(c.first, "/opt/homebrew/bin/gh", "Homebrew stays first")
        XCTAssertTrue(c.contains("/Users/someone/.pixi/bin/gh"))
        XCTAssertTrue(c.contains("/Users/someone/.local/bin/gh"))
    }
}

final class ActivityTrendTests: XCTestCase {
    private func activity(_ claude: [Double], codex: [Double]? = nil) -> Activity {
        let days = claude.enumerated().map { i, c in
            DayUsage(day: Double(i) * 86_400, claude: c, codex: codex?[i] ?? 0)
        }
        return Activity(generatedAt: 0, days: days, models: [], claude24h: .init(), codex24h: .init(),
                        drivers: [], subagentShare: nil, longContextShare: nil)
    }

    func testWeekOverWeek() throws {
        let a = activity(Array(repeating: 10, count: 7) + Array(repeating: 15, count: 7))
        XCTAssertEqual(try XCTUnwrap(a.weekOverWeek), 0.5, accuracy: 1e-9)
        XCTAssertNil(activity(Array(repeating: 10, count: 13)).weekOverWeek, "needs two full weeks")
        XCTAssertNil(activity(Array(repeating: 0, count: 7) + Array(repeating: 5, count: 7)).weekOverWeek,
                     "no change from nothing")
    }

    func testVendorSharesOverTheSpanOnly() {
        let a = activity([100, 0, 30], codex: [0, 0, 10])
        let two = a.vendorShares(span: 2)
        XCTAssertEqual(two.map(\.vendor), [.claude, .codex])
        XCTAssertEqual(two.map(\.share), [0.75, 0.25])
        XCTAssertTrue(activity([0, 0]).vendorShares(span: 2).isEmpty)
    }
}

final class ProjectAndHeatTests: XCTestCase {
    private let home = "/Users/someone"

    func testProjectNames() {
        XCTAssertEqual(ProjectShare.name(cwd: "/Users/someone/GitHub/app", home: home), "app")
        XCTAssertEqual(ProjectShare.name(cwd: "/Users/someone/GitHub/app/", home: home), "app")
        XCTAssertEqual(ProjectShare.name(cwd: "/Users/someone/GitHub/app/.claude/worktrees/fix-x", home: home), "app",
                       "a worktree counts toward its repository")
        XCTAssertEqual(ProjectShare.name(cwd: "/Users/someone/GitHub/app/.worktrees/feat-y/src", home: home), "app")
        XCTAssertEqual(ProjectShare.name(cwd: "/Users/someone", home: home), "Home")
        XCTAssertEqual(ProjectShare.name(cwd: "/private/tmp/x", home: home), "Scratch")
        XCTAssertEqual(ProjectShare.name(
            cwd: "/Users/someone/Library/Application Support/Claude/scratch-workspaces/a/b", home: home), "Scratch")
    }

    func testPeakIsTheBusiestCell() throws {
        var heat = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        heat[1][14] = 900; heat[4][9] = 300
        let a = Activity(generatedAt: 0, days: [], models: [], claude24h: .init(), codex24h: .init(), drivers: [],
                         subagentShare: nil, longContextShare: nil, heat: heat)
        let p = try XCTUnwrap(a.peak)
        XCTAssertEqual(p.weekday, 1); XCTAssertEqual(p.hour, 14)
        XCTAssertNil(Activity(generatedAt: 0, days: [], models: [], claude24h: .init(), codex24h: .init(), drivers: [],
                              subagentShare: nil, longContextShare: nil).peak)
    }
}

final class CodexWorkspaceTests: XCTestCase {
    func testWorkspaceNameForTheSelectedAccountOnly() throws {
        let o = try Fixture.json("codex-accounts.json")
        XCTAssertEqual(CodexSource.workspaceName(o, accountID: "acct-workspace-0002"), "Example Workspace")
        XCTAssertNil(CodexSource.workspaceName(o, accountID: "acct-personal-0001"), "personal accounts have no workspace name")
        XCTAssertNil(CodexSource.workspaceName(o, accountID: nil))
        XCTAssertEqual(CodexSource.planName("self_serve_business_prolite"), "Business")
    }
}
