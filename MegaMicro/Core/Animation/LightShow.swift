import Foundation

/// Ten seconds of scripted per-key colour — the demo reel for the thing this
/// hardware was not supposed to do. Every key holds its own colour, those
/// colours change independently of one another, and the perimeter ring rotates
/// through the spectrum underneath the whole way.
///
/// Pure choreography: no agent state, no device I/O, no clock. `AppState`
/// walks the steps and does the talking, so the timing and the colour spread
/// can be tested without a keyboard plugged in.
enum LightShow {
    /// One frame of the show. `colors` is keyed by **LED index**, not agent
    /// slot, so the wide key's two switches (which share LED 10) can never
    /// disagree with each other. An absent LED is dark.
    struct Step: Hashable, Sendable {
        var colors: [Int: UInt32]          // led index → packed 0xRRGGBB
        var underglow: UInt32
        var underglowEffect: VOAI.Effect
        var hold: TimeInterval
    }

    /// Every addressable LED in physical order, top-left to bottom-right —
    /// that ordering is what makes a sweep read as a sweep.
    static let leds: [Int] = Array(Set(VOAI.ledIndexForAgentSlot)).sorted()

    /// The four physical rows, in LED indices. Rows 0–2 are the key grid; the
    /// last holds the wide key and its neighbour.
    static let rows: [[Int]] = [[0, 1], [2, 3, 4, 5], [6, 7, 8, 9], [10, 11]]

    /// Hue step between neighbouring keys during the sweeps. Wide enough that
    /// adjacent keys are obviously different colours on video.
    private static let spread = 21

    /// About how long the whole show runs: long enough to read on camera,
    /// short enough to stay one take.
    static let duration: TimeInterval = 10

    /// The full show. Deterministic — every take is the same take, which
    /// matters when the third one is the one that gets cut.
    static func script() -> [Step] {
        var steps: [Step] = []
        var ringHue = 0
        func ring(_ advance: Int) -> UInt32 {
            ringHue += advance
            return packed(hue: ringHue)
        }

        // 1. Ignition (1.1 s) — the rainbow arrives one key at a time, so the
        //    first thing on camera is twelve different colours, not one.
        var lit: [Int: UInt32] = [:]
        for (position, led) in leds.enumerated() {
            lit[led] = packed(hue: position * spread)
            steps.append(Step(colors: lit, underglow: ring(7), underglowEffect: .solid, hold: 0.09))
        }

        // 2. Wave (3.2 s) — the whole spectrum slides across the board. Each
        //    key changes colour continuously, and never to its neighbour's.
        for tick in 0..<40 {
            var colors: [Int: UInt32] = [:]
            for (position, led) in leds.enumerated() {
                colors[led] = packed(hue: tick * 7 + position * spread)
            }
            steps.append(Step(colors: colors, underglow: ring(-9), underglowEffect: .solid, hold: 0.08))
        }

        // 3. Confetti (2.4 s) — only four keys change on any given step, so the
        //    board stops looking like one animation and starts looking like
        //    twelve independent lights.
        let palette = [0, 24, 48, 90, 128, 160, 190, 214]
        var confetti = steps.last?.colors ?? [:]
        var roll = Roll(seed: 0x5EED_1E77)
        for tick in 0..<16 {
            for offset in 0..<4 {
                let led = leds[(tick * 5 + offset * 3) % leds.count]
                confetti[led] = packed(hue: palette[roll.next(palette.count)])
            }
            steps.append(Step(colors: confetti, underglow: ring(11), underglowEffect: .solid, hold: 0.15))
        }

        // 4. Rows (1.6 s) — one row at full brightness over three dimmed ones,
        //    each row its own hue. Reads as structure after the chaos.
        for pass in 0..<2 {
            for (index, _) in rows.enumerated() {
                var colors: [Int: UInt32] = [:]
                for (position, row) in rows.enumerated() {
                    let hue = position * 64 + pass * 32
                    let brightness = position == index ? 1.0 : 0.12
                    for led in row { colors[led] = packed(hue: hue, brightness: brightness) }
                }
                steps.append(Step(colors: colors, underglow: ring(13), underglowEffect: .solid, hold: 0.2))
            }
        }

        // 5. Finale (1.7 s) — white flash, blackout, then the full rainbow held
        //    over a ring the firmware animates itself.
        let rainbow = Dictionary(uniqueKeysWithValues: leds.enumerated().map { ($1, packed(hue: $0 * spread)) })
        let flash = Dictionary(uniqueKeysWithValues: leds.map { ($0, white()) })
        steps.append(Step(colors: flash, underglow: white(), underglowEffect: .solid, hold: 0.12))
        steps.append(Step(colors: [:], underglow: 0, underglowEffect: .off, hold: 0.08))
        steps.append(Step(colors: rainbow, underglow: ring(17), underglowEffect: .solid, hold: 0.5))
        steps.append(Step(colors: [:], underglow: 0, underglowEffect: .off, hold: 0.08))
        steps.append(Step(colors: rainbow, underglow: 0xFFFFFF, underglowEffect: .rainbow, hold: 0.92))
        return steps
    }

    // MARK: Playback shapes

    /// One step as a device call. Every slot is sent every time: omitted
    /// fields latch on the firmware, so a dark key is explicitly turned off
    /// rather than left holding whatever it had.
    static func threads(for step: Step) -> [VOAI.ThreadParam] {
        VOAI.ledIndexForAgentSlot.indices.map { slot in
            let color = step.colors[VOAI.ledIndexForAgentSlot[slot]]
            return VOAI.ThreadParam(
                id: slot,
                c: color ?? 0,
                b: color == nil ? 0 : 1,
                e: (color == nil ? VOAI.Effect.off : VOAI.Effect.solid).rawValue,
                s: 0.5,
                sk: 0,
                sa: 0)
        }
    }

    /// The same step as an on-screen frame, so the app window and the physical
    /// board show the same colours in a screen recording.
    static func frame(for step: Step, ledCount: Int) -> EffectFrame {
        var perLED = Array(repeating: HSV.off, count: ledCount)
        var specs: [Int: LEDSpec] = [:]
        for led in 0..<ledCount {
            let color = hsv(step.colors[led] ?? 0)
            perLED[led] = color
            specs[led] = LEDSpec(color: color, kind: .solid)
        }
        let ring = hsv(step.underglowEffect == .off ? 0 : step.underglow)
        return EffectFrame(perLED: perLED, wholeBoard: ring, underglow: ring, perLEDSpecs: specs)
    }

    // MARK: Colour

    /// Packed RGB for a hue (0–255, wrapping), scaled by brightness. The show
    /// dims in the colour itself rather than the `b` field so a step is one
    /// value the on-screen mirror can read back.
    static func packed(hue: Int, brightness: Double = 1) -> UInt32 {
        let (r, g, b) = HSV(h: UInt8(truncatingIfNeeded: hue), s: 255, v: 255).rgb
        return pack(r * brightness, g * brightness, b * brightness)
    }

    static func white(_ brightness: Double = 1) -> UInt32 {
        pack(brightness, brightness, brightness)
    }

    static func hsv(_ color: UInt32) -> HSV {
        HSV(r: Double((color >> 16) & 0xFF) / 255,
            g: Double((color >> 8) & 0xFF) / 255,
            b: Double(color & 0xFF) / 255)
    }

    private static func pack(_ r: Double, _ g: Double, _ b: Double) -> UInt32 {
        func channel(_ value: Double) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return (channel(r) << 16) | (channel(g) << 8) | channel(b)
    }

    /// A tiny seeded generator: the confetti has to look random and be the
    /// same every run, so takes cut together.
    private struct Roll {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }
}
