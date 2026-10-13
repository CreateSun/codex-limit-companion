import Foundation

struct RecoveryTrigger: Codable {
    let id: UUID
    let date: Date
    let bucket: String
    init(date: Date = Date(), bucket: String) { id = UUID(); self.date = date; self.bucket = bucket }
}

struct RecoveryLog: Identifiable, Codable {
    enum Status: String, Codable {
        case pending, queued, failed, skipped, pasted, submitted, interrupted
        var label: String {
            switch self {
            case .pending: return "发送中"
            case .queued: return "已排队"
            case .failed: return "失败"
            case .skipped: return "已跳过"
            case .pasted: return "已粘贴"
            case .submitted: return "已模拟提交"
            case .interrupted: return "结果未确认"
            }
        }
    }
    let id: UUID
    let trigger: RecoveryTrigger
    let threadID: String?
    let title: String
    let message: String
    var status: Status
    var detail: String?
    var completedAt: Date?
    init(trigger: RecoveryTrigger, threadID: String?, title: String, message: String, status: Status = .pending, detail: String? = nil) {
        self.id = UUID(); self.trigger = trigger; self.threadID = threadID
        self.title = title; self.message = message; self.status = status; self.detail = detail
    }
}

/// Bounded local history. Serial writes keep old snapshots from overwriting newer ones.
final class RecoveryLogStore {
    static let limit = 300
    private let url: URL
    private let queue = DispatchQueue(label: "companion.recovery-history", qos: .utility)
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CodexLimitCompanion/recovery-history.json")) { self.url = url }
    func load() -> [RecoveryLog] {
        guard let data = try? Data(contentsOf: url), let logs = try? JSONDecoder().decode([RecoveryLog].self, from: data) else { return [] }
        return logs.prefix(Self.limit).map { entry in
            var entry = entry
            if entry.status == .pending { entry.status = .interrupted; entry.detail = "上次退出时发送尚未返回，未自动重试。" }
            return entry
        }
    }
    func save(_ logs: [RecoveryLog]) {
        let snapshot = Array(logs.prefix(Self.limit)), url = url
        queue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { NSLog("Recovery history could not be saved: %@", error.localizedDescription) }
        }
    }
    func flush() { queue.sync {} }
}

extension QuotaBucket {
    /// Recovery needs every exhausted window to reset. Server-only restrictions have no reliable ETA.
    func estimatedRecovery(after now: Date) -> Date? {
        let exhausted = windows.filter { $0.used >= 100 }
        guard !exhausted.isEmpty else { return nil }
        let dates = exhausted.compactMap(\.resetsAt)
        guard dates.count == exhausted.count, let date = dates.max(), date > now else { return nil }
        return date
    }
}
