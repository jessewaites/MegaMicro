import Foundation

/// A proportional 5-pixel-tall bitmap font, in the spirit of the `small` font
/// AWTRIX renders with.
///
/// Two jobs. It draws the on-screen simulator, and it *measures* — which is
/// what tells the planner whether a page's text fits in the panel or has to
/// scroll. Measuring proportionally matters: "III" and "MMM" are the same
/// character count and nearly triple the pixel width apart, so a flat
/// characters-times-N estimate scrolls pages that would have fit and vice
/// versa.
///
/// This is a stand-in, not a copy of the firmware's font. Glyph widths are
/// close enough to make layout decisions sensible, but the real panel is the
/// authority — see `tracking` if the simulator and the hardware disagree.
enum MatrixFont {
    /// Glyph height. The firmware documents the small font as "capital height:
    /// 5 px", rows 1-5 of the eight.
    static let height = 5

    /// Every character advances the same 4 px — the firmware documents
    /// "character width: 4 px" for both fonts, so this is **fixed** width, not
    /// proportional.
    ///
    /// That correction matters more than it looks. Measuring proportionally
    /// (I = 1 px, M = 5 px) made the planner's fit decisions disagree with the
    /// hardware in both directions: narrow strings were scrolled that would
    /// have fit, wide ones were left static and would have run off the panel.
    /// Glyph art is drawn 3 px wide and centred in the cell, leaving 1 px of
    /// natural spacing.
    static let advance = 4
    /// The firmware documents "space width: 2 px" — narrower than a character.
    static let spaceWidth = 2
    /// Widest glyph art. Anything wider would bleed into the next cell.
    static let artWidth = 3

    /// Rows top to bottom, `#` lit. Authored as pictures on purpose: a glyph
    /// you can read in the source is a glyph you can fix in the source.
    static let glyphs: [Character: [String]] = [
        "A": [".#.", "#.#", "###", "#.#", "#.#"],
        "B": ["##.", "#.#", "##.", "#.#", "##."],
        "C": [".##", "#..", "#..", "#..", ".##"],
        "D": ["##.", "#.#", "#.#", "#.#", "##."],
        "E": ["###", "#..", "##.", "#..", "###"],
        "F": ["###", "#..", "##.", "#..", "#.."],
        "G": [".##", "#..", "#.#", "#.#", ".##"],
        "H": ["#.#", "#.#", "###", "#.#", "#.#"],
        "I": ["#", "#", "#", "#", "#"],
        "J": ["..#", "..#", "..#", "#.#", ".#."],
        "K": ["#.#", "#.#", "##.", "#.#", "#.#"],
        "L": ["#..", "#..", "#..", "#..", "###"],
        "M": ["#.#", "###", "###", "#.#", "#.#"],
        "N": ["#.#", "##.", "###", ".##", "#.#"],
        "O": [".#.", "#.#", "#.#", "#.#", ".#."],
        "P": ["##.", "#.#", "##.", "#..", "#.."],
        "Q": [".#.", "#.#", "#.#", "##.", ".##"],
        "R": ["##.", "#.#", "##.", "#.#", "#.#"],
        "S": [".##", "#..", ".#.", "..#", "##."],
        "T": ["###", ".#.", ".#.", ".#.", ".#."],
        "U": ["#.#", "#.#", "#.#", "#.#", ".#."],
        "V": ["#.#", "#.#", "#.#", ".#.", ".#."],
        "W": ["#.#", "#.#", "###", "###", "#.#"],
        "X": ["#.#", "#.#", ".#.", "#.#", "#.#"],
        "Y": ["#.#", "#.#", ".#.", ".#.", ".#."],
        "Z": ["###", "..#", ".#.", "#..", "###"],

        "0": [".#.", "#.#", "#.#", "#.#", ".#."],
        "1": [".#.", "##.", ".#.", ".#.", "###"],
        "2": ["##.", "..#", ".#.", "#..", "###"],
        "3": ["##.", "..#", ".#.", "..#", "##."],
        "4": ["#.#", "#.#", "###", "..#", "..#"],
        "5": ["###", "#..", "##.", "..#", "##."],
        "6": [".#.", "#..", "###", "#.#", ".#."],
        "7": ["###", "..#", ".#.", ".#.", ".#."],
        "8": [".#.", "#.#", ".#.", "#.#", ".#."],
        "9": [".#.", "#.#", "###", "..#", ".#."],

        ".": [".", ".", ".", ".", "#"],
        ",": [".", ".", ".", "#", "#"],
        ":": [".", "#", ".", "#", "."],
        "-": ["...", "...", "###", "...", "..."],
        "_": ["...", "...", "...", "...", "###"],
        "+": ["...", ".#.", "###", ".#.", "..."],
        "!": ["#", "#", "#", ".", "#"],
        "?": ["##.", "..#", ".#.", "...", ".#."],
        "/": ["..#", "..#", ".#.", "#..", "#.."],
        "%": ["#.#", "..#", ".#.", "#..", "#.#"],
        "#": ["#.#", "###", "#.#", "###", "#.#"],
        ">": ["#..", ".#.", "..#", ".#.", "#.."],
        "<": ["..#", ".#.", "#..", ".#.", "..#"],
        "(": [".#", "#.", "#.", "#.", ".#"],
        ")": ["#.", ".#", ".#", ".#", "#."],
        "·": [".", ".", "#", ".", "."],
        "x": ["...", "...", "#.#", ".#.", "#.#"],
        "'": ["#", "#", ".", ".", "."],
        // Continuation mark for a truncated label. Three pixels — about one
        // character — buys the difference between "AGENTCLO" reading as a
        // broken word and "AGENTCL…" reading as a deliberate abbreviation.
        "…": ["...", "...", "...", "...", "#.#"],
    ]

    /// Anything unmapped draws as a hollow box, which reads as "missing glyph"
    /// instead of silently swallowing a character.
    static let fallback = ["###", "#.#", "#.#", "#.#", "###"]

    static func rows(for character: Character) -> [String] {
        if let glyph = glyphs[character] { return glyph }
        // Lower-case falls back to the upper-case form: the panel is too small
        // for a second case, and AgentClock upper-cases its labels anyway.
        if let upper = character.uppercased().first, let glyph = glyphs[upper] { return glyph }
        return fallback
    }

    /// Cell width — how far the cursor moves, not how wide the ink is.
    static func width(of character: Character) -> Int {
        if let emoji = EmojiGlyph.sprite(for: character) { return emoji.advance }
        return character == " " ? spaceWidth : advance
    }

    /// Rendered pixel width of a whole string.
    static func width(of text: String) -> Int {
        text.reduce(0) { $0 + width(of: $1) }
    }

    /// Ink width of a glyph, for centring it inside its cell.
    static func artWidth(of character: Character) -> Int {
        if let emoji = EmojiGlyph.sprite(for: character) { return emoji.width }
        return character == " " ? 0 : (rows(for: character).first?.count ?? 0)
    }
}
