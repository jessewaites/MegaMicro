import Foundation

/// EXPERIMENTAL — one page per provider, rotating.
///
/// The premise, and it's the right one: 32×8 cannot hold the whole fleet at
/// once, so stop trying. Give Claude a page and Codex a page and let the device
/// do what it already does natively — rotate between them. Each page then has
/// the whole panel to tell one provider's story, instead of a quarter of it.
///
/// Borrowed from claude-office's framing rather than its code (it reads the
/// same hooks we already do): a main agent with subagents under it reads as a
/// boss and its employees, and context filling up is worth seeing.
///
/// Delete with the other labs once a direction is chosen.
enum ProviderPage {

    struct Model: Equatable {
        let source: String
        /// The main agent's state — drives the mark's colour.
        let state: AgentState
        /// One entry per live subagent, each with its own state.
        let subagents: [AgentState]
        /// Quota used, 0...1.
        let quota: Double
        /// Context window fullness, 0...1.
        let context: Double
    }

    enum Style: String, CaseIterable, Identifiable, Codable, Sendable {
        case bossAndCrew = "Mark + subagent blocks + quota bar"
        case crewOnly = "Mark + subagents, no gauge"
        case gaugesOnly = "Mark + quota and context bars"
        case everything = "Mark + subagents + both gauges"
        /// Just the creature — what an interrupt shows.
        case markOnly = "Mark only"

        var id: String { rawValue }

        var detail: String {
            switch self {
            case .bossAndCrew:
                "The main agent's mark, a block per subagent, and the quota along the bottom. Three facts, three zones."
            case .crewOnly:
                "Just who is working and how many helpers. Biggest, clearest blocks — nothing competing for the pixels."
            case .gaugesOnly:
                "No subagents: quota on top, context underneath. For when the question is \"how much have I got left\"."
            case .everything:
                "All of it. Honest about how crowded 32×8 gets once you ask it for four things at once."
            case .markOnly:
                "The mark alone, eyes carrying the state. What an interrupt puts on the panel."
            }
        }
    }

    /// The mark's width now comes from the art itself: the Claude Code creature
    /// is 11x8, wider than tall, which suits a panel that has width to spare and
    /// no height at all.
    static let gutter = 1

    static func markWidth(for source: String) -> Int {
        PixelIcon.bundled(id: IconLibrary.iconID(forSource: source))?.width ?? 8
    }

    static func render(_ model: Model, style: Style,
                       colors: [String: String], gauge: [String: String] = StatePalette.gaugeDefaults,
                       width: Int = 32, time: TimeInterval = 0) -> PixelCanvas {
        var canvas = PixelCanvas(width: width, height: 8)
        // The mark keeps its brand colour — #D97757 is half of what makes it
        // recognisable, and tinting the whole body threw that away. The state
        // goes in the eyes instead: two pixels, but a colour change inside a
        // face is about the most noticeable thing on a panel this size.
        let stateColor = PixelCanvas.RGB(hex: StatePalette.color(for: model.state, in: colors))
        drawMark(model.source, into: &canvas, state: model.state, tint: stateColor, time: time)

        let x = markWidth(for: model.source) + gutter
        let room = width - x

        switch style {
        case .bossAndCrew:
            if model.subagents.isEmpty {
                // Nothing to show in the crew row, so say who this page is
                // about instead of leaving it blank.
                drawWord(for: model.source, into: &canvas, colors: colors, state: model.state)
            } else {
                drawCrew(model.subagents, into: &canvas, x: x, y: 0, width: room,
                         rows: 1, colors: colors)
            }
            bar(&canvas, value: model.quota, x: x, y: 5, width: room, height: 2, gauge: gauge)

        case .crewOnly:
            drawCrew(model.subagents, into: &canvas, x: x, y: 0, width: room,
                     rows: 2, colors: colors)

        case .gaugesOnly:
            bar(&canvas, value: model.quota, x: x, y: 1, width: room, height: 2, gauge: gauge)
            bar(&canvas, value: model.context, x: x, y: 5, width: room, height: 2,
                gauge: gauge, tint: PixelCanvas.RGB(hex: "#00AAFF"))

        case .everything:
            drawCrew(model.subagents, into: &canvas, x: x, y: 0, width: room,
                     rows: 1, colors: colors)
            bar(&canvas, value: model.quota, x: x, y: 5, width: room, height: 1, gauge: gauge)
            bar(&canvas, value: model.context, x: x, y: 7, width: room, height: 1,
                gauge: gauge, tint: PixelCanvas.RGB(hex: "#00AAFF"))

        case .markOnly:
            break
        }
        return canvas
    }

    /// Draw the mark and let it carry the state.
    ///
    /// How it carries it depends on the art, decided automatically: a mark with
    /// enclosed holes has eyes, so the body keeps its brand colour and only the
    /// eyes change — that is the Claude creature. A mark with no holes has
    /// nothing to tint in isolation, so the whole thing takes the state colour —
    /// that is the Codex prompt. Either way one rule covers both, and adding a
    /// new mark needs no code.
    ///
    /// At idle neither is tinted: the mark rests in its own brand colour.
    private static func drawMark(_ source: String, into canvas: inout PixelCanvas,
                                 state: AgentState, tint: PixelCanvas.RGB,
                                 time: TimeInterval) {
        guard let icon = PixelIcon.bundled(id: IconLibrary.iconID(forSource: source)) else { return }
        let pixels = icon.frame(at: time)
        let sockets = eyes(of: icon)
        let tintWholeMark = sockets.isEmpty && state != .idle

        for y in 0..<icon.height {
            for x in 0..<icon.width where pixels[y * icon.width + x].isLit {
                canvas[x, y] = tintWholeMark ? tint : pixels[y * icon.width + x]
            }
        }
        if state != .idle {
            for (x, y) in sockets { canvas[x, y] = tint }
        }
    }

