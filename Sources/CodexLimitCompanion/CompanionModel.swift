import AppKit
import ApplicationServices
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
    @Published private(set) var recoveryLogs: [RecoveryLog] = []
    @Published var selected: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "targetThreadIds") ?? []) {
        didSet { UserDefaults.standard.set(Array(selected), forKey: "targetThreadIds") }
    }
    @Published var bucketID = UserDefaults.standard.string(forKey: "monitoredBucketID") ?? "" {
        didSet { UserDefaults.standard.set(bucketID, forKey: "monitoredBucketID"); recovery.reset(); changed?() }
    }
    @Published var autoSend = UserDefaults.standard.object(forKey: "autoSendToSelectedThreads") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSend, forKey: "autoSendToSelectedThreads") }
    }
    @Published var autoPaste = UserDefaults.standard.object(forKey: "autoPasteAfterLimitReset") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoPaste, forKey: "autoPasteAfterLimitReset") }
    }
    @Published var submitPaste = UserDefaults.standard.object(forKey: "autoSendAfterPaste") as? Bool ?? true {
        didSet { UserDefaults.standard.set(submitPaste, forKey: "autoSendAfterPaste") }
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
    var changed: (() -> Void)?
    private let logStore: RecoveryLogStore
    private let queueMessage: (String, String) async throws -> Void
    private let loadThreads: () async throws -> [ThreadSummary]
    init(loadThreads: @escaping () async throws -> [ThreadSummary] = CodexAppServerClient.listThreads,
         logStore: RecoveryLogStore = RecoveryLogStore(),
         queueMessage: @escaping (String, String) async throws -> Void = { try await CodexAppServerClient.queueMessage(to: $0, message: $1) }) {
        self.loadThreads = loadThreads
        self.logStore = logStore
        self.queueMessage = queueMessage
        self.recoveryLogs = logStore.load()
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
                if let current, recovery.observe(current) {
                    let trigger = RecoveryTrigger(bucket: current.name)
                    if notify { notifyRecovery() }
                    if autoSend { sendSelected(automaticTrigger: trigger) }
                    if autoPaste { pasteToForeground(automaticTrigger: trigger) }
                    if !autoSend && !autoPaste {
                        record(RecoveryLog(trigger: trigger, threadID: nil, title: "自动发送已关闭", message: message, status: .skipped))
                    }
                }
            } catch { self.error = error.localizedDescription }
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
    func pasteToForeground(automaticTrigger: RecoveryTrigger? = nil) {
        let entry = automaticTrigger.map { RecoveryLog(trigger: $0, threadID: nil, title: "前台会话（无法确认目标）", message: message) }
        if let entry { record(entry) }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { finishLog(entry?.id, status: .skipped, detail: "发送内容为空"); return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { feedback = "前台粘贴需要在系统设置 → 隐私与安全性 → 辅助功能中授权。"; finishLog(entry?.id, status: .failed, detail: feedback); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.chat").first else {
            feedback = "请先打开 Codex 或 ChatGPT，并选择目标会话。"; finishLog(entry?.id, status: .failed, detail: feedback); return
        }
        app.activate(options: [.activateAllWindows])
        let submit = submitPaste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            Self.key(0x09, flags: .maskCommand)
            if submit {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    Self.key(0x24)
                    self.finishLog(entry?.id, status: .submitted, detail: "已模拟回车，无法确认目标会话及是否发送成功。")
                }
            } else { self.finishLog(entry?.id, status: .pasted, detail: "仅粘贴，未自动提交。") }
        }
    }
    private static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for pressed in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: pressed)
            event?.flags = flags; event?.post(tap: .cghidEventTap)
        }
    }
}
