import XCTest

/// Each vendor's response parsing, from spec/fixtures. These cover the pure
/// decode functions only: no request is made and no credential is read.
final class ClaudeParsingTests: XCTestCase {
    func testLegacyWindowsAndExtraSpend() throws {
        let s = ClaudeLive.decode(try Fixture.json("typical.json"))
        XCTAssertEqual(s.meters.map(\.label), ["Current", "Weekly", "Weekly · Opus"])
        XCTAssertEqual(s.meters.map(\.used), [42.5, 61.0, 18.25])
        XCTAssertEqual(s.meters.map(\.windowSeconds), [18_000, 604_800, 604_800])
        XCTAssertEqual(s.meters[0].resetsAt, Fixture.unix("2026-09-04T21:00:00Z"))
        XCTAssertEqual(s.extra, ExtraSpend(used: 42, limit: 200))
        XCTAssertEqual(s.extra?.text, "$42 of $200")
    }

    func testDisabledExtraAndOverLimitWindows() throws {
        let s = ClaudeLive.decode(try Fixture.json("at-limit.json"))
        XCTAssertNil(s.extra)
        XCTAssertEqual(s.meters.map(\.used), [100.0, 104.2], "over 100% is kept, not clamped, in the data")
    }

    func testUnknownWindowGetsALabelAndWeeklySpan() throws {
        let s = ClaudeLive.decode(try Fixture.json("unknown-window.json"))
        let unknown = try XCTUnwrap(s.meters.first { $0.label == "Thirty Day Experimental" })
        XCTAssertEqual(unknown.used, 55)
        XCTAssertEqual(unknown.windowSeconds, 604_800)
        XCTAssertEqual(ClaudeLive.decode(try Fixture.json("no-weekly.json")).meters.map(\.label), ["Current"])
    }

    func testLimitsListWinsOverCodenamePools() throws {
        let s = ClaudeLive.decode(try Fixture.json("claude-limits.json"))
        XCTAssertEqual(s.meters.map(\.label), ["Current", "Weekly", "Weekly · Opus"])
        XCTAssertEqual(s.meters.map(\.used), [23.5, 41.0, 64.0])
        XCTAssertFalse(s.meters.contains { $0.label.contains("Iguana") }, "internal pools are not plan windows")
        XCTAssertEqual(s.meters[0].resetsAt, Fixture.unix("2026-09-04T21:00:00Z"), "fractional seconds parse")
        XCTAssertNil(s.extra)
    }

    func testWeeklyBreakdownDropsZeroRowsAndSorts() throws {
        let s = ClaudeLive.decode(try Fixture.json("claude-limits.json"))
        XCTAssertEqual(s.breakdown, [Share(label: "Cowork", percent: 46), Share(label: "Claude Code", percent: 34)])
    }

    func testPlanNames() {
        XCTAssertEqual(ClaudeSource.planName(orgType: "claude_team", tier: ""), "Team")
        XCTAssertEqual(ClaudeSource.planName(orgType: "claude_enterprise", tier: "default_claude_max_20x"), "Enterprise")
        XCTAssertEqual(ClaudeSource.planName(orgType: "claude_max", tier: "default_claude_max_20x"), "Max 20x")
        XCTAssertEqual(ClaudeSource.planName(orgType: "claude_max", tier: "default_claude_max_5x"), "Max 5x")
        XCTAssertEqual(ClaudeSource.planName(orgType: "claude_pro", tier: ""), "Pro")
        XCTAssertEqual(ClaudeSource.planName(orgType: "", tier: ""), "Free")
    }
}

final class CodexParsingTests: XCTestCase {
    func testLiveEndpointWindowsShortestFirst() throws {
        let live = CodexSource.decodeLive(try Fixture.json("codex-wham-usage.json"))
        XCTAssertEqual(live.plan, "plus")
        XCTAssertEqual(live.meters.map(\.label), ["Current", "Weekly"])
        XCTAssertEqual(live.meters.map(\.used), [71.5, 34])
        XCTAssertEqual(live.meters.map(\.resetsAt), [1_788_455_880, 1_789_103_127])
    }

