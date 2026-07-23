import XCTest
@testable import MegaMicro

final class WorkLouderLayerManagerTests: XCTestCase {
    private var directory: URL!
    private var storageURL: URL!
    private var backupURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("megamicro-layers-\(UUID().uuidString)")
        storageURL = directory.appendingPathComponent("input_storage.json")
        backupURL = directory.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(fixture.utf8).write(to: storageURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: storageURL.path)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testInspectionFindsLiveSourceAndTargets() throws {
        let manager = WorkLouderLayerManager(
            storageURL: storageURL, backupDirectoryURL: backupURL)
        let result = try manager.inspect(requireInputQuit: false)
        XCTAssertEqual(result.deviceID, "device-1")
        XCTAssertEqual(result.profileID, "profile-a")
        XCTAssertEqual(result.source.id, 0)
        XCTAssertEqual(result.targets.map(\.id), [1])
    }

    func testCloneChangesOnlyTargetLayoutAndCreatesParseableBackups() throws {
        let manager = WorkLouderLayerManager(
            storageURL: storageURL, backupDirectoryURL: backupURL)
        let before = try JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as! [String: Any]
        let result = try manager.cloneCodexLayout(to: 1, requireInputQuit: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fullBackupURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.layoutBackupURL.path))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: result.fullBackupURL)))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: result.layoutBackupURL)))
        XCTAssertNoThrow(try manager.verifyClone(targetLayerID: 1, requireInputQuit: false))

        let permissions = try FileManager.default.attributesOfItem(atPath: storageURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o640)

        // Layer-level identity and presentation survive the layout-only copy.
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as! [String: Any]
        let beforeLayer = layer(1, in: before)
        let afterLayer = layer(1, in: after)
        XCTAssertEqual(beforeLayer["name"] as? String, afterLayer["name"] as? String)
        XCTAssertEqual(beforeLayer["color"] as? String, afterLayer["color"] as? String)
        XCTAssertEqual(beforeLayer["lights"] as? [String: Bool], afterLayer["lights"] as? [String: Bool])

        let rollback = try manager.restoreLayout(
            to: 1, from: result.layoutBackupURL, requireInputQuit: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollback.safetyBackupURL.path))
        let restored = try JSONSerialization.jsonObject(
            with: Data(contentsOf: storageURL)) as! [String: Any]
        XCTAssertTrue((layer(1, in: restored)["layout"] as AnyObject)
            .isEqual(beforeLayer["layout"] as AnyObject))
    }

    func testAmbiguousCodexDeviceRefusesToProceed() throws {
        var object = try JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
        var collections = object["collections"] as! [[String: Any]]
        var devices = collections[0]["data"] as! [[String: Any]]
        devices.append(devices[0])
        collections[0]["data"] = devices
        object["collections"] = collections
        try JSONSerialization.data(withJSONObject: object).write(to: storageURL)

        let manager = WorkLouderLayerManager(
            storageURL: storageURL, backupDirectoryURL: backupURL)
        XCTAssertThrowsError(try manager.cloneCodexLayout(to: 1, requireInputQuit: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    private func layer(_ id: Int, in root: [String: Any]) -> [String: Any] {
        let collections = root["collections"] as! [[String: Any]]
        let devices = collections[0]["data"] as! [[String: Any]]
        let device = devices[0]["device"] as! [String: Any]
        let profiles = device["profiles"] as! [[String: Any]]
        return (profiles[0]["layers"] as! [[String: Any]]).first { $0["id"] as? Int == id }!
    }

    private var fixture: String {
        """
        {
          "collections": [{
            "name": "devices",
            "data": [{
              "device": {
                "id": "device-1",
                "name": "My Codex Micro",
                "deviceType": "codex_micro",
                "activeProfileId": "profile-a",
                "profiles": [{
                  "id": "profile-a",
                  "name": "Default",
                  "layers": [
                    {
                      "id": 0,
                      "name": "Codex",
                      "color": "#ffffff",
                      "lights": {"enabled": true},
                      "layout": {
                        "keymap": [["KV_OAI_AG00", "KV_OAI_AG01"]],
                        "encoders": [["KV_OAI_ENC_CC", "KV_OAI_ENC_CW", "KV_OAI_ENC_CLK"]],
                        "joystick": {"type": "VENDOR", "sectors": []}
                      }
                    },
                    {
                      "id": 1,
                      "name": "Wispr",
                      "color": "#00ff00",
                      "lights": {"enabled": false},
                      "layout": {
                        "keymap": [["KC_A", "KC_B"]],
                        "encoders": [],
                        "joystick": {"type": "RADIAL", "sectors": []}
                      }
                    }
                  ]
                }]
              },
              "checksum": "keep-me"
            }]
          }],
          "files": [{"checksum": "also-keep-me"}]
        }
        """
    }
}
