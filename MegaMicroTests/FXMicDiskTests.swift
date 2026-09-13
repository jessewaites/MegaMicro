import XCTest
@testable import MegaMicro

final class FXMicDiskTests: XCTestCase {
    func testCleanPagesConfigIsValidAndCoversFourPresets() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: FXMicDisk.cleanPagesConfig) as? [String: Any])
        let presets = try XCTUnwrap(json["presets"] as? [[String: Any]])
        XCTAssertEqual(presets.map { $0["pos"] as? Int }, [0, 1, 2, 3])
        for preset in presets {
            let list = try XCTUnwrap(preset["list"] as? [[String: Any]])
            XCTAssertEqual(list.count, 1)
            XCTAssertEqual(list[0]["effect"] as? String, "SAMPLE")
            XCTAssertEqual((preset["trigger"] as? [String: Any])?["row"] as? Int, 0)
            XCTAssertNil(preset["handle"]); XCTAssertNil(preset["shake"]); XCTAssertNil(preset["lfo"])
        }
    }

    func testSilentSampleIsAWellFormedWavOfZeros() {
        let data = FXMicDisk.silentSample
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(data.count, 44 + 882 * 2)
        XCTAssertTrue(data[44...].allSatisfy { $0 == 0 })
        // Four of them are nothing next to the mic's 1 MB.
        XCTAssertLessThan(data.count * 4, 10_000)
    }

    func testApplyAndRemoveRoundTripOnAScratchVolume() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fxmic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A stray AppleDouble twin, as macOS leaves on FAT.
        try Data().write(to: dir.appendingPathComponent("._junk"))

        XCTAssertFalse(FXMicDisk.isApplied(.silentSamples, on: dir))
        try FXMicDisk.apply(.silentSamples, on: dir)
        try FXMicDisk.apply(.cleanPages, on: dir)
        XCTAssertTrue(FXMicDisk.isApplied(.silentSamples, on: dir))
        XCTAssertTrue(FXMicDisk.isApplied(.cleanPages, on: dir))
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(names, ["1.wav", "2.wav", "3.wav", "4.wav", "config.json"])

        try FXMicDisk.remove(.cleanPages, on: dir)
        XCTAssertFalse(FXMicDisk.isApplied(.cleanPages, on: dir))
        XCTAssertTrue(FXMicDisk.isApplied(.silentSamples, on: dir))
        try FXMicDisk.remove(.silentSamples, on: dir)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
