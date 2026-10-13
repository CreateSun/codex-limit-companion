import XCTest
@testable import CodexLimitCompanion

final class LiveReadTests: XCTestCase {
    func testReadOnlyIntegration() async throws {
        guard ProcessInfo.processInfo.environment["COMPANION_LIVE_CHECK"] == "1" else { throw XCTSkip("Opt-in read-only local Codex check") }
        defer { CodexAppServerClient.shutdown() }
        let buckets = try await CodexAppServerClient.readLimits()
        XCTAssertFalse(buckets.isEmpty)
        XCTAssertTrue(buckets.contains { !$0.windows.isEmpty })
        let threads = try await CodexAppServerClient.listThreads()
        XCTAssertEqual(Set(threads.map(\.id)).count, threads.count)
        print("Live integration: \(buckets.count) quota buckets, \(threads.count) sessions; no messages sent")
    }
}
