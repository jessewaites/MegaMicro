import Foundation

/// Decodes `CueTones` out of a 16 kHz mono block stream.
///
/// Per 50 ms block: a Goertzel power at each of the four cue frequencies (and a
/// few Hz either side, so a slightly detuned playback still lands), normalised
/// against the block's total energy so the result is a *purity* — the share of
/// everything heard that is this one tone. A cue fires when its two components
/// each hold a clear share, together dominate the block, and do so on two
/// consecutive blocks, once per burst: the same cue fires again only after a
/// block in which it wasn't heard, which one quiet block between chirps gives.
///
/// Pure Swift, no Accelerate: four frequencies × nine offsets × 800 samples is
/// under 30k multiply-adds per block, nothing at 20 blocks a second.
final class ToneDetector {
    struct Detection: Equatable {
        var cue: Int
        /// Combined purity of the pair, 0…1.
        var purity: Float
    }

    /// The strongest candidate in the latest block, fired or not — for a UI
    /// that shows the detector hearing something before it commits.
    struct Reading: Equatable {
        var cue: Int
        var purity: Float
    }

    let sampleRate: Double
    /// Search ±`offsetSpan` Hz around each target in `offsetStep` Hz steps.
    static let offsetSpan: Double = 40
    static let offsetStep: Double = 10
    /// Each component must hold this share of the block on its own…
    static let minComponentPurity: Float = 0.15
    /// …and the pair together this much.
    static let minPairPurity: Float = 0.45
    /// Blocks in a row a cue must be heard before firing.
    static let confirmBlocks = 2
    /// Below this RMS the block is floor noise — don't even look.
    static let minRMS: Float = 0.002

    private(set) var lastReading: Reading?

    private var pendingCue: Int?
    private var pendingCount = 0
    /// The cue that already fired for the burst still in progress. Cleared by
    /// the first block that isn't that cue, so a fresh burst of the same cue
    /// after one quiet block fires again.
    private var firedCue: Int?
    private let coefficients: [[Float]]   // [frequency][offset]

    init(sampleRate: Double = 16_000) {
        self.sampleRate = sampleRate
        let offsets = stride(from: -Self.offsetSpan, through: Self.offsetSpan, by: Self.offsetStep)
        coefficients = CueTones.frequencies.map { f in
            offsets.map { Float(2 * cos(2 * Double.pi * (f + $0) / sampleRate)) }
        }
    }

    func reset() {
        pendingCue = nil
        pendingCount = 0
        firedCue = nil
        lastReading = nil
    }

    /// Feed one block. Returns a detection on the block that confirms a cue.
    func process(_ block: [Float], rms: Float) -> Detection? {
        guard rms >= Self.minRMS, !block.isEmpty else {
            lastReading = nil
            pendingCue = nil
            pendingCount = 0
            firedCue = nil
            return nil
        }

        let purities = componentPurities(block, rms: rms)

        // Best pair by combined purity, subject to each half carrying weight.
        var best: (cue: Int, purity: Float)?
        for (cue, pair) in CueTones.pairs.enumerated() {
            let a = purities[pair.0], b = purities[pair.1]
            let combined = a + b
            if combined > (best?.purity ?? 0) {
                best = (cue, combined)
            }
        }
        lastReading = best.flatMap { $0.purity >= 0.1 ? Reading(cue: $0.cue, purity: $0.purity) : nil }

        guard let best,
              best.purity >= Self.minPairPurity,
              purities[CueTones.pairs[best.cue].0] >= Self.minComponentPurity,
              purities[CueTones.pairs[best.cue].1] >= Self.minComponentPurity else {
            pendingCue = nil
            pendingCount = 0
            firedCue = nil
            return nil
        }

        if pendingCue == best.cue {
            pendingCount += 1
        } else {
            pendingCue = best.cue
            pendingCount = 1
            firedCue = nil
        }
        guard pendingCount == Self.confirmBlocks, firedCue != best.cue else { return nil }
        firedCue = best.cue
        return Detection(cue: best.cue, purity: min(1, best.purity))
    }

    /// Share of the block's energy at each cue frequency (max over offsets).
    /// For a lone full-block sine this is 1; for one half of an equal-amplitude
    /// pair it is 0.5.
    private func componentPurities(_ block: [Float], rms: Float) -> [Float] {
        let n = Float(block.count)
        let sumSquares = rms * rms * n
        guard sumSquares > 0 else { return Array(repeating: 0, count: coefficients.count) }
        return coefficients.map { offsets in
            var bestPower: Float = 0
            for coefficient in offsets {
                var s1: Float = 0, s2: Float = 0
                for x in block {
                    let s = x + coefficient * s1 - s2
                    s2 = s1
                    s1 = s
                }
                let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
                bestPower = max(bestPower, power)
            }
            return min(1, 2 * bestPower / (n * sumSquares))
        }
    }
}
