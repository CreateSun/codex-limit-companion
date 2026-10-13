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
        XCTAssertTrue(tracker.observe(try bucket(0)))
        XCTAssertFalse(tracker.observe(try bucket(0)))
    }
    func testWeeklyLimitBlocksRecovery() throws {
        var tracker = RecoveryTracker()
        XCTAssertFalse(tracker.observe(try bucket(100, weekly: 100)))
        XCTAssertFalse(tracker.observe(try bucket(0, weekly: 100)))
        XCTAssertTrue(tracker.observe(try bucket(0, weekly: 0)))
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
}
