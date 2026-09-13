import XCTest
@testable import AgentClock

final class CodexHooksInstallerTests: XCTestCase {
    var dir: URL!
    var installer: CodexHooksInstaller!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentclock-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        installer = CodexHooksInstaller(
            hooksURL: dir.appendingPathComponent("hooks.json"),
            configTomlURL: dir.appendingPathComponent("config.toml"),
            backupDir: dir.appendingPathComponent("backups"),
            port: 48812)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func readHooks() throws -> [String: Any] {
        let data = try Data(contentsOf: installer.hooksURL)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInstallCreatesHooksWithTimeouts() throws {
        try installer.install()
        let hooks = try XCTUnwrap(try readHooks()["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(HookEvents.codex.keys))
        let pre = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]]).first
        XCTAssertEqual(pre?["matcher"] as? String, "*")
        let inner = try XCTUnwrap((pre?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(inner["timeout"] as? Int, 2)
        XCTAssertTrue((inner["command"] as? String ?? "").contains("--provider codex"))
        XCTAssertTrue(installer.isInstalled())
    }

    func testUninstallPreservesUserHooks() throws {
        let user: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "echo mine"]]]]]]
        try JSONSerialization.data(withJSONObject: user).write(to: installer.hooksURL)
        try installer.install()
        try installer.uninstall()
        let hooks = try XCTUnwrap(try readHooks()["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        XCTAssertFalse(installer.isInstalled())
    }

    func testEnableFeatureAppendsBlock() throws {
        try "[projects.\"/x\"]\ntrust_level = \"trusted\"\n".write(to: installer.configTomlURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(installer.featureEnabled())
        try installer.enableFeature()
        XCTAssertTrue(installer.featureEnabled())
        let toml = try String(contentsOf: installer.configTomlURL, encoding: .utf8)
        XCTAssertTrue(toml.contains("[features]\ncodex_hooks = true"))
        XCTAssertTrue(toml.contains("trust_level"), "existing content preserved")
    }

    func testEnableFeatureFlipsExistingFalse() throws {
        try "[features]\ncodex_hooks = false\nother = 1\n".write(to: installer.configTomlURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(installer.featureEnabled())
        try installer.enableFeature()
        XCTAssertTrue(installer.featureEnabled())
        let toml = try String(contentsOf: installer.configTomlURL, encoding: .utf8)
        XCTAssertTrue(toml.contains("other = 1"))
        XCTAssertFalse(toml.contains("codex_hooks = false"))
    }

    func testEnableFeatureInsertsUnderExistingFeaturesSection() throws {
        try "[features]\nsomething = true\n\n[projects.\"/x\"]\ntrust_level = \"trusted\"\n"
            .write(to: installer.configTomlURL, atomically: true, encoding: .utf8)
        try installer.enableFeature()
        XCTAssertTrue(installer.featureEnabled())
        let toml = try String(contentsOf: installer.configTomlURL, encoding: .utf8)
        // Must not create a second [features] table.
        XCTAssertEqual(toml.components(separatedBy: "[features]").count, 2)
    }

    func testMalformedHooksAreNeverOverwritten() throws {
        let malformed = Data("[not json]".utf8)
        try malformed.write(to: installer.hooksURL)
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try Data(contentsOf: installer.hooksURL), malformed)
    }
}
