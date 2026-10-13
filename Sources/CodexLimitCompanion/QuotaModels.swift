import Foundation

struct QuotaWindow: Identifiable, Equatable {
    let id: String
    let used: Double
    let minutes: Int?
    let resetsAt: Date?
    var remaining: Double { max(0, min(100, 100 - used)) }
    var title: String {
        guard let minutes else { return id == "primary" ? "短周期" : "长周期" }
        if minutes == 10080 { return "每周额度" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时额度" }
        return "\(minutes) 分钟额度"
    }
}

struct QuotaBucket: Identifiable, Equatable {
    let id: String
    let name: String
    let windows: [QuotaWindow]
    let serverBlocked: Bool
    var shortWindow: QuotaWindow? { windows.min { ($0.minutes ?? Int.max) < ($1.minutes ?? Int.max) } }
    var blocked: Bool { serverBlocked || windows.contains { $0.used >= 100 } }
    static func decode(_ raw: Any?) throws -> [QuotaBucket] {
        guard let result = raw as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        let map = result["rateLimitsByLimitId"] as? [String: Any] ?? [:]
        var entries = map.sorted { $0.key < $1.key }.compactMap { key, value -> (String, [String: Any])? in
            guard let value = value as? [String: Any] else { return nil }
            return (key, value)
        }
        if entries.isEmpty, let legacy = result["rateLimits"] as? [String: Any] { entries = [("codex", legacy)] }
        let buckets = entries.map { key, bucket in
            let windows = ["primary", "secondary"].compactMap { kind -> QuotaWindow? in
                guard let data = bucket[kind] as? [String: Any], let used = data["usedPercent"] as? NSNumber,
                      used.doubleValue.isFinite else { return nil }
                return QuotaWindow(id: kind, used: used.doubleValue,
                    minutes: (data["windowDurationMins"] as? NSNumber)?.intValue,
                    resetsAt: (data["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
            }
            let reached = bucket["rateLimitReachedType"]
            return QuotaBucket(id: key, name: (bucket["limitName"] as? String) ?? (bucket["name"] as? String) ?? key,
                windows: windows, serverBlocked: reached != nil && !(reached is NSNull))
        }
        guard !buckets.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return buckets
    }
}

struct ThreadSummary: Identifiable {
    let id: String
    let preview: String
    let cwd: String
    let updatedAt: Date?
    var title: String { preview.split(separator: "\n").first.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? String(id.prefix(12)) }
    var project: String { cwd.isEmpty ? "独立会话" : URL(fileURLWithPath: cwd).lastPathComponent }
}

/// A bucket switch, missing data, or first observation never counts as recovery.
struct RecoveryTracker {
    private var previous: [String: Bool] = [:]
    mutating func reset() { previous = [:] }
    mutating func observe(_ bucket: QuotaBucket) -> Bool {
        guard !bucket.windows.isEmpty else { previous.removeValue(forKey: bucket.id); return false }
        let recovered = previous[bucket.id] == true && !bucket.blocked
        previous[bucket.id] = bucket.blocked
        return recovered
    }
}
