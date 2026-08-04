import XCTest
@testable import MegaMicro

/// The light show is the demo: it has to run for about ten seconds, and it has
/// to keep the keys visibly disagreeing with each other the whole way.
final class LightShowTests: XCTestCase {
    func testRunsForAboutTenSeconds() {
        let total = LightShow.script().reduce(0) { $0 + $1.hold }
        XCTAssertEqual(total, LightShow.duration, accuracy: 0.25)
    }

    func testKeysHoldDifferentColorsAtTheSameTime() {
        // Once the board is fully lit, it should never be showing one colour —
        // that's the whole claim. The single white flash in the finale is the
        // one deliberate exception; the build-up and blackouts aren't fully
        // lit, so they're not part of this.
        let full = LightShow.script().filter { $0.colors.count == LightShow.leds.count }
        let flashes = full.filter { Set($0.colors.values) == [LightShow.white()] }
        XCTAssertEqual(flashes.count, 1)
        for step in full where Set(step.colors.values) != [LightShow.white()] {
            XCTAssertGreaterThanOrEqual(Set(step.colors.values).count, 4)
        }
    }

    func testKeysChangeAtDifferentTimes() {
        // Somewhere in the show, consecutive steps must differ on some keys and
        // agree on others — that's what "different colours at different times"
        // looks like as data, and it's what a uniform animation can't do.
        let steps = LightShow.script()
        let staggered = zip(steps, steps.dropFirst()).contains { previous, next in
            let changed = LightShow.leds.filter { previous.colors[$0] != next.colors[$0] }
            return !changed.isEmpty && changed.count < LightShow.leds.count
        }
        XCTAssertTrue(staggered)
    }

    func testUnderglowRotatesThroughManyColors() {
        let ring = Set(LightShow.script().map(\.underglow))
        XCTAssertGreaterThan(ring.count, 20)
    }

    func testEveryStepAddressesEverySlotExplicitly() {
        // Omitted fields latch on the firmware, so each step has to speak for
        // all thirteen slots — including the dark ones.
        for step in LightShow.script() {
            let threads = LightShow.threads(for: step)
            XCTAssertEqual(threads.count, VOAI.ledIndexForAgentSlot.count)
            XCTAssertEqual(Set(threads.map(\.id)).count, threads.count)
            XCTAssertTrue(threads.allSatisfy { $0.sk == 0 && $0.sa == 0 })
        }
    }

    func testWideKeysTwoSwitchesNeverDisagree() {
        for step in LightShow.script() {
            let threads = LightShow.threads(for: step)
            XCTAssertEqual(threads[6].c, threads[7].c)
        }
    }

    func testOnScreenFrameMirrorsTheBoard() {
        let step = LightShow.Step(colors: [0: 0xFF0000, 1: 0x00FF00],
                                  underglow: 0x0000FF, underglowEffect: .solid, hold: 0.1)
        let frame = LightShow.frame(for: step, ledCount: 12)
        XCTAssertEqual(frame.perLED.count, 12)
        XCTAssertEqual(frame.perLED[0], LightShow.hsv(0xFF0000))
        XCTAssertEqual(frame.perLED[1], LightShow.hsv(0x00FF00))
        XCTAssertEqual(frame.perLED[2], .off)
        XCTAssertEqual(frame.underglow, LightShow.hsv(0x0000FF))
    }

    func testScriptIsDeterministic() {
        XCTAssertEqual(LightShow.script(), LightShow.script())
    }
}
