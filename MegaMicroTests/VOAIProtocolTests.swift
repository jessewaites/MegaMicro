import XCTest
@testable import MegaMicro

final class VOAIProtocolTests: XCTestCase {
    func testFrameLayoutSingleReport() {
        let reports = VOAI.frames(channel: VOAI.channelRPC, message: Data("hello".utf8))
        XCTAssertEqual(reports.count, 1)
        let report = reports[0]
        XCTAssertEqual(report.count, 64)
        XCTAssertEqual(report[0], 0x06)
        XCTAssertEqual(report[1], 2)
        XCTAssertEqual(report[2], 5)
        XCTAssertEqual(Array(report[3..<8]), Array("hello".utf8))
        XCTAssertTrue(report[8...].allSatisfy { $0 == 0 })
    }

    func testChunkingLongMessage() {
        // 130 bytes → 61 + 61 + 8 = three reports.
        let message = Data(repeating: UInt8(ascii: "x"), count: 130)
        let reports = VOAI.frames(channel: VOAI.channelRPC, message: message)
        XCTAssertEqual(reports.count, 3)
        XCTAssertEqual(reports[0][2], 61)
        XCTAssertEqual(reports[1][2], 61)
        XCTAssertEqual(reports[2][2], 8)
    }

    func testExactMultipleGetsTerminator() {
        let message = Data(repeating: 1, count: 61)
        let reports = VOAI.frames(channel: VOAI.channelRPC, message: message)
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[1][2], 0, "zero-length terminator marks message end")
    }

    func testAccumulatorReassembles() {
        let message = Data(repeating: UInt8(ascii: "a"), count: 130)
        var accumulator = VOAI.FrameAccumulator()
        var completed: (UInt8, Data)?
        for report in VOAI.frames(channel: VOAI.channelRPC, message: message) {
            if let done = accumulator.append(report) {
                XCTAssertNil(completed, "must complete exactly once")
                completed = done
            }
        }
        XCTAssertEqual(completed?.0, VOAI.channelRPC)
        XCTAssertEqual(completed?.1, message)
    }

    func testThreadStatusRequestJSON() throws {
        let params = [VOAI.ThreadParam(id: 0, c: 0xFF453A, b: 1.0, e: 1, s: nil)]
        let data = try VOAI.threadStatusRequest(id: 1234, params: params)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["id"] as? Int, 234, "ids cycle 0–999")
        XCTAssertEqual(json["method"] as? String, "v.oai.thstatus")
        let first = try XCTUnwrap((json["params"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["c"] as? Int, 0xFF453A)
        XCTAssertNil(first["s"], "nil optionals must be omitted, not null")
    }

    func testParseHIDAndJoystickNotifications() {
        let key = Data(#"{"method":"v.oai.hid","params":{"k":3,"act":"approve"}}"#.utf8)
        XCTAssertEqual(VOAI.parseMessage(channel: 2, message: key), .key(index: 3, action: "approve"))
        let joy = Data(#"{"method":"v.oai.rad","params":{"a":270.5,"d":0.8}}"#.utf8)
        XCTAssertEqual(VOAI.parseMessage(channel: 2, message: joy), .joystick(angle: 270.5, distance: 0.8))
        let debug = Data("boot ok".utf8)
        XCTAssertEqual(VOAI.parseMessage(channel: 1, message: debug), .debug("boot ok"))
    }

    func testPackedRGBPrimaries() {
        XCTAssertEqual(VOAI.packedRGB(HSV(h: 0, s: 255, v: 42)), 0xFF0000, "brightness must not dim the packed color")
        XCTAssertEqual(VOAI.packedRGB(HSV(h: 85, s: 255, v: 255)), 0x00FF00)
        XCTAssertEqual(VOAI.packedRGB(HSV(h: 170, s: 255, v: 255)), 0x0000FF)
    }

    func testEffectMapping() {
        XCTAssertEqual(VOAI.effectParams(for: .solid).effect, .solid)
        let breathing = VOAI.effectParams(for: .breathing(period: 2.8))
        XCTAssertEqual(breathing.effect, .breath)
        XCTAssertEqual(breathing.speed ?? 0, 0.55, accuracy: 0.01)
        XCTAssertEqual(VOAI.effectParams(for: .strobe(hz: 5)).speed, 1.0)
        XCTAssertEqual(VOAI.effectParams(for: .fadeOut(total: 45)).effect, .solid)
    }

    func testAmbientBreathingRunsOnFirmware() {
        let spec = RGBRules.standard.spec(for: .thinking)
        let param = VOAI.ambientZoneParam(
            for: spec,
            renderedColor: HSV(h: spec.color.h, s: spec.color.s, v: 20))

        XCTAssertEqual(param.e, VOAI.Effect.breath.rawValue)
        XCTAssertEqual(param.b, Double(spec.color.v) / 255.0, accuracy: 0.001)
        XCTAssertEqual(param.c, VOAI.packedRGB(spec.color))
    }

    func testAmbientBlinkUsesRenderedBrightness() {
        let spec = RGBRules.standard.spec(for: .waiting)
        let rendered = HSV(h: spec.color.h, s: spec.color.s, v: 0)
        let param = VOAI.ambientZoneParam(for: spec, renderedColor: rendered)

        XCTAssertEqual(param.e, VOAI.Effect.solid.rawValue)
        XCTAssertEqual(param.b, 0)
    }

    func testRendererFillsPerLEDSpecs() {
        let rules = RGBRules.standard
        let frame = AnimationRenderer.frame(
            aggregate: .waiting, aggregateAge: 0,
            perKeyStates: [2: (state: .waiting, age: 0)],
            rules: rules, ledCount: 12, t: 0)
        XCTAssertEqual(frame.perLEDSpecs.count, 12)
        XCTAssertEqual(frame.perLEDSpecs[2]?.kind, rules.spec(for: .waiting).kind)
        XCTAssertEqual(frame.perLEDSpecs[0]?.kind, rules.spec(for: .idle).kind)
    }

    func testNumberedHIDOutputKeepsReportIDInPayload() {
        let report = VOAI.frames(channel: VOAI.channelRPC, message: Data("hello".utf8))[0]
        let prepared = HIDTransport.prepareOutputReport(
            report,
            reportSize: VOAI.reportSize,
            usesLeadingReportID: true)

        XCTAssertEqual(prepared.reportID, CFIndex(VOAI.reportID))
        XCTAssertEqual(prepared.payload, report)
    }

    func testZeroHIDReportIDIsRemovedFromPayload() {
        var report = [UInt8](repeating: 0, count: 33)
        report[1] = 0xA5
        let prepared = HIDTransport.prepareOutputReport(
            report,
            reportSize: report.count,
            usesLeadingReportID: true)

        XCTAssertEqual(prepared.reportID, 0)
        XCTAssertEqual(prepared.payload.count, 32)
        XCTAssertEqual(prepared.payload.first, 0xA5)
    }
}
