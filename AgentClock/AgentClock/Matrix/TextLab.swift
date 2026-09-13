import Foundation

/// EXPERIMENTAL — a scratchpad for choosing how text should look on the panel.
///
/// Delete this file and `TextLabPane.swift` once the treatment is settled and
/// folded into `MatrixFont` / `PagePlanner`. Nothing else depends on it.
///
/// The question it exists to answer: 32×8 fits eight characters of the
/// firmware's 5-row font, which cuts most project names. The alternatives are
/// a shorter font (more characters per line) or two stacked lines (twice the
/// characters, half the height each) — and neither is judgeable from a table of
/// pixel counts.
enum TextLab {

    /// A 3-row font, deliberately **proportional** where `MatrixFont` is fixed.
    ///
    /// The firmware's own font must be fixed-width because the firmware draws
    /// it. This one would be drawn by us, pixel by pixel via `draw` commands,
    /// so it can spend 5 px on an `M` and 1 px on an `I` — which is the only
    /// way M/N/W stay distinguishable from H at three rows tall.
    static let rows3: [Character: [String]] = [
        "A": [".#.", "###", "#.#"], "B": ["##.", "###", "###"],
        "C": ["###", "#..", "###"], "D": ["##.", "#.#", "##."],
        "E": ["###", "##.", "###"], "F": ["###", "##.", "#.."],
        "G": ["###", "#.#", "###"], "H": ["#.#", "###", "#.#"],
        "I": ["#", "#", "#"],       "J": ["..#", "..#", "##."],
        "K": ["#.#", "##.", "#.#"], "L": ["#..", "#..", "###"],
        "M": ["#...#", "##.##", "#.#.#"],
        "N": ["##.#", "#.##", "#..#"],
        "O": ["###", "#.#", "###"], "P": ["###", "###", "#.."],
        "Q": ["###", "#.#", "###"], "R": ["##.", "###", "#.#"],
        "S": [".##", ".#.", "##."], "T": ["###", ".#.", ".#."],
        "U": ["#.#", "#.#", "###"], "V": ["#.#", "#.#", ".#."],
        "W": ["#...#", "#.#.#", ".#.#."],
        "X": ["#.#", ".#.", "#.#"], "Y": ["#.#", ".#.", ".#."],
        "Z": ["##.", ".#.", ".##"],
        "0": ["###", "#.#", "###"], "1": [".#", "##", ".#"],
        "2": ["##.", ".#.", ".##"], "3": ["##.", ".##", "##."],
        "4": ["#.#", "###", "..#"], "5": [".##", ".#.", "##."],
        "6": ["#..", "###", "###"], "7": ["###", "..#", "..#"],
        "8": ["###", "###", "###"], "9": ["###", "###", "..#"],
        "-": ["...", "###", "..."], ".": [".", ".", "#"],
        " ": [".", ".", "."],
    ]

    static let height3 = 3
    /// Gap between glyphs, in the 3-row font.
    static let tracking3 = 1

    static func art3(for character: Character) -> [String] {
        if let glyph = rows3[character] { return glyph }
        if let upper = character.uppercased().first, let glyph = rows3[upper] { return glyph }
        return ["###", "#.#", "###"]
    }

    static func width3(of character: Character) -> Int {
        character == " " ? 2 : (art3(for: character).first?.count ?? 0)
    }

    static func width3(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.map(width3(of:)).reduce(0, +) + tracking3 * (text.count - 1)
    }

    static func draw3(_ text: String, into canvas: inout PixelCanvas,
                      at x: Int, y: Int, color: PixelCanvas.RGB) {
        var cursor = x
        for character in text {
            let art = art3(for: character)
            for (rowIndex, row) in art.enumerated() {
                for (columnIndex, cell) in row.enumerated() where cell == "#" {
                    canvas[cursor + columnIndex, y + rowIndex] = color
                }
            }
            cursor += width3(of: character) + tracking3
        }
    }

    // MARK: Splitting a name across two lines

