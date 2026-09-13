import XCTest
@testable import MegaMicro

final class CueMessageDecoderTests: XCTestCase {
    private func run(_ symbols: [Int], spacing: TimeInterval = 0.24) -> [CueMessageDecoder.Message] {
        var decoder = CueMessageDecoder()
        var t: TimeInterval = 10
        var out: [CueMessageDecoder.Message] = []
        for s in symbols {
            if let m = decoder.feed(symbol: s, at: t) { out.append(m) }
            t += spacing
        }
        return out
    }

    func testSinglesAreImmediate() {
        XCTAssertEqual(run([0]), [.fx3(down: true)])
        XCTAssertEqual(run([1]), [.fx4(down: true)])
        XCTAssertEqual(run([2]), [.handle(down: true)])
    }

    func testPrefixedPairsAreReleases() {
        XCTAssertEqual(run([3, 0]), [.fx3(down: false)])
        XCTAssertEqual(run([3, 1]), [.fx4(down: false)])
        XCTAssertEqual(run([3, 2]), [.handle(down: false)])
    }

    func testPages() {
        XCTAssertEqual(run([3, 3, 1, 0]), [.page(level: 0)])
        for level in 1...4 {
            XCTAssertEqual(run([3, 3, 0, level - 1]), [.page(level: level)], "level \(level)")
        }
    }

    func testAFullPressCycleOnPageThree() {
        XCTAssertEqual(run([3, 3, 0, 1, 1, 3, 1, 0, 3, 0]),
                       [.page(level: 2), .fx4(down: true), .fx4(down: false), .fx3(down: true), .fx3(down: false)])
    }

    func testStalePrefixIsDroppedAfterTheGap() {
        var decoder = CueMessageDecoder()
        XCTAssertNil(decoder.feed(symbol: 3, at: 1))
        XCTAssertEqual(decoder.feed(symbol: 0, at: 3), .fx3(down: true))
    }

    func testMalformedPageIsIgnored() {
        XCTAssertEqual(run([3, 3, 2, 2]), [])
        XCTAssertEqual(run([3, 3, 2, 2, 1]), [.fx4(down: true)])
    }
}
