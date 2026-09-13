import XCTest
@testable import MegaMicro

final class FXMicDiskTests: XCTestCase {
    func testScriptIsPlainPythonWithTheHooksItNeeds() {
        let src = FXMicScript.source
        XCTAssertFalse(src.contains("\t"))
        for needle in ["teenage.python_callback", "_ui.callback(_hook)", "_spl.trigger(-1,",
                       "_send(3, 3, 1, 0)", "SPACING = \(FXMicScript.spacingTicks)", "return _orig(m)"] {
            XCTAssertTrue(src.contains(needle), needle)
        }
        for line in src.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let indent = line.prefix { $0 == " " }.count
            XCTAssertEqual(indent % 4, 0, String(line))
        }
    }

    func testApplyWritesScriptAndChirpsAndClearsStaleConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fxmic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data().write(to: dir.appendingPathComponent("._junk"))

        XCTAssertFalse(FXMicDisk.isApplied(.controlScript, on: dir))
        try FXMicDisk.apply(.controlScript, on: dir)
        XCTAssertTrue(FXMicDisk.isApplied(.controlScript, on: dir))
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(names, ["1.wav", "2.wav", "3.wav", "4.wav", "main.py"])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("1.wav")), CueTones.wavData(for: 0))

        try FXMicDisk.remove(.controlScript, on: dir)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
