import XCTest
@testable import AgentClock

final class Phase2InstallerTests: XCTestCase {
    var dir: URL!
    let bridge = URL(fileURLWithPath: "/Applications/AgentClock.app/Contents/Resources/AgentClockBridge")
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentclock-phase2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testOpenCodePluginInstallAndUninstall() throws {
        let url = dir.appendingPathComponent("plugins/agentclock.ts")
        let installer = OpenCodeIntegration(pluginURL: url, port: 48812)
        try installer.install()
        let text = try String(contentsOf: url)
        XCTAssertTrue(text.contains("permission.asked"))
        XCTAssertTrue(text.contains("127.0.0.1:48812/state"))
        try installer.uninstall()
        XCTAssertFalse(installer.isInstalled())
    }

    func testCopilotWritesOwnedNativeHookFile() throws {
        let url = dir.appendingPathComponent("hooks/agentclock.json")
        let installer = CopilotIntegration(hooksURL: url, port: 48812, bridgeURL: bridge)
        try installer.install()
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["permissionRequest"])
        XCTAssertNotNil(hooks["subagentStart"])
        XCTAssertTrue(installer.isInstalled())
    }

    func testQwenMergePreservesUnrelatedSettings() throws {
        let settings = dir.appendingPathComponent("settings.json")
        try Data(#"{"theme":"dark","hooks":{"SessionStart":[{"hooks":[{"command":"echo mine"}]}]}}"#.utf8).write(to: settings)
        let installer = QwenIntegration(settingsURL: settings, backupDir: dir.appendingPathComponent("backups"),
                                        port: 48812, bridgeURL: bridge)
        try installer.install()
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual(root["theme"] as? String, "dark")
        try installer.uninstall()
        let after = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let hooks = try XCTUnwrap(after["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["SessionStart"], "user hook survives uninstall")
    }

    func testCursorMergePreservesUnrelatedHooksAndUninstallsOwnedEntries() throws {
        let hooksURL = dir.appendingPathComponent(".cursor/hooks.json")
        try FileManager.default.createDirectory(at: hooksURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"version":1,"theme":"mine","hooks":{"stop":[{"command":"echo mine"}]}}"#.utf8)
            .write(to: hooksURL)
        let installer = CursorIntegration(hooksURL: hooksURL, backupDir: dir.appendingPathComponent("backups"),
                                          port: 48812, bridgeURL: bridge)
        try installer.install()
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any])
        XCTAssertEqual(root["theme"] as? String, "mine")
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["beforeSubmitPrompt"])
        XCTAssertNotNil(hooks["afterFileEdit"])
        XCTAssertTrue(installer.isInstalled())

        try installer.uninstall()
        root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any])
        let remaining = try XCTUnwrap(root["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(remaining["stop"] as? [[String: Any]])
        XCTAssertEqual(stop.first?["command"] as? String, "echo mine")
        XCTAssertNil(remaining["beforeSubmitPrompt"])
    }
}
