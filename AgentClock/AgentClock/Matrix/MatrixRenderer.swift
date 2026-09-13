import Foundation

/// Renders a `ClockPage` the way the panel would.
///
/// This is an approximation of the firmware, not a port of it — the font is a
/// stand-in and the scroll easing is a guess. What it is good for is exactly
/// what it was built for: iterating on layout, colour and pacing without the
/// hardware, and seeing immediately when a label is too long to read.
enum MatrixRenderer {
    /// Where the 5-row font sits on an 8-row panel: one blank row above, two
    /// below, which leaves the bottom row free for the fleet page's pips.
    static let textTop = 1
    /// Documented base scroll rate: 21 px/s at speed 100.
    static let scrollPixelsPerSecond = 21.0
    /// Blank columns between the end of a scrolling string and its next repeat,
    /// so a looping label doesn't run into its own head.
    static let scrollGap = 6

    static func render(_ page: ClockPage, width: Int = 32, height: Int = 8,
                       time: TimeInterval = 0) -> PixelCanvas {
        var canvas = PixelCanvas(width: width, height: height)

        var textLeft = 0
        if let iconID = page.icon, let icon = PixelIcon.bundled(id: iconID) {
            draw(icon, into: &canvas, time: time)
            textLeft = icon.width
        }

        let color = PixelCanvas.RGB(hex: page.textColor)
        let available = width - textLeft
        let textWidth = MatrixFont.width(of: page.text)

        switch page.scroll {
        case .some(.loop), .some(.bounce), .some(.wrap):
            drawScrolling(page.text, into: &canvas, left: textLeft, available: available,
                          textWidth: textWidth, color: color, mode: page.scroll!,
                          speed: page.scrollSpeed ?? 100, time: time)
        case .some(.static), .none:
            // Centre it when it fits, which is what `textCenter` does on the
            // device; left-align when it doesn't so the start is readable.
            let x = textWidth <= available ? textLeft + (available - textWidth) / 2 : textLeft
            canvas.draw(page.text, at: x, y: textTop, color: color)
        }

        // Draw commands belong to the text-and-decorations layer, which the
        // device paints *before* the icon — so anything under an icon's columns
        // is covered on real hardware. Reproduce that here rather than
        // flattering the simulator, or the preview shows pixels the panel
        // never will. (With no icon, `textLeft` is 0 and nothing is clipped,
        // which is the case for the fully-drawn provider pages.)
        for command in page.draw {
            let color = PixelCanvas.RGB(hex: command.color ?? page.textColor)
            switch command.op {
            case "pixel" where command.args.count >= 2:
                let x = command.args[0]
                if x >= textLeft { canvas[x, command.args[1]] = color }
            case "line" where command.args.count >= 4:
                // Horizontal and vertical runs only — that is all the encoder
                // emits, and all a 32×8 panel needs.
                let (x0, y0, x1, y1) = (command.args[0], command.args[1],
                                        command.args[2], command.args[3])
                for x in min(x0, x1)...max(x0, x1) where x >= textLeft {
                    for y in min(y0, y1)...max(y0, y1) { canvas[x, y] = color }
                }
            default:
                continue
            }
        }
        return animated(canvas, style: page.animation, time: time)
    }

    /// Apply an entrance to an already-composed frame. Moving final pixels
    /// rather than re-laying out text also animates emoji and draw commands.
    private static func animated(_ final: PixelCanvas, style: MessageAnimation?,
                                 time: TimeInterval) -> PixelCanvas {
        guard let style, style != .none else { return final }
        let duration = 1.35
        let progress = max(0, min(1, time / duration))
        guard progress < 1 else { return final }
        var frame = PixelCanvas(width: final.width, height: final.height)

        switch style {
        case .none:
            return final
        case .stream:
            let eased = 1 - pow(1 - progress, 3)
            let offset = Int((Double(final.width) * (1 - eased)).rounded())
            for y in 0..<final.height {
                for x in 0..<final.width where final[x, y].isLit {
                    frame[x + offset, y] = final[x, y]
                }
            }
        case .fall:
            // Columns land in a short left-to-right cascade. Each final pixel
            // begins above the panel and settles with a gentle ease-out.
            for x in 0..<final.width {
                let delay = Double(x) / Double(max(1, final.width - 1)) * 0.32
                let local = max(0, min(1, (progress - delay) / (1 - delay)))
                let eased = 1 - pow(1 - local, 3)
                let offset = -Int((Double(final.height) * (1 - eased)).rounded())
                for y in 0..<final.height where final[x, y].isLit {
                    frame[x, y + offset] = final[x, y]
                }
            }
        case .showcase:
            // MessagePlayback expands the showcase into alternating fall and
            // stream phases. A standalone render uses the rain entrance.
            return animated(final, style: .fall, time: time)
        }
        return frame
    }

    private static func draw(_ icon: PixelIcon, into canvas: inout PixelCanvas, time: TimeInterval) {
        let pixels = icon.frame(at: time)
        for y in 0..<icon.height {
            for x in 0..<icon.width {
                let pixel = pixels[y * icon.width + x]
                // Black is off on an LED panel, and the firmware treats
                // transparent the same way — so don't paint it.
                if pixel.isLit { canvas[x, y] = pixel }
            }
        }
    }

    private static func drawScrolling(_ text: String, into canvas: inout PixelCanvas,
                                      left: Int, available: Int, textWidth: Int,
                                      color: PixelCanvas.RGB, mode: ClockPage.ScrollMode,
                                      speed: Int, time: TimeInterval) {
        // Text that fits doesn't move, whatever the mode says — a jittering
        // six-character label is worse than a still one.
        guard textWidth > available else {
            canvas.draw(text, at: left + (available - textWidth) / 2, y: textTop, color: color)
            return
        }

        let rate = scrollPixelsPerSecond * Double(max(1, speed)) / 100
        let travel = Double(textWidth + scrollGap)
        let offset: Double
        switch mode {
        case .bounce:
            // Ping-pong across the overflow, pausing at each end.
            let span = Double(textWidth - available)
            let period = (span * 2) / rate
            let phase = period > 0 ? time.truncatingRemainder(dividingBy: period) / period : 0
            offset = phase < 0.5 ? span * (phase * 2) : span * (2 - phase * 2)
        case .loop, .wrap, .static:
            offset = (time * rate).truncatingRemainder(dividingBy: travel)
        }

        var canvasCopy = canvas
        canvasCopy.draw(text, at: left - Int(offset), y: textTop, color: color)
        if mode != .bounce {
            // Second copy trailing the first, so the loop has no blank gap
            // wider than `scrollGap`.
            canvasCopy.draw(text, at: left - Int(offset) + Int(travel), y: textTop, color: color)
        }

        // Everything left of the icon belongs to the icon: repaint that strip
        // so scrolling text passes *behind* it rather than over it.
        for y in 0..<canvas.height {
            for x in left..<canvas.width {
                canvas[x, y] = canvasCopy[x, y]
            }
        }
    }
}
