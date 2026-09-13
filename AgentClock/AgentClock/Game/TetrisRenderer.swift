import Foundation

/// Draws a game of Tetris onto the panel.
///
/// The playfield *is* the panel — 32×8 with nothing else on it. There is no
/// room for a score, a next-piece box or a border, and every pixel spent on
/// chrome is a pixel of well. The score lives on the Mac; the panel plays the
/// game.
enum TetrisRenderer {

    static func render(_ game: Tetris, width: Int = Tetris.depth,
                       height: Int = Tetris.across,
                       flash: Double = 0,
                       showsGhost: Bool = true) -> PixelCanvas {
        var canvas = PixelCanvas(width: width, height: height)

        for column in 0..<min(width, Tetris.depth) {
            for row in 0..<min(height, Tetris.across) {
                if let color = game.cell(column: column, row: row) {
                    canvas[column, row] = PixelCanvas.RGB(hex: color)
                }
            }
        }

        if let active = game.active {
            let color = PixelCanvas.RGB(hex: active.piece.color)
            // The landing shadow: where the piece would come to rest if you
            // stopped steering. On a well 32 deep the piece is often far from
            // the stack, and without this you are guessing.
            if showsGhost {
                for cell in landingCells(of: game) {
                    canvas[cell.column, cell.row] = color.scaled(by: 0.22)
                }
            }
            for cell in Tetris.cells(of: active) {
                canvas[cell.column, cell.row] = color
            }
        }

        if game.isOver {
            // Dim everything rather than clearing it: the board you lost with
            // is worth looking at.
            for y in 0..<canvas.height {
                for x in 0..<canvas.width {
                    canvas[x, y] = canvas[x, y].scaled(by: 0.35)
                }
            }
        } else if flash > 0 {
            // A brief white wash when columns clear, so a tetris registers.
            for y in 0..<canvas.height {
                for x in 0..<canvas.width where canvas[x, y].isLit {
                    canvas[x, y] = blend(canvas[x, y], toward: .init(r: 255, g: 255, b: 255),
                                         amount: min(1, flash))
                }
            }
        }
        return canvas
    }

    /// Where the active piece would land, found by walking it down a copy.
    static func landingCells(of game: Tetris) -> [Tetris.Cell] {
        guard var active = game.active else { return [] }
        var landed = active
        while true {
            var next = landed
            next.origin.column -= 1
            guard game.fits(next) else { break }
            landed = next
        }
        active = landed
        return Tetris.cells(of: active)
    }

    private static func blend(_ base: PixelCanvas.RGB, toward target: PixelCanvas.RGB,
                              amount: Double) -> PixelCanvas.RGB {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(max(0, min(255, Double(a) + (Double(b) - Double(a)) * amount)))
        }
        return .init(r: mix(base.r, target.r), g: mix(base.g, target.g), b: mix(base.b, target.b))
    }
}