    func testLiveEndpointWithoutRateLimitHasNoMeters() {
        XCTAssertTrue(CodexSource.decodeLive(["plan_type": "free"]).meters.isEmpty)
    }

    func testRolloutTakesTheLastLineWithAPrimaryWindow() throws {
        let limits = try XCTUnwrap(CodexSource.lastLimits(inRollout: try Fixture.text("codex-rollout.jsonl")))
        let meters = CodexSource.rolloutMeters(limits, mtime: 0)
        XCTAssertEqual(meters.map(\.label), ["Current", "Weekly"])
        XCTAssertEqual(meters.map(\.used), [91, 34])
        XCTAssertEqual(meters.map(\.windowSeconds), [18_000, 604_800])
    }

    func testRolloutSkipsALaterLimitWithNullPrimary() throws {
        let limits = try XCTUnwrap(CodexSource.lastLimits(inRollout: try Fixture.text("codex-two-limit-ids.jsonl")))
        XCTAssertEqual(limits["limit_id"] as? String, "codex")
        XCTAssertEqual(CodexSource.rolloutMeters(limits, mtime: 0).map(\.used), [94])
    }

    func testRolloutWithOnlyNullLimitsGivesNothing() throws {
        XCTAssertNil(CodexSource.lastLimits(inRollout: try Fixture.text("codex-no-limits.jsonl")))
        XCTAssertNil(CodexSource.lastLimits(inRollout: "{\"rate_limits\": {\"primary\": {\"used_pe"), "a cut line is skipped")
    }

    func testRelativeResetFromOlderBuilds() {
        let limits: [String: Any] = ["primary": ["used_percent": 10, "window_minutes": 300, "resets_in_seconds": 600]]
        XCTAssertEqual(CodexSource.rolloutMeters(limits, mtime: 1_000).first?.resetsAt, 1_600)
    }

    func testPlanNamesAndLabels() {
        XCTAssertEqual(CodexSource.planName("promax"), "Pro Max")
        XCTAssertEqual(CodexSource.planName("pro"), "Pro")
        XCTAssertEqual(CodexSource.planName("plus"), "Plus")
        XCTAssertEqual(CodexSource.planName("business"), "Business")
        XCTAssertNil(CodexSource.planName(""))
        XCTAssertEqual(CodexSource.label(windowSeconds: 18_000), "Current")
        XCTAssertEqual(CodexSource.label(windowSeconds: 604_800), "Weekly")
        XCTAssertEqual(CodexSource.label(windowSeconds: 86_400), "24h")
    }
}

final class CopilotParsingTests: XCTestCase {
    func testMeteredSeat() throws {
        let p = CopilotSource.decode(try Fixture.json("copilot-metered.json"), override: nil)
        XCTAssertEqual(p.plan, "Individual Pro")
        XCTAssertEqual(p.account, "Personal")
        let m = try XCTUnwrap(p.meters.first)
        XCTAssertEqual(m.label, "Premium · 1500/mo")
        XCTAssertEqual(m.used, 27.5, accuracy: 0.001)
        XCTAssertEqual(m.windowSeconds, 30 * 86_400)
        XCTAssertNotNil(m.resetsAt)
        XCTAssertEqual(p.note, "12 requests over the allowance")
        XCTAssertEqual(p.updatedAt, Fixture.unix("2026-09-14T10:00:00Z"))
    }

    func testUncappedSeatShowsCreditsInsteadOfABar() throws {
        let p = CopilotSource.decode(try Fixture.json("copilot-unlimited.json"), override: nil)
        XCTAssertEqual(p.plan, "Business")
        XCTAssertEqual(p.account, "example-org")
        XCTAssertTrue(p.meters.isEmpty)
        XCTAssertEqual(p.note?.hasSuffix("premium credits this month · no cap"), true)
    }

    func testAccountOverrideWins() throws {
        let p = CopilotSource.decode(try Fixture.json("copilot-unlimited.json"), override: "Work")
        XCTAssertEqual(p.account, "Work")
    }
}

