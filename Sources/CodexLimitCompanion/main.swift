import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import UserNotifications

private let autoPasteKey = "autoPasteAfterLimitReset"
private let autoSendKey = "autoSendAfterPaste"
private let autoSendToThreadsKey = "autoSendToSelectedThreads"
private let targetThreadsKey = "targetThreadIds"
private let recoveryTextKey = "recoveryText"

@main
struct CodexLimitCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = LimitMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            autoPasteKey: true,
            autoSendKey: true,
            autoSendToThreadsKey: true,
            recoveryTextKey: "额度已恢复，请继续处理上一个任务。"
        ])
        monitor.start()
    }
}

@MainActor
final class LimitMonitor: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var wasReached = false
    private var lastResetSent: Int?

    private var threads: [ThreadSummary] = []
    private var selectedThreadIds: Set<String> = Set(UserDefaults.standard.stringArray(forKey: targetThreadsKey) ?? [])
    private var sessionsSubmenu: NSMenu?

    func start() {
        statusItem.button?.title = "Codex: …"
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        Task {
            do {
                let snapshot = try await CodexAppServerClient.readLimit()
                update(snapshot)
            } catch {
                statusItem.button?.title = "Codex: error"
                statusItem.button?.toolTip = error.localizedDescription
            }
        }
    }

    private func update(_ snapshot: LimitSnapshot) {
        let reset = Date(timeIntervalSince1970: TimeInterval(snapshot.resetsAt))
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        statusItem.button?.title = "Codex: 剩余 \(snapshot.remainingPercent)%"
        statusItem.button?.toolTip = "剩余 \(snapshot.remainingPercent)%（已用 \(snapshot.usedPercent)%）· \(snapshot.windowMinutes) 分钟窗口；\(snapshot.reached ? "已达限" : "可用")；重置 \(formatter.string(from: reset))"

        if wasReached && !snapshot.reached && lastResetSent != snapshot.resetsAt {
            lastResetSent = snapshot.resetsAt
            notifyRecovery()
            if UserDefaults.standard.bool(forKey: autoPasteKey) {
                pasteIntoChatGPT()
            }
            if UserDefaults.standard.bool(forKey: autoSendToThreadsKey) {
                sendRecoveryToSelectedThreads()
            }
        }
        wasReached = snapshot.reached
        rebuildMenu(snapshot)
    }

    private func notifyRecovery() {
        let notification = UNMutableNotificationContent()
        notification.title = "Codex 额度已恢复"
        notification.body = UserDefaults.standard.string(forKey: recoveryTextKey) ?? ""
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: notification, trigger: nil))
    }

    private func rebuildMenu(_ snapshot: LimitSnapshot? = nil) {
        let menu = NSMenu()
        let state = snapshot.map { "剩余 \($0.remainingPercent)%（已用 \($0.usedPercent)%）· \($0.windowMinutes) 分钟窗口" } ?? "正在读取额度…"
        menu.addItem(withTitle: state, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "粘贴到 ChatGPT", action: #selector(pasteFromMenu), keyEquivalent: "v").target = self

        let sendSelected = menu.addItem(
            withTitle: selectedThreadIds.isEmpty ? "发送到已选会话" : "发送到已选会话（\(selectedThreadIds.count)）",
            action: #selector(sendToSelectedFromMenu), keyEquivalent: ""
        )
        sendSelected.target = self
        sendSelected.isEnabled = !selectedThreadIds.isEmpty

        let sessionsMenu = NSMenu()
        sessionsMenu.delegate = self
        sessionsSubmenu = sessionsMenu
        let sessionsItem = menu.addItem(withTitle: "发送到会话…", action: nil, keyEquivalent: "")
        menu.setSubmenu(sessionsMenu, for: sessionsItem)
        let loading = sessionsMenu.addItem(withTitle: "打开时刷新会话列表", action: nil, keyEquivalent: "")
        loading.isEnabled = false

        menu.addItem(.separator())
        let autoPaste = menu.addItem(withTitle: "额度恢复时自动粘贴", action: #selector(toggleAutoPaste), keyEquivalent: "")
        autoPaste.target = self
        autoPaste.state = UserDefaults.standard.bool(forKey: autoPasteKey) ? .on : .off
        let autoSend = menu.addItem(withTitle: "粘贴后自动发送", action: #selector(toggleAutoSend), keyEquivalent: "")
        autoSend.target = self
        autoSend.state = UserDefaults.standard.bool(forKey: autoSendKey) ? .on : .off
        let autoSendToThreads = menu.addItem(withTitle: "额度恢复时自动发送到会话", action: #selector(toggleAutoSendToThreads), keyEquivalent: "")
        autoSendToThreads.target = self
        autoSendToThreads.state = UserDefaults.standard.bool(forKey: autoSendToThreadsKey) ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func refreshFromMenu() { refresh() }
    @objc private func pasteFromMenu() { pasteIntoChatGPT() }
    @objc private func toggleAutoPaste() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: autoPasteKey), forKey: autoPasteKey)
        rebuildMenu()
    }

    @objc private func toggleAutoSend() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: autoSendKey), forKey: autoSendKey)
        rebuildMenu()
    }

    @objc private func toggleAutoSendToThreads() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: autoSendToThreadsKey), forKey: autoSendToThreadsKey)
        rebuildMenu()
    }

    @objc private func sendToSelectedFromMenu() {
        sendRecoveryToSelectedThreads()
    }

    /// 把恢复消息通过 codex queue 发送到所有已选会话(不依赖 UI 焦点,可指定多个)。
    private func sendRecoveryToSelectedThreads() {
        let message = UserDefaults.standard.string(forKey: recoveryTextKey) ?? ""
        let ids = selectedThreadIds.sorted()
        guard !ids.isEmpty else { return }
        Task {
            var failures: [String] = []
            for id in ids {
                do { try await CodexAppServerClient.queueMessage(to: id, message: message) }
                catch { failures.append("\(id.prefix(8))…：\(error.localizedDescription)") }
            }
            if !failures.isEmpty {
                showAlert("发送到会话失败", failures.joined(separator: "\n"))
            }
        }
    }

    // MARK: - 会话选择

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === sessionsSubmenu else { return }
        refreshThreads()
    }

    @objc private func refreshThreadsFromMenu() {
        refreshThreads()
    }

    private func refreshThreads() {
        guard let sessionsSubmenu else { return }
        sessionsSubmenu.removeAllItems()
        let loading = sessionsSubmenu.addItem(withTitle: "正在加载会话列表…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        Task {
            do {
                let list = try await CodexAppServerClient.listThreads()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.threads = list
                    self.rebuildSessionsSubmenu()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, let sessionsSubmenu = self.sessionsSubmenu else { return }
                    sessionsSubmenu.removeAllItems()
                    let failed = sessionsSubmenu.addItem(withTitle: "加载失败：\(error.localizedDescription)", action: nil, keyEquivalent: "")
                    failed.isEnabled = false
                    let retry = sessionsSubmenu.addItem(withTitle: "重试", action: #selector(self.refreshThreadsFromMenu), keyEquivalent: "")
                    retry.target = self
                }
            }
        }
    }

    private func rebuildSessionsSubmenu() {
        guard let sessionsSubmenu else { return }
        sessionsSubmenu.removeAllItems()
        if threads.isEmpty {
            let empty = sessionsSubmenu.addItem(withTitle: "（没有找到会话）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        } else {
            for thread in threads {
                let item = sessionsSubmenu.addItem(withTitle: title(for: thread), action: #selector(toggleThreadSelection(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = thread.id
                item.state = selectedThreadIds.contains(thread.id) ? .on : .off
                item.toolTip = thread.preview
            }
        }
        sessionsSubmenu.addItem(.separator())
        let selectAll = sessionsSubmenu.addItem(withTitle: "全选", action: #selector(selectAllThreads), keyEquivalent: "")
        selectAll.target = self
        let deselectAll = sessionsSubmenu.addItem(withTitle: "全不选", action: #selector(deselectAllThreads), keyEquivalent: "")
        deselectAll.target = self
        let refresh = sessionsSubmenu.addItem(withTitle: "刷新列表", action: #selector(refreshThreadsFromMenu), keyEquivalent: "")
        refresh.target = self
    }

    private func title(for thread: ThreadSummary) -> String {
        let line = thread.preview.split(separator: "\n").first.map(String.init) ?? ""
        let truncated = line.count > 40 ? String(line.prefix(40)) + "…" : line
        let date: String
        if let updated = thread.updatedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            date = formatter.string(from: updated)
        } else {
            date = ""
        }
        let text = truncated.isEmpty ? "\(thread.id.prefix(12))…" : truncated
        return date.isEmpty ? text : "\(date)  \(text)"
    }

    @objc private func toggleThreadSelection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if selectedThreadIds.contains(id) {
            selectedThreadIds.remove(id)
        } else {
            selectedThreadIds.insert(id)
        }
        UserDefaults.standard.set(Array(selectedThreadIds), forKey: targetThreadsKey)
        rebuildSessionsSubmenu()
        rebuildMenu()
    }

    @objc private func selectAllThreads() {
        selectedThreadIds = Set(threads.map(\.id))
        UserDefaults.standard.set(Array(selectedThreadIds), forKey: targetThreadsKey)
        rebuildSessionsSubmenu()
        rebuildMenu()
    }

    @objc private func deselectAllThreads() {
        selectedThreadIds = []
        UserDefaults.standard.set([], forKey: targetThreadsKey)
        rebuildSessionsSubmenu()
        rebuildMenu()
    }

    private func pasteIntoChatGPT() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            showAlert("需要“辅助功能”权限", "请在系统设置 → 隐私与安全性 → 辅助功能中允许 CodexLimitCompanion，然后重试。")
            return
        }
        let text = UserDefaults.standard.string(forKey: recoveryTextKey) ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first {
            app.activate(options: [.activateAllWindows])
        } else {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/ChatGPT.app"), configuration: .init()) { _, _ in }
        }
        let shouldSend = UserDefaults.standard.bool(forKey: autoSendKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.postPaste()
            guard shouldSend else { return }
            // 给粘贴留出落地时间，再按回车发送。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.pressReturn()
            }
        }
    }

    /// 发送 ⌘V 粘贴。
    private func postPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }

    /// 发送回车键，触发 ChatGPT/Codex 输入框提交。
    private func pressReturn() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
        up?.post(tap: .cghidEventTap)
    }

    private func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

