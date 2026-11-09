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
