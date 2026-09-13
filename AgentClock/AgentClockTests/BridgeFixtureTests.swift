import XCTest

final class BridgeFixtureTests: XCTestCase {
    private var bridgeURL: URL {
        Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/AgentClockBridge")
    }

    private func normalize(provider: String, event: String, json: String,
                           environment: [String: String] = [:]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = bridgeURL
        process.arguments = ["--provider", provider, "--event", event, "--dry-run-report"]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(json.utf8)); try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAntigravityIdentityAndWaiting() throws {
        let report = try normalize(provider: "antigravity", event: "PreToolUse", json: #"""
        {
          "conversationId":"conversation-1","workspacePaths":["/repo"],
          "toolCall":{"name":"ask_question","args":{}}
        }
        """#)
        XCTAssertEqual(report["source"] as? String, "antigravity-cli")
        XCTAssertEqual(report["session"] as? String, "conversation-1")
        XCTAssertEqual(report["cwd"] as? String, "/repo")
        XCTAssertEqual(report["state"] as? String, "waiting")
    }

    func testClaudeSubagentPreservesParentIdentity() throws {
        let report = try normalize(provider: "claude", event: "SubagentStart", json: #"""
        {
          "session_id":"parent-1","agent_id":"worker-2","agent_type":"Explore","cwd":"/repo"
        }
        """#)
        XCTAssertEqual(report["session"] as? String, "worker-2")
        XCTAssertEqual(report["parentSession"] as? String, "parent-1")
        XCTAssertEqual(report["agent"] as? String, "Explore")
        XCTAssertEqual(report["state"] as? String, "thinking")
    }

    func testFailureBeatsToolState() throws {
        let report = try normalize(provider: "qwen", event: "PostToolUseFailure",
                                   json: #"{"session_id":"q1","cwd":"/repo","error":"boom"}"#)
        XCTAssertEqual(report["state"] as? String, "error")
        XCTAssertNil(report["error"], "raw error text must not be forwarded")
    }

    func testITermSessionIdentityIsForwarded() throws {
        let report = try normalize(
            provider: "codex", event: "PreToolUse",
            json: #"{"session_id":"c1","cwd":"/repo"}"#,
            environment: ["ITERM_SESSION_ID": "w0t1p0:ABC-123"])
        XCTAssertEqual(report["terminalSession"] as? String, "w0t1p0:ABC-123")
    }

    func testWezTermPaneIdentityIsForwarded() throws {
        let report = try normalize(
            provider: "claude", event: "PreToolUse",
            json: #"{"session_id":"c1","cwd":"/repo"}"#,
            environment: ["WEZTERM_PANE": "42", "WEZTERM_UNIX_SOCKET": "/tmp/wez.sock"])
        XCTAssertEqual(report["terminalKind"] as? String, "wezterm")
        XCTAssertEqual(report["terminalSession"] as? String, "42")
        XCTAssertEqual(report["terminalEndpoint"] as? String, "/tmp/wez.sock")
    }

    func testKittyWindowIdentityIsForwarded() throws {
        let report = try normalize(
            provider: "cursor", event: "afterFileEdit",
            json: #"{"conversation_id":"cursor-1","workspace_roots":["/repo"]}"#,
            environment: ["KITTY_WINDOW_ID": "7", "KITTY_LISTEN_ON": "unix:/tmp/kitty.sock"])
        XCTAssertEqual(report["source"] as? String, "cursor")
        XCTAssertEqual(report["cwd"] as? String, "/repo")
        XCTAssertEqual(report["state"] as? String, "coding")
        XCTAssertEqual(report["terminalKind"] as? String, "kitty")
        XCTAssertEqual(report["terminalSession"] as? String, "7")
    }

    func testMCPHandshakeAndToolDiscovery() throws {
        let process = Process()
        process.executableURL = bridgeURL
        process.arguments = ["--mcp", "--port", "59999"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        try process.run()
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
        ].joined(separator: "\n") + "\n"
        input.fileHandleForWriting.write(Data(requests.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let initialized = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let result = try XCTUnwrap(initialized["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
        let listed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                       ["show_message", "clear_message", "clock_status"])
    }
}
