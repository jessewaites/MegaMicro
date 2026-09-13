import XCTest
@testable import AgentClock

final class ConfigStoreTests: XCTestCase {
    private func decode(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    func testPartialConfigKeepsItsValuesAndDefaultsTheRest() throws {
        // The shape every upgrade produces: a document written before newer
        // settings existed. Losing the clock address here would mean a user
        // reconfiguring the app on every release.
        let config = try decode(#"{"version":1,"clockHost":"clock.local"}"#)
        XCTAssertEqual(config.clockHost, "clock.local")
        XCTAssertEqual(config.webhookPort, 48812)
        XCTAssertTrue(config.display.showAgentPage)
        XCTAssertEqual(config.display.stateColors, StatePalette.defaults)
    }

    func testEmptyDocumentDecodesToDefaults() throws {
        XCTAssertEqual(try decode("{}").webhookPort, AppConfig().webhookPort)
    }

    func testAFieldOfTheWrongTypeCostsOnlyThatField() throws {
        let config = try decode(#"{"clockHost":"clock.local","webhookPort":"not a number"}"#)
        XCTAssertEqual(config.clockHost, "clock.local")
        XCTAssertEqual(config.webhookPort, 48812)
    }

    func testUnknownKeysAreIgnored() throws {
        let config = try decode(#"{"clockHost":"x","somethingFromTheFuture":42}"#)
        XCTAssertEqual(config.clockHost, "x")
    }

    func testCustomColorsSurviveButNewStatesStillGetDefaults() throws {
        // Doubled delimiter: the colour's own `"#` would close a single-# raw string.
        let config = try decode(##"{"display":{"stateColors":{"coding":"#123456"}}}"##)
        XCTAssertEqual(config.display.stateColors["coding"], "#123456")
        XCTAssertEqual(config.display.stateColors["error"], StatePalette.defaults["error"])
    }

    func testRoundTrip() throws {
        var original = AppConfig()
        original.clockHost = "awtrixng-a1b2c3.local"
        original.display.notifyOnSuccess = true
        original.display.stateColors["coding"] = "#ABCDEF"

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(restored.clockHost, original.clockHost)
        XCTAssertTrue(restored.display.notifyOnSuccess)
        XCTAssertEqual(restored.display.stateColors["coding"], "#ABCDEF")
    }

    func testValidHexRejectsWhatTheDeviceWouldReject() {
        XCTAssertTrue(StatePalette.isValidHex("#00FF88"))
        XCTAssertFalse(StatePalette.isValidHex("00FF88"))
        XCTAssertFalse(StatePalette.isValidHex("#00FF8"))
        XCTAssertFalse(StatePalette.isValidHex("#GGGGGG"))
    }

    func testHostNormalizationAcceptsWhatPeopleActuallyPaste() {
        XCTAssertEqual(AwtrixClient.baseURLString(for: "1.2.3.4"), "http://1.2.3.4")
        XCTAssertEqual(AwtrixClient.baseURLString(for: " clock.local "), "http://clock.local")
        XCTAssertEqual(AwtrixClient.baseURLString(for: "clock.local:8080"), "http://clock.local:8080")
        XCTAssertEqual(AwtrixClient.baseURLString(for: "http://clock.local/"), "http://clock.local")
    }

    func testDeviceErrorsAreSurfacedInTheirOwnWords() {
        let body = Data(#"{"error":{"code":"validationFailed","message":"out of range","field":"brightness"}}"#.utf8)
        XCTAssertEqual(AwtrixClient.errorMessage(in: body), "out of range (brightness)")
    }
}
