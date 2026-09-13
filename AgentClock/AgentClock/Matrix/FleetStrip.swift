import Foundation

/// EXPERIMENTAL — the panel as a fleet strip rather than a page of text.
///
/// The premise: 32×8 is too small for words but exactly right for *marks*.
/// 32 ÷ 4 = 8, which is precisely one icon, so up to four agents each get a
/// full-size logo side by side; the colour says what each one is doing. Nothing
/// scrolls, nothing rotates, nothing is truncated, and the whole fleet is
/// legible in the time it takes to glance up.
///
/// Delete with `TextLab` once a direction is chosen.
enum FleetStrip {

    struct Slot: Equatable {
        let source: String
        let state: AgentState
    }

    enum Style: String, CaseIterable, Identifiable {
        /// Brand-coloured mark, with the state as a bar along the bottom row.
        case markAndBar = "Mark + state bar"
        /// The mark itself recoloured to the state. Loudest, but the brand
        /// colour is gone — you read the shape, not the hue.
        case tintedMark = "Mark tinted by state"
        /// Brand-coloured mark inside a one-pixel state-coloured frame.
        case framedMark = "Mark in a state frame"
        /// No marks at all: one solid block per agent. Scales past four.
        case blocks = "Solid blocks only"

        var id: String { rawValue }

        var detail: String {
            switch self {
            case .markAndBar:
                "Who and what, separately. The mark keeps its brand colour so Claude still reads as Claude; the bottom row carries the state."
            case .tintedMark:
                "Strongest colour signal at a distance — the whole mark changes. Costs the brand colour, so you identify the agent by shape alone."
            case .framedMark:
                "Same idea as the bar but wrapped around the mark. Uses more pixels for the state and leaves the mark cramped."
            case .blocks:
                "What every style falls back to past four agents, where there is no longer room for an 8-pixel mark."
            }
        }
    }

    /// Four is the hard limit for marks: below 8 pixels a logo is unreadable.
    static let maximumMarks = 4

    static func render(_ slots: [Slot], style: Style, colors: [String: String],
                       width: Int = 32, time: TimeInterval = 0) -> PixelCanvas {
        var canvas = PixelCanvas(width: width, height: 8)
        guard !slots.isEmpty else { return canvas }

        // Worst state first, so the agent that needs you is leftmost — the
        // place your eye lands.
        let ordered = slots.sorted { $0.state > $1.state }

        guard style != .blocks, ordered.count <= maximumMarks else {
            drawBlocks(ordered, into: &canvas, colors: colors, width: width)
            return canvas
        }

        let slice = width / ordered.count
        for (index, slot) in ordered.enumerated() {
            let originX = index * slice + (slice - 8) / 2
            let stateColor = PixelCanvas.RGB(hex: StatePalette.color(for: slot.state, in: colors))
            drawMark(slot, at: originX, into: &canvas, style: style,
                     stateColor: stateColor, time: time)

            if style == .markAndBar {
                // The bar spans the whole slice, not just the mark, so the
                // strip reads as N segments of colour from across the room.
                for x in (index * slice)..<min(width, (index + 1) * slice - 1) {
                    canvas[x, 7] = stateColor
                }
            }
        }
        return canvas
    }

    private static func drawMark(_ slot: Slot, at originX: Int, into canvas: inout PixelCanvas,
                                 style: Style, stateColor: PixelCanvas.RGB, time: TimeInterval) {
        guard let icon = PixelIcon.bundled(id: IconLibrary.iconID(forSource: slot.source)) else {
            return
        }
        let pixels = icon.frame(at: time)
        // The marks are drawn seven rows tall with row 7 clear, which is what
        // leaves the bottom row free for the state bar.
        let rows = style == .markAndBar ? 7 : 8
        for y in 0..<min(rows, icon.height) {
            for x in 0..<icon.width {
                let pixel = pixels[y * icon.width + x]
                guard pixel.isLit else { continue }
                canvas[originX + x, y] = style == .tintedMark ? stateColor : pixel
            }
        }
        if style == .framedMark {
            for x in 0..<8 {
                canvas[originX + x, 0] = stateColor
                canvas[originX + x, 7] = stateColor
            }
        }
    }

    /// One solid block per agent, sized to whatever room is left. This is how
    /// a big fleet still reads: you lose *which* agent, but you keep how many
    /// and what state they are in.
    private static func drawBlocks(_ slots: [Slot], into canvas: inout PixelCanvas,
                                   colors: [String: String], width: Int) {
        let slice = max(1, width / slots.count)
        for (index, slot) in slots.enumerated() {
            let color = PixelCanvas.RGB(hex: StatePalette.color(for: slot.state, in: colors))
            let start = index * slice
            // One dark column between blocks, so adjacent same-state agents
            // still read as two.
            for x in start..<min(width, start + slice - 1) {
                for y in 1..<7 { canvas[x, y] = color }
            }
        }
    }
}
