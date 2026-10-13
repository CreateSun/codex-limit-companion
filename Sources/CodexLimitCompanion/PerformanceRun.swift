import AppKit
import Foundation

/// Opt-in read-only profiling: never calls recovery, paste, queue, or preference setters.
@MainActor
enum PerformanceRun {
    static func run(model: CompanionModel, path: String) async {
        var events: [[String: Any]] = []
        func event(_ phase: String, _ detail: [String: Any] = [:]) {
            events.append(["phase": phase, "time": Date().timeIntervalSince1970].merging(detail) { _, new in new })
            if let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func load(force: Bool) async {
            if force { model.refreshThreads() } else { model.refreshThreadsIfNeeded() }
            while model.loadingThreads { await pause(0.02) }
        }
        event("startup_idle")
        await pause(5)
        do {
            event("quota_cold")
            let start = Date()
            let buckets = try await CodexAppServerClient.readLimits()
            event("quota_complete", ["duration": Date().timeIntervalSince(start), "buckets": buckets.count])
            await pause(8)
            event("sessions_first")
            let first = Date()
            await load(force: false)
            event("sessions_complete", ["duration": Date().timeIntervalSince(first), "count": model.threads.count, "error": model.threadError ?? ""])
            await pause(5)
            event("cached_100")
            let cached = Date()
            for _ in 0..<100 { model.refreshThreadsIfNeeded() }
            event("cached_complete", ["duration": Date().timeIntervalSince(cached)])
            await pause(3)
            for index in 1...5 {
                event("refresh_\(index)")
                let start = Date()
                await load(force: true)
                event("refresh_\(index)_complete", ["duration": Date().timeIntervalSince(start), "error": model.threadError ?? ""])
                await pause(1)
            }
            event("quota_warm")
            _ = try await CodexAppServerClient.readLimits()
            event("settled_idle")
            await pause(12)
        } catch { event("failed", ["error": error.localizedDescription]) }
        event("shutdown")
        CodexAppServerClient.shutdown()
        await pause(2)
        event("finished")
        NSApplication.shared.terminate(nil)
    }
}
