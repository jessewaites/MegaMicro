import XCTest
@testable import AgentClock

final class FirmwareCheckTests: XCTestCase {

    func testVerdictsCarryTheRightAdvice() {
        // "Ready" is the only case with nothing to say — the setup section
        // hides itself entirely rather than sitting there being useless.
        XCTAssertNil(FirmwareCheck.Verdict.ready(version: "1.0.0").advice)
        XCTAssertTrue(FirmwareCheck.Verdict.ready(version: "1.0.0").isReady)

        for verdict: FirmwareCheck.Verdict in [
            .wrongFirmware(detail: "x"), .notFlashed(port: "/dev/cu.x"), .notFound,
        ] {
            XCTAssertFalse(verdict.isReady)
            XCTAssertNotNil(verdict.advice, "\(verdict) needs to tell the user what to do")
            XCTAssertFalse(verdict.summary.isEmpty)
        }
    }

    func testTheWrongFirmwareCaseNamesTheActualProblem() throws {
        // Someone who flashed AWTRIX 3 sees a working device and a broken app;
        // the advice has to explain that v3's API simply is not there.
        let advice = try XCTUnwrap(FirmwareCheck.Verdict.wrongFirmware(detail: "d").advice)
        XCTAssertTrue(advice.contains("NG"))
        XCTAssertTrue(advice.lowercased().contains("api"))
    }

    func testUnflashedAdviceMentionsBackingUpFirst() throws {
        // The firmware's own docs are blunt about this: the stock firmware is
        // overwritten, and the copy has to be taken beforehand.
        let advice = try XCTUnwrap(FirmwareCheck.Verdict.notFlashed(port: "p").advice)
        XCTAssertTrue(advice.lowercased().contains("overwrites"))
    }

    func testProbeWithNoHostAndNoBoardReportsNotFound() async {
        // No address to try and nothing plugged in — but only assert the
        // no-board branch when this machine genuinely has no serial device,
        // or the test would depend on what is plugged into the laptop.
        guard FirmwareCheck.attachedBoardPort() == nil else { return }
        let verdict = await FirmwareCheck.probe(host: nil)
        XCTAssertEqual(verdict, .notFound)
    }

    func testProbeIgnoresBlankHosts() async {
        guard FirmwareCheck.attachedBoardPort() == nil else { return }
        let verdict = await FirmwareCheck.probe(host: "   ")
        XCTAssertEqual(verdict, .notFound)
    }

    func testBoardDetectionOnlyMatchesSerialBridges() {
        // Bluetooth-Incoming-Port and debug-console are always present on a
        // Mac and must never be mistaken for a dev board.
        if let port = FirmwareCheck.attachedBoardPort() {
            XCTAssertFalse(port.contains("Bluetooth"))
            XCTAssertFalse(port.contains("debug-console"))
        }
    }
}
