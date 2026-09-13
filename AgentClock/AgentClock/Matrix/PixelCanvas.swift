import Foundation

/// An RGB pixel buffer the size of the panel. Deliberately dumb and pure: the
/// renderer draws into it, the view reads out of it, and tests can assert on
/// individual pixels without a screen.
struct PixelCanvas: Equatable, Sendable {
    struct RGB: Equatable, Sendable {
        var r: UInt8
        var g: UInt8
        var b: UInt8

        static let off = RGB(r: 0, g: 0, b: 0)
        var isLit: Bool { r > 0 || g > 0 || b > 0 }

        /// Parse `#RRGGBB`, falling back to white — the renderer must always
        /// produce *something*, and an unreadable colour is a bug to see, not
        /// a page to drop.
        init(hex: String) {
            var text = hex
            if text.hasPrefix("#") { text.removeFirst() }
            guard text.count == 6, let value = UInt32(text, radix: 16) else {
                self = RGB(r: 255, g: 255, b: 255)
                return
            }
            r = UInt8((value >> 16) & 0xFF)
            g = UInt8((value >> 8) & 0xFF)
            b = UInt8(value & 0xFF)
        }

        init(r: UInt8, g: UInt8, b: UInt8) {
            self.r = r
            self.g = g
            self.b = b
        }

        func scaled(by factor: Double) -> RGB {
            let clamp = { (value: UInt8) in UInt8(max(0, min(255, Double(value) * factor))) }
            return RGB(r: clamp(r), g: clamp(g), b: clamp(b))
        }
    }

    let width: Int
    let height: Int
    private(set) var pixels: [RGB]

    init(width: Int = 32, height: Int = 8) {
        self.width = width
        self.height = height
        pixels = Array(repeating: .off, count: width * height)
    }

    subscript(x: Int, y: Int) -> RGB {
        get {
            guard x >= 0, x < width, y >= 0, y < height else { return .off }
            return pixels[y * width + x]
        }
        set {
            // Silently clipped rather than trapped: text scrolls past both
            // edges by design, so out-of-bounds writes are the normal case.
            guard x >= 0, x < width, y >= 0, y < height else { return }
            pixels[y * width + x] = newValue
        }
    }

    mutating func clear() {
        pixels = Array(repeating: .off, count: width * height)
    }

    /// Draw one glyph with its top-left at (x, y). Returns the advance.
    /// Draw one glyph inside its fixed-width cell, centred, and return the cell
    /// advance. Narrow ink (an `I`) sits in the middle of its 4px cell rather
    /// than hugging the left edge, which is what a fixed-width font looks like.
    @discardableResult
    mutating func draw(_ character: Character, at x: Int, y: Int, color: RGB) -> Int {
        if let emoji = EmojiGlyph.sprite(for: character) {
            for (rowIndex, row) in emoji.rows.enumerated() {
                for (columnIndex, cell) in row.enumerated() {
                    if let pixel = emoji.palette[cell] {
                        self[x + columnIndex, y + rowIndex] = pixel
                    }
                }
            }
            return emoji.advance
        }
        let advance = MatrixFont.width(of: character)
        guard character != " " else { return advance }
        let rows = MatrixFont.rows(for: character)
        let inset = max(0, (MatrixFont.artWidth - MatrixFont.artWidth(of: character)) / 2)
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, cell) in row.enumerated() where cell == "#" {
                self[x + inset + columnIndex, y + rowIndex] = color
            }
        }
        return advance
    }

    /// Draw a string starting at (x, y), which may be negative — that is how
    /// scrolling works.
    mutating func draw(_ text: String, at x: Int, y: Int, color: RGB) {
        var cursor = x
        for character in text {
            // Skip glyphs entirely off-canvas; a long scrolling string is
            // mostly off-canvas at any moment.
            if cursor > width { break }
            let advance = MatrixFont.width(of: character)
            if cursor + advance >= 0 {
                draw(character, at: cursor, y: y, color: color)
            }
            cursor += advance
        }
    }
}