    /// Find the eyes: unlit pixels enclosed by lit ones on the same row, in the
    /// top half of the mark. Detected rather than hardcoded so the art can be
    /// redrawn without silently moving the state indicator somewhere daft.
    static func eyes(of icon: PixelIcon) -> [(Int, Int)] {
        guard let pixels = icon.frames.first else { return [] }
        var found: [(Int, Int)] = []
        for y in 0..<(icon.height / 2) {
            let row = (0..<icon.width).map { pixels[y * icon.width + $0].isLit }
            guard let first = row.firstIndex(of: true),
                  let last = row.lastIndex(of: true), last > first else { continue }
            for x in (first + 1)..<last where !row[x] { found.append((x, y)) }
        }
        return found
    }

    /// The provider's name, in the space beside the mark's head.
    ///
    /// It starts after the mark's *upper* rows rather than after the whole
    /// mark, which matters: the Claude creature's arms reach full width on rows
    /// 3-4, but rows 0-2 stop at its head. Those two reclaimed columns are
    /// exactly what makes "CLAUDE" fit.
    static func drawWord(for source: String, into canvas: inout PixelCanvas,
                         colors: [String: String], state: AgentState) {
        let word = name(for: source)
        let wordWidth = MicroFont.width(of: word)
        // Floated right rather than tucked against the mark. Left-aligned it
        // crowded everything into the first half of the panel and left the
        // right end empty; pushed right, the mark and the word bracket the
        // page and the space between them is the layout rather than a gap.
        let x = canvas.width - wordWidth
        guard x > headWidth(for: source) else { return }
        // White, not a dimmed state colour: the state is already shouting from
        // the mark's eyes and the bar, and a grey word just looked switched off.
        MicroFont.draw(word, into: &canvas, at: x, y: 0,
                       color: PixelCanvas.RGB(r: 255, g: 255, b: 255))
    }

    static func name(for source: String) -> String {
        switch source {
        case "claude-code", "claude": "CLAUDE"
        case "codex": "CODEX"
        default: String(AppModel.readableSourceName(source).uppercased().prefix(8))
        }
    }

    /// How far the mark reaches across its top three rows — where the word sits.
    static func headWidth(for source: String) -> Int {
        guard let icon = PixelIcon.bundled(id: IconLibrary.iconID(forSource: source)),
              let pixels = icon.frames.first else { return 8 }
        var rightmost = 0
        for y in 0..<min(3, icon.height) {
            for x in 0..<icon.width where pixels[y * icon.width + x].isLit {
                rightmost = max(rightmost, x)
            }
        }
        return rightmost + 1
    }

    /// Stamp the 5x4 creature in a single colour.
    private static func drawCreature(at x: Int, y: Int, tint: PixelCanvas.RGB,
                                     into canvas: inout PixelCanvas) {
        guard let icon = PixelIcon.bundled(id: IconLibrary.subagentID),
              let pixels = icon.frames.first else { return }
        for iy in 0..<icon.height {
            for ix in 0..<icon.width where pixels[iy * icon.width + ix].isLit {
                canvas[x + ix, y + iy] = tint
            }
        }
    }

    /// One block per subagent, each in its own state colour — claude-office's
    /// employees, reduced to what 23 pixels can hold. Overflow is shown as a
    /// dim block rather than dropped silently, so "more than fits" is visible.
    private static func drawCrew(_ subagents: [AgentState], into canvas: inout PixelCanvas,
                                 x: Int, y: Int, width: Int, rows: Int,
                                 colors: [String: String]) {
        guard !subagents.isEmpty else { return }
        let creatureWidth = PixelIcon.bundled(id: IconLibrary.subagentID)?.width ?? 5
        let creatureHeight = PixelIcon.bundled(id: IconLibrary.subagentID)?.height ?? 4
        let stride = creatureWidth + 1
        let perRow = max(1, (width + 1) / stride)
        let capacity = perRow * rows

        for (index, state) in subagents.prefix(capacity).enumerated() {
            let row = index / perRow
            let column = index % perRow
            drawCreature(at: x + column * stride, y: y + row * creatureHeight,
                         tint: PixelCanvas.RGB(hex: StatePalette.color(for: state, in: colors)),
                         into: &canvas)
        }
        if subagents.count > capacity {
            // The last one goes dim to say "and more" — dropping them silently
            // would read as a smaller fleet than you actually have.
            let column = (capacity - 1) % perRow
            let row = (capacity - 1) / perRow
            drawCreature(at: x + column * stride, y: y + row * creatureHeight,
                         tint: PixelCanvas.RGB(r: 80, g: 80, b: 80), into: &canvas)
        }
    }

    private static func bar(_ canvas: inout PixelCanvas, value: Double,
                            x: Int, y: Int, width: Int, height: Int,
                            gauge: [String: String] = StatePalette.gaugeDefaults,
                            tint: PixelCanvas.RGB? = nil) {
        let clamped = max(0, min(1, value))
        let filled = Int((Double(width) * clamped).rounded())
        let color = tint ?? PixelCanvas.RGB(hex: StatePalette.gaugeColor(for: clamped, in: gauge))
        // Bright enough to read as an empty gauge. At 22 it was
        // indistinguishable from an unlit pixel, so a page with no quota
        // looked like a page that had failed to draw.
        let track = PixelCanvas.RGB(r: 60, g: 60, b: 60)
        for column in 0..<width {
            for row in y..<(y + height) {
                canvas[x + column, row] = column < filled ? color : track
            }
        }
    }
}
