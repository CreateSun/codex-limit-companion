import XCTest
@testable import CodexLimitCompanion

final class RecoveryLogTests: XCTestCase {
    func testEstimateWaitsForAllExhaustedWindowsAndRejectsUnknown() {
        let now = Date(timeIntervalSince1970: 1000)
        func window(_ id: String, _ time: Double?) -> QuotaWindow {
            QuotaWindow(id: id, used: 100, minutes: 300, resetsAt: time.map(Date.init(timeIntervalSince1970:)))
        }
        func bucket(_ windows: [QuotaWindow]) -> QuotaBucket {
            QuotaBucket(id: "codex", name: "Codex", windows: windows, serverBlocked: true)
        }
        XCTAssertEqual(bucket([window("primary", 2000), window("secondary", 3000)]).estimatedRecovery(after: now), Date(timeIntervalSince1970: 3000))
        XCTAssertNil(bucket([window("primary", nil)]).estimatedRecovery(after: now))
        XCTAssertNil(bucket([window("primary", 900)]).estimatedRecovery(after: now))
        XCTAssertNil(bucket([]).estimatedRecovery(after: now))
    }

    func testPersistenceIsBoundedAndInterruptedSendsAreNotSuccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryLogStore(url: directory.appendingPathComponent("history.json"))
        let trigger = RecoveryTrigger(bucket: "Codex")
        let entries = (0..<350).map { RecoveryLog(trigger: trigger, threadID: "thread-\($0)", title: "会话 \($0)", message: "继续\n精确内容", status: $0 == 0 ? .pending : .queued) }
        store.save([])
        store.save(entries)
        store.flush()
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 300)
        XCTAssertEqual(loaded.first?.status, .interrupted)
        XCTAssertEqual(loaded.first?.message, "继续\n精确内容")
        XCTAssertEqual(loaded[1].status, .queued)
        XCTAssertEqual(loaded[1].trigger.id, trigger.id)
        XCTAssertEqual(loaded.last?.threadID, "thread-299")
    }

    @MainActor
    func testAutomaticPerThreadOutcomesWithMockSender() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults.standard
        let savedIDs = defaults.object(forKey: "targetThreadIds")
        let savedMessage = defaults.object(forKey: "recoveryText")
        defer {
            defaults.set(savedIDs, forKey: "targetThreadIds")
            defaults.set(savedMessage, forKey: "recoveryText")
        }
        let store = RecoveryLogStore(url: directory.appendingPathComponent("history.json"))
        var sent: [String] = []
        let model = CompanionModel(loadThreads: { [] }, logStore: store, queueMessage: { id, text in
            sent.append(id)
            XCTAssertEqual(text, "测试恢复消息")
            if id == "b" { throw CocoaError(.fileReadUnknown) }
        })
        model.selected = ["a", "b"]
        model.message = "测试恢复消息"
        model.sendSelected(automaticTrigger: RecoveryTrigger(bucket: "Codex"))
        for _ in 0..<100 where model.sending { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.sending)
        XCTAssertEqual(sent, ["a", "b"])
        XCTAssertEqual(model.recoveryLogs.first { $0.threadID == "a" }?.status, .queued)
        XCTAssertEqual(model.recoveryLogs.first { $0.threadID == "b" }?.status, .failed)
        XCTAssertTrue(model.recoveryLogs.allSatisfy { $0.completedAt != nil && $0.message == "测试恢复消息" })
        model.flushLogs()
        XCTAssertEqual(store.load().count, 2)
    }
}
