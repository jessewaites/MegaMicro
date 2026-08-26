import XCTest

final class BridgeFixtureTests: XCTestCase {
    private var bridgeURL: URL {
        Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/MegaMicroBridge")
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

    func testCmuxSurfaceIdentityIsForwarded() throws {
        let report = try normalize(
            provider: "claude", event: "PreToolUse",
            json: #"{"session_id":"c1","cwd":"/repo"}"#,
            environment: ["CMUX_SURFACE_ID": "83F4E6A4-5246-4DB8-A412-9CE7B059FA6C"])
        XCTAssertEqual(report["terminalKind"] as? String, "cmux")
        XCTAssertEqual(report["terminalSession"] as? String, "83F4E6A4-5246-4DB8-A412-9CE7B059FA6C")
    }

    // cmux draws with libghostty and reports TERM_PROGRAM to match, so the
    // surface id has to be read before any of the generic terminal probes or a
    // cmux session gets filed under the wrong terminal.
    func testCmuxWinsOverTerminalProgramAndInheritedTerminalIDs() throws {
        let report = try normalize(
            provider: "claude", event: "PreToolUse",
            json: #"{"session_id":"c1","cwd":"/repo"}"#,
            environment: [
                "CMUX_SURFACE_ID": "83F4E6A4-5246-4DB8-A412-9CE7B059FA6C",
                "TERM_PROGRAM": "ghostty",
                "ITERM_SESSION_ID": "w0t1p0:ABC-123",
            ])
        XCTAssertEqual(report["terminalKind"] as? String, "cmux")
        XCTAssertEqual(report["terminalSession"] as? String, "83F4E6A4-5246-4DB8-A412-9CE7B059FA6C")
    }

    // cmux mints a fresh workspace id on every restore, so recording one would
    // send the key to a workspace that no longer exists.
    func testCmuxWorkspaceIDIsNotRecorded() throws {
        let report = try normalize(
            provider: "claude", event: "PreToolUse",
            json: #"{"session_id":"c1","cwd":"/repo"}"#,
            environment: [
                "CMUX_SURFACE_ID": "83F4E6A4-5246-4DB8-A412-9CE7B059FA6C",
                "CMUX_WORKSPACE_ID": "9B6920C1-6C29-4C27-A069-78CF285F932A",
            ])
        XCTAssertNil(report["terminalEndpoint"] as? String)
    }
}
