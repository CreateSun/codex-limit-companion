import Foundation

/// All connection state is confined to the utility queue, including continuations.
/// A single child serves quota polling and session reads throughout the app lifetime.
final class RPCConnection: @unchecked Sendable {
    typealias Launch = () -> (URL, [String], [String: String])
    private struct Pending {
        let method: String
        let params: [String: Any]
        let continuation: CheckedContinuation<Any?, Error>
        let timeout: DispatchWorkItem
    }
    private let queue = DispatchQueue(label: "companion.codex-rpc", qos: .utility)
    private let launch: Launch
    private let timeoutSeconds: Double
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var buffer = Data()
    private var errorTail = Data()
    private var ready = false
    private var generation = UUID()
    private var nextID = 2
    private var pending: [Int: Pending] = [:]

    init(timeout: Double = 20, launch: @escaping Launch) {
        self.timeoutSeconds = timeout
        self.launch = launch
    }

    func request(_ method: String, params: [String: Any]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let id = self.nextID
                self.nextID += 1
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.pending[id] != nil else { return }
                    self.fail(self.failure("Codex 请求超时，请稍后手动重试。"))
                }
                self.pending[id] = Pending(method: method, params: params, continuation: continuation, timeout: timeout)
                self.queue.asyncAfter(deadline: .now() + self.timeoutSeconds, execute: timeout)
                do {
                    if self.process == nil { try self.start() }
                    else if self.ready { try self.sendRequest(id) }
                } catch { self.fail(error) }
            }
        }
    }

    func shutdown() { queue.sync { fail(failure("Codex 连接已关闭。")) } }

    private func start() throws {
        let (url, arguments, environment) = launch()
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = url
        child.arguments = arguments
        child.environment = environment
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        process = child; input = stdin; output = stdout; errors = stderr
        generation = UUID()
        let token = generation
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            // EOF is permanently readable: detach immediately to avoid a busy loop.
            if bytes.isEmpty { handle.readabilityHandler = nil }
            self?.queue.async { [weak self] in
                guard let self, self.generation == token else { return }
                if bytes.isEmpty { self.fail(self.failure("Codex 连接已断开。")) }
                else { self.receive(bytes) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            self?.queue.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.errorTail.append(bytes)
                self.errorTail = Data(self.errorTail.suffix(4096))
            }
        }
        child.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.fail(self.failure("Codex 后台连接已退出，请手动重试。"))
            }
        }
        try child.run()
        try send(["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "codex-limit-companion", "title": "Codex Limit Companion", "version": "0.0.2"]]])
    }

    private func receive(_ bytes: Data) {
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer.prefix(upTo: newline))
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? Int else { continue }
            if id == 1 {
                if let error = object["error"] { fail(rpcError(error)); return }
                do {
                    try send(["method": "initialized", "params": [:]])
                    ready = true
                    for id in pending.keys.sorted() { try sendRequest(id) }
                } catch { fail(error); return }
            } else if let request = pending.removeValue(forKey: id) {
                request.timeout.cancel()
                if let error = object["error"] { request.continuation.resume(throwing: rpcError(error)) }
                else { request.continuation.resume(returning: object["result"]) }
            }
        }
    }

    private func sendRequest(_ id: Int) throws {
        guard let request = pending[id] else { return }
        try send(["id": id, "method": request.method, "params": request.params])
    }
    private func send(_ object: [String: Any]) throws {
        guard let input else { throw failure("Codex 连接不可用。") }
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: object) + Data([10]))
    }
    private func failure(_ text: String) -> NSError {
        NSError(domain: "Codex", code: 3, userInfo: [NSLocalizedDescriptionKey: text])
    }
    private func rpcError(_ raw: Any) -> NSError {
        failure((raw as? [String: Any])?["message"] as? String ?? "Codex 请求失败。")
    }
    private func fail(_ error: Error) {
        generation = UUID()
        ready = false
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        let old = process
        old?.terminationHandler = nil
        if let old, old.isRunning {
            old.terminate()
            queue.asyncAfter(deadline: .now() + 1) {
                if old.isRunning { kill(old.processIdentifier, SIGKILL) }
            }
        }
        process = nil; input = nil; output = nil; errors = nil
        buffer.removeAll(); errorTail.removeAll()
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}
