import Foundation

/// The opening titles: the Claude Code creature walks in from the right, stops
/// and waves, then the Codex ball bounces in beside it.
///
/// The creature is drawn from code rather than stamped from its GIF, because
/// the walk needs its legs to alternate and the wave needs one arm to lift —
/// neither of which a single static frame can do. The proportions match
/// `Icons/src/acclaude.json` exactly; if that art is redrawn, this needs the
/// same edit.
enum IntroAnimation {

    // MARK: Timing

    static let walkDuration: TimeInterval = 3.4
    static let waveDuration: TimeInterval = 2.4
    static let slideDuration: TimeInterval = 2.2
    /// Where Codex makes contact — hard against the creature's right edge.
    static let bumpX = 12
    /// Fraction of the slide spent approaching, before the bump.
    static let approachFraction = 0.55
    static let holdDuration: TimeInterval = 1.6
    static var total: TimeInterval { walkDuration + waveDuration + slideDuration + holdDuration }

    static let claudeColor = "#D97757"
    static let codexColor = "#96A5FF"

    /// Where the creature comes to rest.
    static let restX = 1
    /// Where the Codex mark settles — a comfortable gap from the creature
    /// rather than right up against it.
    static let promptRestX = 17

    // MARK: The creature

    /// Eleven wide, eight tall. `legPhase` alternates which pair of legs is
    /// planted; `armPhase` waves.
    ///
    /// The wave works like an arm rather than a lever: the upper arm — the nub
    /// on rows 3 and 4 — never moves, and a forearm rises from it and swings
    /// between two columns. Earlier versions lifted the whole nub, which made
    /// the creature look like it was shrugging, and before that redrew the body
    /// rows, which made its head twitch.
    static func creature(legPhase: Int, armPhase: ArmPhase) -> [String] {
        var rows = [
            "..#######..",
            "..#######..",
            "..#.###.#..",
            "###########",
            "###########",
            "..#######..",
            "..#######..",
            "..#.#.#.#..",
        ]
        // Walk cycle: lift one diagonal pair of legs, then the other. Two
        // frames is all a four-legged silhouette needs to read as walking.
        rows[7] = switch legPhase {
        case 0: "..#.#.#.#.."
        case 1: "..#...#...."
        default: "....#...#.."
        }
        // Rows 0 and 3-7 never change while waving: the head, the eyes, the
        // upper arms and the legs all hold still. Only the forearm moves, and
        // only in columns 0 and 1.
        switch armPhase {
        case .down:
            break
        case .out:
            rows[1] = "#.#######.."   // hand out at column 0
            rows[2] = "#.#.###.#.."   // forearm, joining the shoulder below
        case .over:
            rows[1] = ".########.."   // hand swung in to column 1
            rows[2] = ".##.###.#.."
        }
        return rows
    }

    enum ArmPhase { case down, out, over }

    /// The Codex mark comes straight from the icon the pages use, at full
    /// size. It only had to be a hand-drawn miniature while it was bouncing:
    /// a bounce needs headroom, and the real seven-row mark leaves one pixel
    /// of it. Sliding needs no headroom at all, so the intro and the page can
    /// now show the identical mark — and it cannot drift, because it is
    /// literally the same art.
    static var codexMark: PixelIcon? { PixelIcon.bundled(id: "accodex") }

    // MARK: Frames

    static func frame(at time: TimeInterval, width: Int = 32) -> PixelCanvas {
        var canvas = PixelCanvas(width: width, height: 8)
        let claude = PixelCanvas.RGB(hex: claudeColor)
        let codex = PixelCanvas.RGB(hex: codexColor)

        let walkEnd = walkDuration
        let waveEnd = walkEnd + waveDuration

        // The creature: walking, then parked.
        let creatureX: Int
        let legPhase: Int
        var armPhase = ArmPhase.down

        if time < walkEnd {
            let progress = time / walkDuration
            creatureX = Int((Double(width) - (Double(width) - Double(restX)) * progress).rounded())
            // Step roughly three times a second — slow enough to read as steps
            // rather than a blur.
            legPhase = Int(time * 6) % 2 == 0 ? 1 : 2
        } else {
            // A one-pixel jolt when Codex lands against it, then back.
            let bumpAt = waveEnd + slideDuration * approachFraction
            let jolted = time >= bumpAt && time < bumpAt + 0.18
            creatureX = jolted ? restX + 1 : restX
            legPhase = 0
            if time < waveEnd {
                // A beat to settle after walking, then the forearm comes up and
                // swings back and forth, then it drops.
                let waveTime = time - walkEnd
                if waveTime > 0.35 && waveTime < 2.0 {
                    armPhase = Int((waveTime - 0.35) * 5) % 2 == 0 ? .out : .over
                }
            }
        }
        draw(creature(legPhase: legPhase, armPhase: armPhase),
             at: creatureX, y: 0, color: claude, into: &canvas)

        // Codex slides in, bumps into the creature, and backs off to a polite
        // distance.
        //
        // The bump is not only for fun: a single eased slide spends most of its
        // time covering the last few pixels, so it crawls one pixel every
        // several frames and reads as stepping. Splitting the move into a quick
        // approach and a quick recoil keeps the speed up throughout, which is
        // what actually looks smooth on a pixel grid.
        if time >= waveEnd, let icon = codexMark {
            let progress = min(1, (time - waveEnd) / slideDuration)
            let x: Double
            if progress < approachFraction {
                // Approach: barely eased, so it keeps moving.
                let leg = progress / approachFraction
                x = Double(width) - (Double(width) - Double(bumpX)) * (1 - pow(1 - leg, 2))
            } else {
                // Recoil: springs back off the creature and settles.
                let leg = (progress - approachFraction) / (1 - approachFraction)
                x = Double(bumpX) + (Double(promptRestX) - Double(bumpX)) * (1 - pow(1 - leg, 2))
            }
            drawIcon(icon, at: Int(x.rounded()), tint: codex, into: &canvas)
        }
        return canvas
    }

    /// Stamp a bundled mark, tinted. The intro brightens Codex's resting
    /// #011299 — a title sequence has to read, and that navy is nearly black
    /// against an unlit panel.
    private static func drawIcon(_ icon: PixelIcon, at x: Int,
                                 tint: PixelCanvas.RGB, into canvas: inout PixelCanvas) {
        guard let pixels = icon.frames.first else { return }
        for y in 0..<icon.height {
            for column in 0..<icon.width where pixels[y * icon.width + column].isLit {
                canvas[x + column, y] = tint
            }
        }
    }

    private static func draw(_ art: [String], at x: Int, y: Int,
                             color: PixelCanvas.RGB, into canvas: inout PixelCanvas) {
        for (row, line) in art.enumerated() {
            for (column, cell) in line.enumerated() where cell == "#" {
                canvas[x + column, y + row] = color
            }
        }
    }
}