struct LimitSnapshot {
    let usedPercent: Int
    let windowMinutes: Int
    let resetsAt: Int
    let reached: Bool

    /// ChatGPT 客户端展示的是「剩余用量」口径(剩余 = 100 - 已用)。
    var remainingPercent: Int { max(0, 100 - usedPercent) }
}

/// Codex 会话摘要,来自 app-server 的 thread/list。
struct ThreadSummary {
    let id: String
    let preview: String
    let updatedAt: Date?
}

enum CodexAppServerClient {
    static func readLimit() async throws -> LimitSnapshot {
        try decodeLimit(try await rpc("account/rateLimits/read", params: [:]))
    }

    static func listThreads() async throws -> [ThreadSummary] {
        let result = try await rpc("thread/list", params: ["limit": 100])
        guard let data = (result as? [String: Any])?["data"] as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data.compactMap { dict in
            guard let id = dict["id"] as? String else { return nil }
            return ThreadSummary(
                id: id,
                preview: (dict["preview"] as? String) ?? "",
                updatedAt: (dict["updatedAt"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
    }

    /// 通过 codex queue 向指定会话投递消息,不依赖 UI 焦点,可对多个会话逐个调用。
    static func queueMessage(to threadId: String, message: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let command = codexCommand(for: ["queue", "--thread", threadId, "--message", message])
            process.executableURL = command.executable
            process.arguments = command.arguments
            process.environment = Self.childEnvironment()
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let detail = String(data: stderr.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                    let summary = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: NSError(domain: "Codex", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: summary.isEmpty ? "codex queue 退出码 \(proc.terminationStatus)" : summary
                    ]))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    /// 向 codex app-server 发一次 JSON-RPC 请求,返回对应 id 的 result。
    private static func rpc(_ method: String, params: [String: Any], id: Int = 2) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let command = codexCommand(for: ["app-server"])
            process.executableURL = command.executable
            process.arguments = command.arguments
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            process.environment = Self.childEnvironment()
            let lock = NSLock()
            var completed = false
            func finish(_ result: Result<Any?, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !completed else { return }
                completed = true
                if process.isRunning { process.terminate() }
                continuation.resume(with: result)
            }
            var pending = Data()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                pending.append(handle.availableData)
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: newline)
                    pending.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          (object["id"] as? Int) == id else { continue }
                    if let error = object["error"] {
                        let message = (error as? [String: Any])?["message"] as? String ?? "\(error)"
                        finish(.failure(NSError(domain: "Codex", code: 1, userInfo: [NSLocalizedDescriptionKey: message])))
                    } else {
                        finish(.success(object["result"]))
                    }
                }
            }
            process.terminationHandler = { _ in
                guard !completed else { return }
                let message = String(data: stderr.fileHandleForReading.availableData, encoding: .utf8) ?? "Codex App Server exited."
                finish(.failure(NSError(domain: "Codex", code: 2, userInfo: [NSLocalizedDescriptionKey: message])))
            }
            do {
                try process.run()
                func send(_ object: [String: Any]) { stdin.fileHandleForWriting.write(try! JSONSerialization.data(withJSONObject: object) + Data([10])) }
                send(["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "codex-limit-companion", "title": "Codex Limit Companion", "version": "0.0.1"]]])
                send(["method": "initialized", "params": [:]])
                send(["method": method, "id": id, "params": params])
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) { finish(.failure(NSError(domain: "Codex", code: 3, userInfo: [NSLocalizedDescriptionKey: "Timed out talking to Codex App Server."]))) }
            } catch { finish(.failure(error)) }
        }
    }

