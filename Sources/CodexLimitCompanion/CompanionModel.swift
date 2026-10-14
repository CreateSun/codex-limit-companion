import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class CompanionModel: ObservableObject {
    @Published var buckets: [QuotaBucket] = []
    @Published var threads: [ThreadSummary] = []
    @Published var refreshing = false
    @Published var loadingThreads = false
    @Published var sending = false
    @Published var error: String?
    @Published var threadError: String?
    @Published var feedback: String?
    @Published var updatedAt: Date?
    @Published private(set) var waitingForRecovery = false
    @Published private(set) var recoveryLogs: [RecoveryLog] = []
    @Published var selected: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "targetThreadIds") ?? []) {
        didSet { UserDefaults.standard.set(Array(selected), forKey: "targetThreadIds") }
    }
    @Published var bucketID = UserDefaults.standard.string(forKey: "monitoredBucketID") ?? "" {
        didSet { UserDefaults.standard.set(bucketID, forKey: "monitoredBucketID"); recovery.reset(); waitingForRecovery = false; changed?() }
    }
    @Published var autoSend = UserDefaults.standard.object(forKey: "autoSendToSelectedThreads") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSend, forKey: "autoSendToSelectedThreads") }
    }
    @Published var notify = UserDefaults.standard.object(forKey: "notifyOnRecovery") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notify, forKey: "notifyOnRecovery") }
    }
    @Published var showPercent = UserDefaults.standard.bool(forKey: "showMenuPercent") {
        didSet { UserDefaults.standard.set(showPercent, forKey: "showMenuPercent"); changed?() }
    }
    @Published var message = UserDefaults.standard.string(forKey: "recoveryText") ?? "额度已恢复，请继续处理上一个任务。" {
        didSet { UserDefaults.standard.set(message, forKey: "recoveryText") }
    }
    let updater = AppUpdater()
    var changed: (() -> Void)?
    private let logStore: RecoveryLogStore
    private let queueMessage: (String, String) async throws -> Void
    private let loadThreads: () async throws -> [ThreadSummary]
    init(loadThreads: @escaping () async throws -> [ThreadSummary] = CodexAppServerClient.listThreads,
         logStore: RecoveryLogStore = RecoveryLogStore(),
         queueMessage: @escaping (String, String) async throws -> Void = { try await CodexAppServerClient.queueMessage(to: $0, message: $1) }) {
        // Retired: never restore keyboard injection from legacy preferences.
        UserDefaults.standard.set(false, forKey: "autoPasteAfterLimitReset")
        UserDefaults.standard.set(false, forKey: "autoSendAfterPaste")
        self.loadThreads = loadThreads
        self.logStore = logStore
        self.queueMessage = queueMessage
        self.recoveryLogs = logStore.load()
        updater.canInstall = { [weak self] in self?.sending != true }
    }
    func flushLogs() { logStore.flush() }
    private func record(_ entry: RecoveryLog) {
        recoveryLogs.insert(entry, at: 0)
        recoveryLogs = Array(recoveryLogs.prefix(RecoveryLogStore.limit))
        logStore.save(recoveryLogs)
    }
    private func finishLog(_ id: UUID?, status: RecoveryLog.Status, detail: String? = nil) {
        guard let id, let index = recoveryLogs.firstIndex(where: { $0.id == id }) else { return }
        recoveryLogs[index].status = status
        recoveryLogs[index].detail = detail
        recoveryLogs[index].completedAt = Date()
        logStore.save(recoveryLogs)
    }
    private var threadLoadAttempted = false
    private var timer: Timer?
    private var recovery = RecoveryTracker()
    var current: QuotaBucket? { buckets.first { $0.id == bucketID } }
    var remaining: Double? { error == nil ? current?.shortWindow?.remaining : nil }

    func start() {
        updater.start()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            defer { refreshing = false; changed?() }
            do {
                let result = try await CodexAppServerClient.readLimits()
                buckets = result
                if bucketID.isEmpty || (result.count == 1 && current == nil) { bucketID = result.first { $0.id == "codex" }?.id ?? result[0].id }
                error = current == nil ? "所选额度暂不可用，请选择其他额度。" : nil
                updatedAt = Date()
                let recovered = current.map { recovery.observe($0) } ?? false
                waitingForRecovery = current.map { recovery.isWaiting(for: $0.id) } ?? false
                if let current, recovered {
                    let trigger = RecoveryTrigger(bucket: current.name)
                    if notify { notifyRecovery() }
                    if autoSend { sendSelected(automaticTrigger: trigger) }
                    if !autoSend {
                        record(RecoveryLog(trigger: trigger, threadID: nil, title: "自动发送已关闭", message: message, status: .skipped))
                    }
                }
            } catch { recovery.interruptConfirmation(); self.error = error.localizedDescription }
        }
    }
    func refreshThreadsIfNeeded() {
        guard !threadLoadAttempted else { return }
        refreshThreads()
    }
    func refreshThreads() {
        guard !loadingThreads else { return }
        threadLoadAttempted = true
        loadingThreads = true
        Task {
            defer { loadingThreads = false }
            do { threads = try await loadThreads(); threadError = nil }
            catch { threadError = error.localizedDescription }
        }
    }
    func toggle(_ id: String) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
    func sendSelected(automaticTrigger: RecoveryTrigger? = nil) {
        let ids = selected.sorted(), text = message
        guard !sending, !ids.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let trigger = automaticTrigger {
                let reason = sending ? "已有发送进行中" : ids.isEmpty ? "未选择会话" : "发送内容为空"
                record(RecoveryLog(trigger: trigger, threadID: nil, title: reason, message: text, status: .skipped))
            }
            return
        }
        let jobs = ids.map { id -> (String, UUID?) in
            guard let trigger = automaticTrigger else { return (id, nil) }
            let title = threads.first { $0.id == id }?.title ?? "会话 " + String(id.prefix(12))
            let entry = RecoveryLog(trigger: trigger, threadID: id, title: title, message: text)
            record(entry)
            return (id, entry.id)
        }
        sending = true
        Task {
            var failed: [String] = []
            for (id, logID) in jobs {
                do {
                    try await queueMessage(id, text)
                    finishLog(logID, status: .queued, detail: "Codex 已接受排队；不代表任务执行完成。")
                } catch {
                    failed.append("\(id.prefix(8))：\(error.localizedDescription)")
                    finishLog(logID, status: .failed, detail: error.localizedDescription)
                }
            }
            feedback = failed.isEmpty ? "已发送到 \(ids.count) 个会话" : "\(ids.count - failed.count) 个成功；发送失败：\n" + failed.joined(separator: "\n")
            sending = false
        }
    }
    private func notifyRecovery() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Codex 额度已恢复"
            content.body = "可继续处理选中的任务。"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