    /// Break a label into two lines the way a person would read it.
    ///
    /// Prefers an existing separator nearest the middle — "add-auth-flow" wants
    /// to break at a dash, not mid-word. With no separator, splits at the
    /// midpoint, which is what makes "megamicro" read as MEGA / MICRO.
    static func split(_ text: String) -> (String, String) {
        // Only break a name that genuinely needs it. Splitting "auth" into
        // AU / TH is worse than either alternative.
        guard width3(of: text) > 32 else { return (text, "") }
        let characters = Array(text)
        let middle = characters.count / 2

        let separators: Set<Character> = ["-", "_", " ", ".", "/"]
        let breaks = characters.indices.filter { separators.contains(characters[$0]) }
        if let best = breaks.min(by: { abs($0 - middle) < abs($1 - middle) }) {
            let first = String(characters[..<best])
            let second = String(characters[(best + 1)...])
            if !first.isEmpty && !second.isEmpty { return (first, second) }
        }
        return (String(characters[..<middle]), String(characters[middle...]))
    }

    // MARK: Treatments

    enum Treatment: String, CaseIterable, Identifiable {
        case fiveRow = "5-row, one line"
        case stackedName = "3-row, name split over two lines"
        case stackedNameState = "3-row, name on top / state below"
        case hybrid = "Hybrid: 5-row when it fits, else stacked"

        var id: String { rawValue }

        var detail: String {
            switch self {
            case .fiveRow:
                "The firmware's own font. Most legible, natively scrollable — but eight characters and a cut name."
            case .stackedName:
                "Twice the characters. The name breaks at a separator, or at the midpoint. Needs custom pixel rendering."
            case .stackedNameState:
                "Both facts at once, no rotation needed — which is the argument for keeping the state word at all."
            case .hybrid:
                "Short names stay big and legible; only long ones drop to the small stacked form."
            }
        }
    }

    /// Render a sample onto a panel-sized canvas.
    static func render(_ label: String, state: AgentState, elapsed: String,
                       treatment: Treatment, colors: [String: String],
                       width: Int = 32, iconID: String? = nil,
                       time: TimeInterval = 0) -> PixelCanvas {
        var canvas = PixelCanvas(width: width, height: 8)
        var left = 0
        if let iconID, let icon = PixelIcon.bundled(id: iconID) {
            let pixels = icon.frame(at: time)
            for y in 0..<icon.height {
                for x in 0..<icon.width where pixels[y * icon.width + x].isLit {
                    canvas[x, y] = pixels[y * icon.width + x]
                }
            }
            left = icon.width
        }
        let color = PixelCanvas.RGB(hex: StatePalette.color(for: state, in: colors))
        let dim = color.scaled(by: 0.55)
        let name = label.uppercased()

        switch treatment {
        case .fiveRow:
            var text = name
            while MatrixFont.width(of: text) > width - left, !text.isEmpty { text.removeLast() }
            canvas.draw(text, at: left, y: 1, color: color)

        case .stackedName:
            let (top, bottom) = split(name)
            if bottom.isEmpty {
                // Fits on one line: centre it vertically rather than leaving a
                // conspicuous empty second row.
                draw3(top, into: &canvas, at: left, y: 2, color: color)
            } else {
                draw3(top, into: &canvas, at: left, y: 0, color: color)
                draw3(bottom, into: &canvas, at: left, y: 4, color: color)
            }

        case .stackedNameState:
            var top = name
            while width3(of: top) > width - left, !top.isEmpty { top.removeLast() }
            draw3(top, into: &canvas, at: left, y: 0, color: color)
            // The second line carries state and elapsed — the two things the
            // rotation currently spends a whole extra page on.
            // Local copy: the planner's text machinery went away when the
            // provider page replaced the text pages, and this lab outlived it.
            let word = switch state {
            case .thinking: "THINK"
            case .coding: "CODE"
            case .waiting: "WAIT"
            case .success: "DONE"
            case .error: "ERROR"
            case .idle: "IDLE"
            }
            let below = elapsed.isEmpty ? word : "\(word) \(elapsed)"
            draw3(below, into: &canvas, at: left, y: 4, color: dim)

        case .hybrid:
            if MatrixFont.width(of: name) <= width - left {
                canvas.draw(name, at: left, y: 1, color: color)
            } else {
                let (top, bottom) = split(name)
                if bottom.isEmpty {
                    draw3(top, into: &canvas, at: left, y: 2, color: color)
                } else {
                    draw3(top, into: &canvas, at: left, y: 0, color: color)
                    draw3(bottom, into: &canvas, at: left, y: 4, color: color)
                }
            }
        }
        return canvas
    }
}
