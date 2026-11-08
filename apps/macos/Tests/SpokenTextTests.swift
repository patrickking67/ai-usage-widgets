import XCTest

/// The sentences VoiceOver reads for meters and lanes.
final class SpokenTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testDurations() {
        XCTAssertEqual(Meter.spokenDuration(30), "less than a minute")
        XCTAssertEqual(Meter.spokenDuration(60), "1 minute")
        XCTAssertEqual(Meter.spokenDuration(41 * 60), "41 minutes")
        XCTAssertEqual(Meter.spokenDuration(3600), "1 hour")
        XCTAssertEqual(Meter.spokenDuration(2 * 3600 + 13 * 60), "2 hours 13 minutes")
        XCTAssertEqual(Meter.spokenDuration(3 * 86_400 + 4 * 3600 + 59), "3 days 4 hours")
        XCTAssertEqual(Meter.spokenDuration(-5), "less than a minute")
    }

    func testRunningHotSaysWhenTheLimitArrives() {
        let m = Meter(label: "Current", used: 60, resetsAt: now.timeIntervalSince1970 + 3 * 3600, windowSeconds: 18_000)
        XCTAssertEqual(m.spokenSummary(at: now),
                       "60 percent used, resets in 3 hours, at this rate the limit is reached in 1 hour 20 minutes")
    }

    func testOnPace() {
        let m = Meter(label: "Current", used: 20, resetsAt: now.timeIntervalSince1970 + 2 * 3600, windowSeconds: 18_000)
        XCTAssertEqual(m.spokenSummary(at: now), "20 percent used, resets in 2 hours, on pace for 33 percent")
    }

    func testWeeklyResetNamesTheDay() {
        let reset = now.addingTimeInterval(3 * 86_400)
        let f = DateFormatter(); f.dateFormat = "EEEE"
        let m = Meter(label: "Weekly", used: 10, resetsAt: reset.timeIntervalSince1970, windowSeconds: 604_800)
        XCTAssertTrue(m.spokenSummary(at: now).hasPrefix("10 percent used, resets \(f.string(from: reset))"))
    }

    func testFreshWindowAndNoReset() {
        let fresh = Meter(label: "Weekly", used: 80, resetsAt: now.timeIntervalSince1970 - 1, windowSeconds: 604_800)
        XCTAssertEqual(fresh.spokenSummary(at: now), "0 percent used, fresh window")
        let unknown = Meter(label: "Monthly", used: 12.4, resetsAt: nil, windowSeconds: 0)
        XCTAssertEqual(unknown.spokenSummary(at: now), "12 percent used")
    }

    func testLaneSummary() {
        let lane = ProviderUsage(vendor: .claude, account: "Personal", plan: "Pro", meters: [
            Meter(label: "Current", used: 37, resetsAt: nil, windowSeconds: 18_000),
            Meter(label: "Weekly", used: 52, resetsAt: nil, windowSeconds: 604_800)], updatedAt: nil)
        XCTAssertEqual(lane.spokenHottest(at: now), "Claude, 52 percent used")
        let empty = ProviderUsage(vendor: .copilot, account: "", plan: nil, meters: [], updatedAt: nil)
        XCTAssertEqual(empty.spokenHottest(at: now), "GitHub Copilot, no limits reported")
    }
}
