import XCTest
@testable import MegaMicro

final class ToneDetectorTests: XCTestCase {
    private let rate = 16_000.0
    private let n = 800

    /// One 50 ms block of the given sines (frequency, amplitude), plus an
    /// optional deterministic noise floor.
    private func block(_ tones: [(Double, Double)], noise: Float = 0, offset: Int = 0) -> [Float] {
        var seed: UInt32 = 12345
        return (0..<n).map { i in
            let t = Double(i + offset) / rate
            var v = tones.reduce(0.0) { $0 + $1.1 * sin(2 * .pi * $1.0 * t) }
            if noise > 0 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                v += Double(Float(seed >> 8) / Float(1 << 24) * 2 - 1) * Double(noise)
            }
            return Float(v)
        }
    }

    private func rms(_ b: [Float]) -> Float {
        (b.reduce(0) { $0 + $1 * $1 } / Float(b.count)).squareRoot()
    }

    private func feed(_ detector: ToneDetector, _ blocks: [[Float]]) -> [ToneDetector.Detection] {
        blocks.compactMap { detector.process($0, rms: rms($0)) }
    }

    private func cueBlocks(_ cue: Int, count: Int, detune: Double = 0, noise: Float = 0) -> [[Float]] {
        let (low, high) = CueTones.frequencies(for: cue)
        return (0..<count).map { i in
            block([(low * (1 + detune), 0.4), (high * (1 + detune), 0.4)],
                  noise: noise, offset: i * n)
        }
    }

    func testEachCueFiresOnceOnTheConfirmingBlock() {
        for cue in 0..<CueTones.cueCount {
            let detector = ToneDetector(sampleRate: rate)
            let hits = feed(detector, cueBlocks(cue, count: 7))
            XCTAssertEqual(hits.map(\.cue), [cue], "cue \(cue)")
            XCTAssertGreaterThan(hits.first?.purity ?? 0, ToneDetector.minPairPurity)
        }
    }

    func testSingleBlockIsNotEnough() {
        let detector = ToneDetector(sampleRate: rate)
        let silence = [Float](repeating: 0, count: n)
        let hits = feed(detector, [cueBlocks(2, count: 1)[0], silence, cueBlocks(2, count: 1)[0], silence])
        XCTAssertTrue(hits.isEmpty)
    }

    func testDetunedToneStillDecodes() {
        for detune in [-0.02, 0.02] {
            let detector = ToneDetector(sampleRate: rate)
            let hits = feed(detector, cueBlocks(1, count: 6, detune: detune))
            XCTAssertEqual(hits.map(\.cue), [1], "detune \(detune)")
        }
    }

    func testSurvivesNoiseFloor() {
        let detector = ToneDetector(sampleRate: rate)
        let hits = feed(detector, cueBlocks(3, count: 6, noise: 0.08))
        XCTAssertEqual(hits.map(\.cue), [3])
    }

    func testOneBurstFiresOnceAndAQuietBlockReArmsIt() {
        let detector = ToneDetector(sampleRate: rate)
        let silence = [Float](repeating: 0, count: n)
        // A long burst is one press, however many blocks it spans.
        var hits = feed(detector, cueBlocks(0, count: 12))
        XCTAssertEqual(hits.map(\.cue), [0])
        // One silent block, then the same symbol again: a second chirp.
        hits = feed(detector, [silence] + cueBlocks(0, count: 4))
        XCTAssertEqual(hits.map(\.cue), [0])
    }

    func testBackToBackDifferentCuesBothFire() {
        let detector = ToneDetector(sampleRate: rate)
        let hits = feed(detector, cueBlocks(0, count: 6) + cueBlocks(3, count: 6))
        XCTAssertEqual(hits.map(\.cue), [0, 3])
    }

    func testWhistleAndVoiceDoNotFire() {
        // A lone pure tone at a cue frequency: half a pair is not a cue.
        var detector = ToneDetector(sampleRate: rate)
        let whistle = (0..<8).map { block([(1600, 0.6)], offset: $0 * n) }
        XCTAssertTrue(feed(detector, whistle).isEmpty)

        // Voiced speech: a 150 Hz fundamental with a rolling-off harmonic stack.
        detector = ToneDetector(sampleRate: rate)
        let harmonics = (1...20).map { (150.0 * Double($0), 0.5 / Double($0)) }
        let voice = (0..<8).map { block(harmonics, noise: 0.02, offset: $0 * n) }
        XCTAssertTrue(feed(detector, voice).isEmpty)

        // Broadband noise alone.
        detector = ToneDetector(sampleRate: rate)
        let hiss = (0..<8).map { block([], noise: 0.3, offset: $0 * n) }
        XCTAssertTrue(feed(detector, hiss).isEmpty)
    }

    func testSilenceIsIgnoredAndReadingClears() {
        let detector = ToneDetector(sampleRate: rate)
        _ = detector.process(cueBlocks(0, count: 1)[0], rms: 0.5)
        XCTAssertNotNil(detector.lastReading)
        XCTAssertNil(detector.process([Float](repeating: 0, count: n), rms: 0))
        XCTAssertNil(detector.lastReading)
    }

    // MARK: Cue tone files

    func testWavHeaderAndLength() {
        let data = CueTones.wavData(for: 0, sampleRate: 22_050)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        let frames = Int(CueTones.duration * 22_050)
        XCTAssertEqual(data.count, 44 + frames * 2)
        // Header fields: PCM, mono, 16-bit, declared data size.
        XCTAssertEqual(data[20], 1); XCTAssertEqual(data[22], 1); XCTAssertEqual(data[34], 16)
        let declared = data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(Int(UInt32(littleEndian: declared)), frames * 2)
        // All four slots fit the mic's 1 MB with room to spare.
        let total = (0..<CueTones.cueCount).map { CueTones.wavData(for: $0).count }.reduce(0, +)
        XCTAssertLessThan(total, 200_000)
    }

    /// The exported file, resampled the way the mic → dongle → app path would
    /// deliver it, decodes back to the same cue. Closes the loop on the chosen
    /// frequencies and amplitudes end to end.
    func testExportedToneRoundTripsThroughDetector() {
        for cue in 0..<CueTones.cueCount {
            let data = CueTones.wavData(for: cue, sampleRate: 16_000)
            let pcm: [Float] = data[44...].withUnsafeBytes { raw in
                let count = raw.count / 2
                return (0..<count).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32_768 }
            }
            // Attenuate hard, as a line signal into a padded input would be.
            let quiet = pcm.map { $0 * 0.1 }
            let blocks = stride(from: 0, to: quiet.count - n, by: n).map { Array(quiet[$0..<$0 + n]) }
            let detector = ToneDetector(sampleRate: rate)
            XCTAssertEqual(feed(detector, blocks).map(\.cue), [cue], "cue \(cue)")
        }
    }

    func testPairsAreUniqueAndLabelsMatchSlots() {
        let keys = CueTones.pairs.map { "\($0.0)-\($0.1)" }
        XCTAssertEqual(Set(keys).count, CueTones.cueCount)
        for cue in 0..<CueTones.cueCount {
            XCTAssertEqual(CueTones.cue(forPair: CueTones.pairs[cue].1, CueTones.pairs[cue].0), cue)
            XCTAssertEqual(CueTones.fileName(for: cue), "\(cue + 1).wav")
            XCTAssertEqual(FXMicLayout.cueLabel(cue), "Sample \(cue + 1)")
        }
        XCTAssertEqual(FXMicLayout.layout.controls.count, CueTones.cueCount + 1)
    }
}
