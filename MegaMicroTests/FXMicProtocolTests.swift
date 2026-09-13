import XCTest
@testable import MegaMicro

final class FXMicProtocolTests: XCTestCase {
    func testParsesAStateLine() {
        let s = FXMicProtocol.parse("MM 1 0 0 10 2 3")
        XCTAssertEqual(s, FXMicProtocol.State(play: true, select: false, fx: false,
                                              handle: 0.5, fxPos: 2, samPos: 3))
        XCTAssertEqual(s?.page, 3)
        XCTAssertTrue(s?.handleDown ?? false)
    }

    func testCleanPageAndReleasedHandle() {
        let s = FXMicProtocol.parse("MM 0 0 0 0 -1 0")
        XCTAssertEqual(s?.page, 0)
        XCTAssertEqual(s?.handleDown, false)
        XCTAssertEqual(FXMicProtocol.pageLabel(0), "Page 1")
        XCTAssertEqual(FXMicProtocol.pageEffect(0), "clean")
        XCTAssertEqual(FXMicProtocol.pageEffect(4), "robot")
    }

    func testRejectsGarbage() {
        XCTAssertNil(FXMicProtocol.parse(">>> "))
        XCTAssertNil(FXMicProtocol.parse("MM 1 0"))
        XCTAssertNil(FXMicProtocol.parse("MM a b c d e f"))
        XCTAssertNil(FXMicProtocol.parse("MM-READY"))
    }

    func testControlIDsRoundTrip() {
        for page in 0..<FXMicProtocol.pageCount {
            for button in FXMicProtocol.Button.allCases {
                let id = FXMicProtocol.control(page: page, button: button)
                XCTAssertEqual(id.rawValue, "mic.p\(page).\(button.rawValue)")
                XCTAssertEqual(FXMicProtocol.describe(id),
                               "\(FXMicProtocol.pageLabel(page)) · \(button.label)")
                XCTAssertTrue(button.label.hasPrefix("FX"))
            }
        }
        XCTAssertNil(FXMicProtocol.describe(.key(3)))
        XCTAssertNil(FXMicProtocol.describe(FXMicLayout.handle))
    }

    func testAgentSourceIsPlainAndSelfContained() {
        // The raw REPL takes the text verbatim; tabs or smart quotes would
        // break it silently on the device.
        XCTAssertFalse(FXMicProtocol.agentSource.contains("\t"))
        XCTAssertTrue(FXMicProtocol.agentSource.contains("ui.callback(_mm_hook)"))
        XCTAssertTrue(FXMicProtocol.agentSource.contains("print(\"MM-READY\")"))
        XCTAssertTrue(FXMicProtocol.agentSource.contains("_mm_orig = teenage.python_callback"))
    }
}
