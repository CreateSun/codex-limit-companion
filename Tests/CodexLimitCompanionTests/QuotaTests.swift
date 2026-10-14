import XCTest
@testable import CodexLimitCompanion

final class QuotaTests: XCTestCase {
    private func bucket(_ used: Double, weekly: Double = 20, id: String = "codex") throws -> QuotaBucket {
        try QuotaBucket.decode(["rateLimitsByLimitId": [id: [
            "primary": ["usedPercent": used, "windowDurationMins": 300, "resetsAt": 1800000000],
            "secondary": ["usedPercent": weekly, "windowDurationMins": 10080, "resetsAt": 1800500000]
        ]]])[0]
    }
    func testFractionalUsageAndWeeklyWindow() throws {
        let result = try bucket(37.5)
        XCTAssertEqual(result.shortWindow?.remaining, 62.5)
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows[1].title, "每周额度")
        XCTAssertEqual(result.shortWindow?.resetsAt, Date(timeIntervalSince1970: 1800000000))
    }
    func testMapWinsOverLegacyAndOrderIsStable() throws {
        let result = try QuotaBucket.decode([
            "rateLimitsByLimitId": ["z-model": ["primary": ["usedPercent": 20]], "a-model": ["primary": ["usedPercent": 40]]],
            "rateLimits": ["primary": ["usedPercent": 100]]
        ])
        XCTAssertEqual(result.map(\.id), ["a-model", "z-model"])
        XCTAssertFalse(result[0].blocked)
    }
    func testMissingDataIsNotZeroUsage() throws {
        let result = try QuotaBucket.decode(["rateLimits": ["primary": ["usedPercent": NSNull()]]])[0]
        XCTAssertNil(result.shortWindow)
        XCTAssertThrowsError(try QuotaBucket.decode([:]))
    }
    func testRecoveryOnlyAfterExhaustionAndOnce() throws {
        var tracker = RecoveryTracker()
        XCTAssertFalse(tracker.observe(try bucket(20)))
        XCTAssertFalse(tracker.observe(try bucket(100)))
        XCTAssertFalse(tracker.observe(try bucket(0), at: Date(timeIntervalSince1970: 1000)))
        XCTAssertTrue(tracker.observe(try bucket(0), at: Date(timeIntervalSince1970: 1060)))
        XCTAssertFalse(tracker.observe(try bucket(0)))
    }
    func testWeeklyLimitBlocksRecovery() throws {
        var tracker = RecoveryTracker()
        XCTAssertFalse(tracker.observe(try bucket(100, weekly: 100)))
        XCTAssertFalse(tracker.observe(try bucket(0, weekly: 100)))
        XCTAssertFalse(tracker.observe(try bucket(0, weekly: 0), at: Date(timeIntervalSince1970: 1000)))
        XCTAssertTrue(tracker.observe(try bucket(0, weekly: 0), at: Date(timeIntervalSince1970: 1060)))
    }
    func testSwitchAndUnknownBucketsDoNotSend() throws {
        var tracker = RecoveryTracker()
        XCTAssertFalse(tracker.observe(try bucket(100)))
        tracker.reset()
        XCTAssertFalse(tracker.observe(try bucket(0)))
        XCTAssertFalse(tracker.observe(try bucket(0, id: "other")))
    }
    func testServerBlockedAndNullFlag() throws {
        let blocked = try QuotaBucket.decode(["rateLimits": ["primary": ["usedPercent": 10], "rateLimitReachedType": "weekly"]])[0]
        XCTAssertTrue(blocked.blocked)
        let allowed = try QuotaBucket.decode(["rateLimits": ["primary": ["usedPercent": 10], "rateLimitReachedType": NSNull()]])[0]
        XCTAssertFalse(allowed.blocked)
    }
    func testOnePercentArmsAndFivePercentMustBeStable() throws {
        var tracker = RecoveryTracker()
        XCTAssertTrue(try bucket(99).blocked)
        XCTAssertFalse(tracker.observe(try bucket(99)))
        XCTAssertFalse(tracker.observe(try bucket(98)))
        XCTAssertFalse(tracker.observe(try bucket(95), at: Date(timeIntervalSince1970: 1000)))
        XCTAssertFalse(tracker.observe(try bucket(95), at: Date(timeIntervalSince1970: 1010)))
        XCTAssertTrue(tracker.observe(try bucket(95), at: Date(timeIntervalSince1970: 1060)))
        XCTAssertFalse(tracker.observe(try bucket(95), at: Date(timeIntervalSince1970: 1120)))
    }
    func testFluctuationNetworkFailureAndSleepBreakConfirmation() throws {
        var tracker = RecoveryTracker()
        XCTAssertFalse(tracker.observe(try bucket(100)))
        XCTAssertFalse(tracker.observe(try bucket(95), at: Date(timeIntervalSince1970: 1000)))
        XCTAssertFalse(tracker.observe(try bucket(96), at: Date(timeIntervalSince1970: 1060)))
        XCTAssertFalse(tracker.observe(try bucket(95), at: Date(timeIntervalSince1970: 1120)))
        tracker.interruptConfirmation()
        XCTAssertFalse(tracker.observe(try bucket(95), at: Date(timeIntervalSince1970: 1180)))
        XCTAssertFalse(tracker.observe(try bucket(95), at: Date(timeIntervalSince1970: 1800)))
        XCTAssertTrue(tracker.observe(try bucket(95), at: Date(timeIntervalSince1970: 1860)))
    }
    func testMissingWeeklyWindowCannotImplyRecovery() throws {
        var tracker = RecoveryTracker()
        XCTAssertFalse(tracker.observe(try bucket(100, weekly: 100)))
        let missingWeekly = QuotaBucket(id: "codex", name: "Codex", windows: [QuotaWindow(id: "primary", used: 0, minutes: 300, resetsAt: nil)], serverBlocked: false)
        XCTAssertFalse(tracker.observe(missingWeekly, at: Date(timeIntervalSince1970: 1000)))
        XCTAssertFalse(tracker.observe(missingWeekly, at: Date(timeIntervalSince1970: 1060)))
        XCTAssertFalse(tracker.observe(try bucket(0, weekly: 0), at: Date(timeIntervalSince1970: 1120)))
    }

}