final class CursorParsingTests: XCTestCase {
    func testIndividualPlanPoolAndOnDemandSpend() throws {
        let p = CursorSource.decode(try Fixture.json("cursor-usage-summary-pro.json"), planHint: nil, override: nil)
        XCTAssertEqual(p.plan, "Pro+")
        XCTAssertEqual(p.account, "Personal")
        XCTAssertEqual(p.experimental, true)
        let m = try XCTUnwrap(p.meters.first)
        XCTAssertEqual(m.label, "Monthly")
        XCTAssertEqual(m.used, 38)
        XCTAssertEqual(m.resetsAt, Fixture.unix("2026-10-01T00:00:00Z"))
        XCTAssertEqual(m.windowSeconds, 30 * 86_400)
        XCTAssertEqual(p.extra, ExtraSpend(used: 3.5, limit: 50), "cents become dollars")
    }

    func testPercentFallsBackToUsedOverLimit() {
        let root: [String: Any] = ["individualUsage": ["plan": ["used": 500, "limit": 2000]]]
        XCTAssertEqual(CursorSource.decode(root, planHint: "pro", override: nil).meters.first?.used, 25)
        XCTAssertEqual(CursorSource.decode(root, planHint: "pro", override: nil).plan, "Pro")
    }

    func testUnlimitedPlanHasANoteAndNoMeter() {
        let p = CursorSource.decode(["isUnlimited": true, "limitType": "team"], planHint: nil, override: nil)
        XCTAssertTrue(p.meters.isEmpty)
        XCTAssertEqual(p.note, "Unlimited plan")
        XCTAssertEqual(p.account, "Team")
    }
}

final class GrokParsingTests: XCTestCase {
    func testMonthlyCreditPool() throws {
        let p = GrokSource.decode(billing: try Fixture.json("grok-credits-monthly.json"), settings: nil, team: nil, override: nil)
        XCTAssertEqual(p.plan, "SuperGrok")
        XCTAssertEqual(p.account, "Personal")
        let m = try XCTUnwrap(p.meters.first)
        XCTAssertEqual(m.label, "Monthly")
        XCTAssertEqual(m.used, 18.5)
        XCTAssertEqual(m.windowSeconds, 30 * 86_400)
        XCTAssertEqual(p.extra, ExtraSpend(used: 1.2, limit: 25))
    }

    func testUnknownUsageIsNotZero() {
        let p = GrokSource.decode(billing: ["config": ["currentPeriod": ["type": "PERIOD_TYPE_WEEKLY"]]],
                                  settings: ["subscription_tier_display": "SuperGrok Heavy"], team: "Team A", override: nil)
        XCTAssertTrue(p.meters.isEmpty)
        XCTAssertEqual(p.plan, "SuperGrok Heavy")
        XCTAssertEqual(p.account, "Team A")
    }
}

final class PaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testProjectionAndLimitTime() throws {
        // 60% used two hours into a five-hour window: on pace for 150%.
        let m = Meter(label: "Current", used: 60, resetsAt: now.timeIntervalSince1970 + 3 * 3600, windowSeconds: 18_000)
        XCTAssertEqual(try XCTUnwrap(m.elapsedFraction(at: now)), 0.4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(m.projectedAtReset(at: now)), 150, accuracy: 1e-9)
        let hit = try XCTUnwrap(m.limitDate(at: now))
        XCTAssertEqual(hit.timeIntervalSince(now), 80 * 60, accuracy: 1)
    }

    func testNoProjectionEarlyInAWindow() {
        let m = Meter(label: "Current", used: 5, resetsAt: now.timeIntervalSince1970 + 17_000, windowSeconds: 18_000)
        XCTAssertNil(m.projectedAtReset(at: now))
        XCTAssertNil(m.limitDate(at: now))
    }

    func testAPassedResetIsAFreshWindow() {
        let m = Meter(label: "Weekly", used: 80, resetsAt: now.timeIntervalSince1970 - 1, windowSeconds: 604_800)
        XCTAssertEqual(m.fraction(at: now), 0)
        XCTAssertEqual(m.resetText(at: now), "Fresh Window")
    }
}
