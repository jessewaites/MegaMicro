import XCTest
@testable import MegaMicro

/// Turning the keyboard off has to survive us letting go of it: the firmware
/// renders each layer's stored lighting the moment no host is driving the
/// LEDs, so "off" means writing darkness into that stored block — and being
/// able to hand the user's own colours back when they switch it on again.
final class DeviceLightsTests: XCTestCase {
    private func config(lights: [[String: Any]?]) -> [String: Any] {
        let layers: [[String: Any]] = lights.enumerated().map { index, block in
            var layer: [String: Any] = ["id": index, "name": "Layer \(index + 1)"]
            if let block { layer["lights"] = block }
            return layer
        }
        return ["version": 1, "profiles": [["id": 0, "layers": layers]]]
    }

    private let lit: [String: Any] = [
        "backlight": ["effect": "solid", "brightness": 1, "speed": 0.5, "magic": 1, "color": 16777215],
        "underglow": ["effect": "rainbow", "brightness": 1, "speed": 0.55, "magic": 1, "color": 16777215],
    ]

    private func lights(_ config: [String: Any], layer: Int) -> [String: Any]? {
        ((config["profiles"] as? [[String: Any]])?[0]["layers"] as? [[String: Any]])?[layer]["lights"]
            as? [String: Any]
    }

    func testBlankingSwitchesEveryLayerOff() throws {
        let result = try XCTUnwrap(VOAIDevice.blankingLights(in: config(lights: [lit, lit])))
        for layer in 0...1 {
            let block = try XCTUnwrap(lights(result.config, layer: layer))
            for surface in ["backlight", "underglow"] {
                XCTAssertEqual((block[surface] as? [String: Any])?["effect"] as? String, "off")
                XCTAssertEqual((block[surface] as? [String: Any])?["brightness"] as? Int, 0)
            }
        }
        XCTAssertEqual(Set(result.saved.keys), ["0/0", "0/1"])
    }

    /// A board that is already dark needs no write at all — and nothing of the
    /// user's is worth saving from it.
    func testAlreadyDarkBoardIsLeftAlone() {
        let dark: [String: Any] = [
            "backlight": ["effect": "off", "brightness": 0],
            "underglow": ["effect": "solid", "brightness": 0],   // turned all the way down
        ]
        XCTAssertNil(VOAIDevice.blankingLights(in: config(lights: [dark, dark])))
    }

    func testLayersWithoutLightingAreSkipped() throws {
        let result = try XCTUnwrap(VOAIDevice.blankingLights(in: config(lights: [nil, lit])))
        XCTAssertEqual(Set(result.saved.keys), ["0/1"])
        XCTAssertNil(lights(result.config, layer: 0))
    }

    func testRestoreReturnsExactlyWhatWasSaved() throws {
        let blanked = try XCTUnwrap(VOAIDevice.blankingLights(in: config(lights: [lit, lit])))
        let restored = try XCTUnwrap(VOAIDevice.restoringLights(blanked.saved, in: blanked.config))
        let block = try XCTUnwrap(lights(restored, layer: 1))
        let underglow = try XCTUnwrap(block["underglow"] as? [String: Any])
        XCTAssertEqual(underglow["effect"] as? String, "rainbow")
        XCTAssertEqual(underglow["speed"] as? Double, 0.55)
        XCTAssertEqual(underglow["color"] as? Int, 16777215)
    }

    /// The board may have gained or lost layers while it was off (edited in
    /// Work Louder Input, say). Restoring what still fits beats refusing.
    func testRestoreIgnoresLayersThatNoLongerExist() throws {
        let saved = try XCTUnwrap(VOAIDevice.blankingLights(in: config(lights: [lit, lit]))).saved
        let shrunk = config(lights: [VOAIDevice.darkLights])
        let restored = try XCTUnwrap(VOAIDevice.restoringLights(saved, in: shrunk))
        XCTAssertEqual((lights(restored, layer: 0)?["backlight"] as? [String: Any])?["effect"] as? String,
                       "solid")
    }

    func testRestoreWithNothingSavedChangesNothing() {
        XCTAssertNil(VOAIDevice.restoringLights([:], in: config(lights: [lit])))
        XCTAssertNil(VOAIDevice.restoringLights(["9/9": "{}"], in: config(lights: [lit])))
    }

    /// The saved block is stored in MegaMicro's config as text, so it has to
    /// survive a round trip through the config file unchanged.
    func testSavedLightingSurvivesConfigRoundTrip() throws {
        let saved = try XCTUnwrap(VOAIDevice.blankingLights(in: config(lights: [lit]))).saved
        var config = AppConfig()
        config.savedDeviceLights = saved
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded.savedDeviceLights, saved)
        XCTAssertNil(AppConfig().savedDeviceLights)
    }
}
