import Foundation

enum CodexAppServerClient {
    static func readLimits() async throws -> [QuotaBucket] {
        try QuotaBucket.decode(try await rpc("account/rateLimits/read", params: [:]))
    }

    static func listThreads() async throws -> [ThreadSummary] {
        let result = try await rpc("thread/list", params: ["limit": 100])
        guard let data = (result as? [String: Any])?["data"] as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var seen = Set<String>()
        return data.compactMap { dict in
            guard let id = dict["id"] as? String, seen.insert(id).inserted else { return nil }
            return ThreadSummary(
                id: id,
                preview: (dict["name"] as? String) ?? (dict["preview"] as? String) ?? "",
                cwd: (dict["cwd"] as? String) ?? "",
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

    private static let connection = RPCConnection {
        let command = codexCommand(for: ["app-server"])
        return (command.executable, command.arguments, childEnvironment())
    }

    static func shutdown() { connection.shutdown() }

    private static func rpc(_ method: String, params: [String: Any]) async throws -> Any? {
        try await connection.request(method, params: params)
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
