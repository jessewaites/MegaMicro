import XCTest
@testable import AgentClock

final class HooksInstallerTests: XCTestCase {
    var dir: URL!
    var installer: HooksInstaller!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentclock-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        installer = HooksInstaller(
            settingsURL: dir.appendingPathComponent("settings.json"),
            backupDir: dir.appendingPathComponent("backups"),
            port: 48812)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeSettings(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        try data.write(to: installer.settingsURL)
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: installer.settingsURL)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInstallPreservesExistingKeys() throws {
        try writeSettings([
            "model": "claude-fable-5",
            "permissions": ["defaultMode": "auto"],
            "enabledPlugins": ["some-plugin": true],
        ])
        try installer.install()

        let settings = try readSettings()
        XCTAssertEqual(settings["model"] as? String, "claude-fable-5")
        XCTAssertEqual((settings["permissions"] as? [String: Any])?["defaultMode"] as? String, "auto")
        XCTAssertEqual((settings["enabledPlugins"] as? [String: Any])?["some-plugin"] as? Bool, true)

        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(HookEvents.claude.keys))
        XCTAssertTrue(installer.isInstalled())
    }

    func testInstallIsIdempotent() throws {
        try writeSettings([:])
        try installer.install()
        try installer.install()

        let hooks = try XCTUnwrap(try readSettings()["hooks"] as? [String: Any])
        for (_, value) in hooks {
            let entries = try XCTUnwrap(value as? [[String: Any]])
            XCTAssertEqual(entries.count, 1, "double install must not duplicate entries")
        }
    }

    func testUninstallRemovesOnlyMarkedEntries() throws {
        // A user-authored Stop hook must survive install/uninstall.
        let userHook: [String: Any] = [
            "hooks": [["type": "command", "command": "echo my-own-hook"]]
        ]
        try writeSettings(["hooks": ["Stop": [userHook]], "model": "x"])

        try installer.install()
        try installer.uninstall()

        let settings = try readSettings()
        XCTAssertEqual(settings["model"] as? String, "x")
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        let command = ((stop[0]["hooks"] as? [[String: Any]])?[0]["command"] as? String) ?? ""
        XCTAssertEqual(command, "echo my-own-hook")
        XCTAssertFalse(installer.isInstalled())
    }

    func testUninstallRemovesHooksKeyWhenEmpty() throws {
        try writeSettings([:])
        try installer.install()
        try installer.uninstall()
        XCTAssertNil(try readSettings()["hooks"])
    }

    func testBackupCreatedOnInstall() throws {
        try writeSettings(["model": "x"])
        try installer.install()
        let backups = try FileManager.default.contentsOfDirectory(atPath: installer.backupDir.path)
        XCTAssertEqual(backups.count, 1)
    }

    func testCommandShapeIsSafe() {
        let command = installer.command(state: "success")
        XCTAssertTrue(command.hasSuffix(HooksInstaller.marker))
        XCTAssertTrue(command.contains("AgentClockBridge"))
        XCTAssertTrue(command.contains("--provider claude"))
        XCTAssertTrue(command.contains("--event Stop"))
    }

    func testInstallWithNoSettingsFileCreatesOne() throws {
        try installer.install()
        XCTAssertTrue(installer.isInstalled())
    }

    func testMalformedSettingsAreNeverOverwritten() throws {
        let malformed = Data("{ definitely not json".utf8)
        try malformed.write(to: installer.settingsURL)
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try Data(contentsOf: installer.settingsURL), malformed)
    }

    func testCreatedSettingsAndBackupsArePrivate() throws {
        try writeSettings(["model": "x"])
        try installer.install()
        let settingsMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: installer.settingsURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(settingsMode.intValue & 0o777, 0o600)
        let backup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: installer.backupDir,
                                                    includingPropertiesForKeys: nil).first
        )
        let backupMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(backupMode.intValue & 0o777, 0o600)
    }
}
