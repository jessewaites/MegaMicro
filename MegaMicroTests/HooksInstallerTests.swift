import XCTest
@testable import MegaMicro

final class HooksInstallerTests: XCTestCase {
    var dir: URL!
    var installer: HooksInstaller!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("megamicro-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        installer = HooksInstaller(
            settingsURL: dir.appendingPathComponent("settings.json"),
            backupDir: dir.appendingPathComponent("backups"),
            port: 48802)
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
        XCTAssertEqual(Set(hooks.keys), Set(AppConfig.defaultClaudeHookEvents.keys))
        XCTAssertTrue(installer.isInstalled())
    }

    // Hooks run the installed bridge by path from every agent session on the
    // machine. Hardening the tree must not clear its exec bit: it hardens
    // nothing and breaks every session with "Permission denied".
    func testHardeningKeepsInstalledExecutablesRunnable() throws {
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("MegaMicroBridge")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let data = dir.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: data)

        PrivateFileStore.hardenExistingTree(dir)

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tool.path))
        XCTAssertEqual(mode(of: tool), 0o700)
        XCTAssertEqual(mode(of: data), 0o600, "non-executables stay owner-read/write only")
    }

    private func mode(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // The pre-bridge curl hooks carry the same marker, so they report as
    // installed while silently omitting the terminal identity exact focus
    // needs. They have to be distinguishable from a healthy install.
    func testPreBridgeCurlHooksReportAsStale() throws {
        try writeSettings(["hooks": ["Stop": [["hooks": [[
            "type": "command",
            "command": "curl -m 2 -s -X POST http://127.0.0.1:48802/state -d '{}' || true #megamicro",
        ]]]]]])
        XCTAssertTrue(installer.isInstalled())
        XCTAssertTrue(installer.isStale())
    }

    func testFreshInstallIsNotStale() throws {
        try installer.install()
        XCTAssertTrue(installer.isInstalled())
        XCTAssertFalse(installer.isStale())
    }

    func testUnmarkedForeignHooksAreNeverJudgedStale() throws {
        try writeSettings(["hooks": ["Stop": [["hooks": [[
            "type": "command", "command": "somebody-elses-tool --report",
        ]]]]]])
        XCTAssertFalse(installer.isInstalled())
        XCTAssertFalse(installer.isStale())
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
        XCTAssertTrue(command.contains("MegaMicroBridge"))
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