    private static func decodeLimit(_ raw: Any?) throws -> LimitSnapshot {
        guard let result = raw as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        let map = result["rateLimitsByLimitId"] as? [String: Any] ?? [:]
        let candidates = (map.values.compactMap { $0 as? [String: Any] } + [result["rateLimits"] as? [String: Any]].compactMap { $0 })
        guard let bucket = candidates.min(by: { score($0) < score($1) }), let primary = bucket["primary"] as? [String: Any],
              let used = primary["usedPercent"] as? Int, let minutes = primary["windowDurationMins"] as? Int,
              let reset = primary["resetsAt"] as? Int else { throw CocoaError(.fileReadCorruptFile) }
        let reached = bucket["rateLimitReachedType"] != nil && !(bucket["rateLimitReachedType"] is NSNull) || used >= 100
        return LimitSnapshot(usedPercent: used, windowMinutes: minutes, resetsAt: reset, reached: reached)
    }

    private static func duration(_ bucket: [String: Any]) -> Int {
        (bucket["primary"] as? [String: Any])?["windowDurationMins"] as? Int ?? .max
    }

    private static func score(_ bucket: [String: Any]) -> Int {
        abs(duration(bucket) - 300)
    }

    /// 构造子进程环境:把 codex / node 所在目录补进 PATH。
    /// 从 Finder 启动的应用 PATH 只有系统目录,codex 脚本的 `#!/usr/bin/env node` 找不到解释器,
    /// 子进程会立即以 "env: node: No such file or directory" 退出。这里先动态定位 codex 与 node
    /// 的安装目录并注入 PATH,不写死用户目录。
    private static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existingDirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var prefix: [String] = []
        for dir in CodexLocator.runtimeDirectories() where !existingDirs.contains(dir) && !prefix.contains(dir) {
            prefix.append(dir)
        }
        guard !prefix.isEmpty else { return env }
        var parts = prefix
        if let current = env["PATH"], !current.isEmpty { parts.append(current) }
        env["PATH"] = parts.joined(separator: ":")
        return env
    }

    private static func codexCommand() -> (executable: URL, arguments: [String]) {
        codexCommand(for: ["app-server"])
    }

    private static func codexCommand(for arguments: [String]) -> (executable: URL, arguments: [String]) {
        if let codex = CodexLocator.codexURL() {
            return (codex, arguments)
        }
        // 未找到独立可执行文件时,交给 PATH 解析 codex 命令(childEnvironment 已注入 node 目录)。
        return (URL(fileURLWithPath: "/usr/bin/env"), ["codex"] + arguments)
    }
}

