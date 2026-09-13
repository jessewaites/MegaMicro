import Foundation

/// Colour emoji deliberately redrawn for an eight-pixel display.
///
/// Full-size emoji artwork becomes muddy when blindly reduced to 7×7. Keeping
/// a tiny sprite atlas makes every supported glyph legible and gives the
/// simulator and physical panel exactly the same pixels.
enum EmojiGlyph {
    struct Sprite {
        let rows: [String]
        let palette: [Character: PixelCanvas.RGB]

        var width: Int { rows.first?.count ?? 0 }
        var height: Int { rows.count }
        var advance: Int { width + 1 }
    }

    private static let red = PixelCanvas.RGB(r: 255, g: 35, b: 70)
    private static let highlight = PixelCanvas.RGB(r: 255, g: 105, b: 125)

    private static let heart = Sprite(
        rows: [
            ".hh.hh.",
            "hRRhRRh",
            "hRRRRRh",
            ".RRRRR.",
            "..RRR..",
            "...R...",
            ".......",
        ],
        palette: ["R": red, "h": highlight])

    static func sprite(for character: Character) -> Sprite? {
        // Character keeps the variation selector and ZWJ components together,
        // so all common text/red-heart spellings arrive here as one glyph.
        switch String(character) {
        case "❤", "❤️", "♥", "♥️": heart
        default: nil
        }
    }
}
