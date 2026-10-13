import XCTest
@testable import CodexLimitCompanion

final class RPCConnectionTests: XCTestCase {
    private func mock(_ script: String, timeout: Double = 2) -> RPCConnection {
        RPCConnection(timeout: timeout) { (URL(fileURLWithPath: "/usr/bin/python3"), ["-u", "-c", script], ProcessInfo.processInfo.environment) }
    }
    func testReusesOneProcessAndWaitsForHandshakeWhileDrainingStderr() async throws {
        let connection = mock("""
        import os, sys, json
        ready = False
        for line in sys.stdin:
            m = json.loads(line)
            if m['method'] == 'initialize':
                sys.stderr.write('x' * 200000); sys.stderr.flush()
                print(json.dumps({'id':m['id'], 'result':{}}), flush=True)
            elif m['method'] == 'initialized':
                ready = True
            else:
                reply = {'id':m['id'], 'result':{'pid':os.getpid(), 'ready':ready}}
                wire = (json.dumps(reply)+'\\n').encode()
                os.write(1, wire[:10]); os.write(1, wire[10:])
        """)
        defer { connection.shutdown() }
        async let first = connection.request("first", params: [:])
        async let second = connection.request("second", params: [:])
        let (a, b) = try await (first, second)
        let one = try XCTUnwrap(a as? [String: Any]), two = try XCTUnwrap(b as? [String: Any])
        XCTAssertEqual(one["pid"] as? Int, two["pid"] as? Int)
        XCTAssertEqual(one["ready"] as? Bool, true)
        XCTAssertEqual(two["ready"] as? Bool, true)
        let third = try await connection.request("third", params: [:]) as? [String: Any]
        XCTAssertEqual(one["pid"] as? Int, third?["pid"] as? Int)
    }
    func testEOFCompletesWithoutWaitingForTimeout() async {
        // Use a native immediate-exit fixture so interpreter startup is not part of EOF timing.
        let connection = RPCConnection(timeout: 10) {
            (URL(fileURLWithPath: "/usr/bin/true"), [], ProcessInfo.processInfo.environment)
        }
        defer { connection.shutdown() }
        let start = Date()
        do { _ = try await connection.request("read", params: [:]); XCTFail("Expected EOF failure") }
        catch { XCTAssertLessThan(Date().timeIntervalSince(start), 3) }
    }
    func testTimeoutCanReconnectAndShutdownKillsChild() async throws {
        let connection = mock("""
        import os, sys, json, signal
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        for line in sys.stdin:
            m = json.loads(line)
            if m['method'] == 'initialize': print(json.dumps({'id':1, 'result':{}}), flush=True)
            elif m['method'] == 'pid': print(json.dumps({'id':m['id'], 'result':os.getpid()}), flush=True)
        """, timeout: 0.5)
        defer { connection.shutdown() }
        let firstValue = try await connection.request("pid", params: [:])
        let first = try XCTUnwrap(firstValue as? Int)
        do { _ = try await connection.request("hang", params: [:]); XCTFail("Expected timeout") } catch {}
        let secondValue = try await connection.request("pid", params: [:])
        let second = try XCTUnwrap(secondValue as? Int)
        XCTAssertNotEqual(first, second)
        connection.shutdown()
        for _ in 0..<30 {
            if kill(Int32(first), 0) != 0 && kill(Int32(second), 0) != 0 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Child process remains after cleanup")
    }
}
