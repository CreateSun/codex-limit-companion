import XCTest
@testable import CodexLimitCompanion

@MainActor
final class SessionCacheTests: XCTestCase {
    private func finish(_ model: CompanionModel) async throws {
        for _ in 0..<100 {
            if !model.loadingThreads { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Session load did not finish")
    }
    func testOpeningUsesCacheAndManualRefreshRetainsRows() async throws {
        var calls = 0
        let model = CompanionModel(loadThreads: {
            calls += 1
            return [ThreadSummary(id: "one", preview: "Test", cwd: "", updatedAt: nil)]
        })
        XCTAssertEqual(calls, 0)
        model.refreshThreadsIfNeeded()
        model.refreshThreadsIfNeeded()
        try await finish(model)
        XCTAssertEqual(calls, 1)
        for _ in 0..<20 { model.refreshThreadsIfNeeded() }
        XCTAssertEqual(calls, 1)
        model.refreshThreads()
        XCTAssertEqual(model.threads.count, 1)
        try await finish(model)
        XCTAssertEqual(calls, 2)
    }
    func testFailureDoesNotRetryOnEveryOpen() async throws {
        var calls = 0
        let model = CompanionModel(loadThreads: { calls += 1; throw CocoaError(.fileReadUnknown) })
        model.refreshThreadsIfNeeded()
        try await finish(model)
        XCTAssertNotNil(model.threadError)
        model.refreshThreadsIfNeeded()
        try await finish(model)
        XCTAssertEqual(calls, 1)
        model.refreshThreads()
        try await finish(model)
        XCTAssertEqual(calls, 2)
    }
}