/// 动态定位 codex 与 node 的可执行文件位置,避免硬编码任何用户目录。
private enum CodexLocator {
    /// 需要补进 PATH 的目录:codex 所在目录 + node 所在目录(去重)。
    static func runtimeDirectories() -> [String] {
        var dirs: [String] = []
        if let d = codexDirectory()?.path, !dirs.contains(d) { dirs.append(d) }
        if let d = nodeDirectory()?.path, !dirs.contains(d) { dirs.append(d) }
        return dirs
    }

    /// codex CLI 路径。优先级:CODEX_CLI_PATH -> PATH -> home 常见安装目录。
    static func codexURL() -> URL? {
        if let p = ProcessInfo.processInfo.environment["CODEX_CLI_PATH"], !p.isEmpty,
           FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        if let p = executableInPath(named: "codex") {
            return URL(fileURLWithPath: p)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for relative in [".n/bin/codex", ".codex/bin/codex", ".local/bin/codex"] {
            let candidate = home.appendingPathComponent(relative)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// codex 所在目录(取符号链接所在目录而非解析后的包目录,node 通常与 codex 同目录)。
    static func codexDirectory() -> URL? {
        codexURL()?.deletingLastPathComponent()
    }

    /// node 解释器所在目录。优先 codex 同目录,其次 PATH,再常见安装位置。
    static func nodeDirectory() -> URL? {
        if let dir = codexDirectory() {
            let node = dir.appendingPathComponent("node")
            if FileManager.default.isExecutableFile(atPath: node.path) { return dir }
        }
        if let p = executableInPath(named: "node") {
            return URL(fileURLWithPath: p).deletingLastPathComponent()
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fallbacks = [
            home.appendingPathComponent(".n/bin/node"),
            home.appendingPathComponent(".volta/bin/node"),
            home.appendingPathComponent(".asdf/shims/node"),
            home.appendingPathComponent(".local/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node"),
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
        ]
        for candidate in fallbacks where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.deletingLastPathComponent()
        }
        return nil
    }

    /// 在当前进程 PATH 中查找可执行文件。
    static func executableInPath(named name: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":").map(String.init) where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}
