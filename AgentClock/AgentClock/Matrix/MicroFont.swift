import Foundation

/// A three-row proportional font, for the few words small enough to belong on
/// the panel — currently just the provider's name when it has no crew to show.
///
/// Proportional where the firmware's own font is fixed-width: we draw this
/// ourselves, pixel by pixel, so an `M` can have five columns and an `I` one.
/// That is the only way letters stay distinct at three rows tall, and it buys
/// the room that makes "CLAUDE" fit beside an eleven-pixel mark at all.
enum MicroFont {
    static let height = 3
    /// Blank columns between glyphs.
    static let tracking = 1

    static let glyphs: [Character: [String]] = [
        "A": [".#.", "###", "#.#"], "B": ["##.", "###", "###"],
        "C": ["###", "#..", "###"], "D": ["##.", "#.#", "##."],
        "E": ["###", "##.", "###"], "F": ["###", "##.", "#.."],
        "G": ["###", "#.#", "###"], "H": ["#.#", "###", "#.#"],
        "I": ["#", "#", "#"],       "J": ["..#", "..#", "##."],
        "K": ["#.#", "##.", "#.#"], "L": ["#.", "#.", "##"],
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
        if let glyph = glyphs[character] { return glyph }
        if let upper = character.uppercased().first, let glyph = glyphs[upper] { return glyph }
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


    static func art(for character: Character) -> [String] {
        if let glyph = glyphs[character] { return glyph }
        if let upper = character.uppercased().first, let glyph = glyphs[upper] { return glyph }
        return ["###", "#.#", "###"]
    }

    static func width(of character: Character) -> Int {
        character == " " ? 2 : (art(for: character).first?.count ?? 0)
    }

    static func width(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.map(width(of:)).reduce(0, +) + tracking * (text.count - 1)
    }

    static func draw(_ text: String, into canvas: inout PixelCanvas,
                     at x: Int, y: Int, color: PixelCanvas.RGB) {
        var cursor = x
        for character in text {
            for (row, line) in art(for: character).enumerated() {
                for (column, cell) in line.enumerated() where cell == "#" {
                    canvas[cursor + column, y + row] = color
                }
            }
            cursor += width(of: character) + tracking
        }
    }
}
