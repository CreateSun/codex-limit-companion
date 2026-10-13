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
    private let loadThreads: () async throws -> [ThreadSummary]
    init(loadThreads: @escaping () async throws -> [ThreadSummary] = CodexAppServerClient.listThreads) {
        self.loadThreads = loadThreads
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
                    if notify { notifyRecovery() }
                    if autoSend { sendSelected() }
                    if autoPaste { pasteToForeground() }
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
    func sendSelected() {
        guard !sending, !selected.isEmpty, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let ids = selected.sorted(), text = message
        sending = true
        Task {
            var failed: [String] = []
            for id in ids {
                do { try await CodexAppServerClient.queueMessage(to: id, message: text) }
                catch { failed.append("\(id.prefix(8))：\(error.localizedDescription)") }
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
    func pasteToForeground() {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { feedback = "前台粘贴需要在系统设置 → 隐私与安全性 → 辅助功能中授权。"; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.chat").first else {
            feedback = "请先打开 Codex 或 ChatGPT，并选择目标会话。"; return
        }
        app.activate(options: [.activateAllWindows])
        let submit = submitPaste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            Self.key(0x09, flags: .maskCommand)
            if submit { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Self.key(0x24) } }
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
