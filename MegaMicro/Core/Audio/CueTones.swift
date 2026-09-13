import Foundation

/// The chirp symbols MegaMicro loads into the EP-2350's four sample slots, and
/// the frequencies it listens for to decode them back out of the line output.
/// `FXMicScript` plays them; `CueMessageDecoder` reads the codes.
///
/// The mic has no data channel, so a button press is only observable as the
/// sound it makes. Each slot gets a short two-tone chirp — DTMF-style — because
/// a pair of simultaneous sines is something a voice, a whistle or a cough
/// essentially never produces, while a single pure tone occasionally is. Four
/// frequencies, two per cue, every pair unique, all far enough apart that the
/// decoder tolerates a few percent of pitch drift.
///
/// Playback on the mic: the white button selects a slot, the grey button plays
/// it. The orange button picks a voice effect, which is why it can't be a cue
/// of its own — pressing it makes no sound.
enum CueTones {
    /// The four component frequencies, in Hz. Kept well under half the
    /// detector's 16 kHz rate and above the bulk of speech energy.
    static let frequencies: [Double] = [900, 1200, 1600, 2100]

    /// Cue → indices into `frequencies`. Low member first.
    static let pairs: [(Int, Int)] = [(0, 2), (0, 3), (1, 2), (1, 3)]

    static var cueCount: Int { pairs.count }

    static func frequencies(for cue: Int) -> (low: Double, high: Double) {
        let pair = pairs[cue]
        return (frequencies[pair.0], frequencies[pair.1])
    }

    /// "Sample 1" … "Sample 4" — the slot number the mic's white button shows.
    static func label(_ cue: Int) -> String { "Sample \(cue + 1)" }

    /// Which cue a pair of frequency indices spells, if any.
    static func cue(forPair a: Int, _ b: Int) -> Int? {
        let key = (min(a, b), max(a, b))
        return pairs.firstIndex { $0 == key }
    }

    // MARK: WAV export

    /// The mic wants its slots as `1.wav` … `4.wav` in the root of its disk.
    static func fileName(for cue: Int) -> String { "\(cue + 1).wav" }

    /// Long enough for the detector to confirm across two 50 ms blocks with
    /// margin for the onset ramp; short enough that the mic's script can send
    /// one every 240 ms with a silent block between.
    static let duration: Double = 0.16
    static let fadeDuration: Double = 0.01
    /// Per-component amplitude. Two at 0.45 peak at 0.9 full scale — hot, so
    /// the tone stands well clear of whatever voice is mixed with it.
    static let amplitude: Double = 0.45

    /// 16-bit PCM mono WAV of the cue's two-tone chirp. 22.05 kHz keeps all
    /// four slots comfortably inside the mic's 1 MB of storage.
    static func wavData(for cue: Int, sampleRate: Double = 22_050) -> Data {
        let (low, high) = frequencies(for: cue)
        let count = Int(duration * sampleRate)
        let fade = max(1, Int(fadeDuration * sampleRate))
        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            var v = amplitude * (sin(2 * .pi * low * t) + sin(2 * .pi * high * t))
            // Raised-cosine edges: a hard start or stop is a click, and a click
            // is broadband energy that dents the tone's purity.
            if i < fade {
                v *= 0.5 - 0.5 * cos(.pi * Double(i) / Double(fade))
            } else if i >= count - fade {
                v *= 0.5 - 0.5 * cos(.pi * Double(count - 1 - i) / Double(fade))
            }
            pcm[i] = Int16(max(-1, min(1, v)) * 32_767)
        }
        return wav(pcm, sampleRate: Int(sampleRate))
    }

    private static func wav(_ samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1)                              // PCM, mono
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2))
        u16(2); u16(16)                             // block align, bits
        data.append(contentsOf: Array("data".utf8)); u32(byteCount)
        samples.withUnsafeBufferPointer { buf in
            buf.baseAddress.map { data.append(UnsafeBufferPointer(start: $0, count: buf.count)) }
        }
        return data
    }
}
