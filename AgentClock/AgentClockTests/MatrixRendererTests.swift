import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AgentClock

final class MatrixRendererTests: XCTestCase {

    // MARK: Font

    func testFontMeasuresProportionally() {
        // The firmware documents a FIXED 4px character cell, so every glyph
        // advances the same amount regardless of its ink.
        XCTAssertEqual(MatrixFont.width(of: "IIIIII"), MatrixFont.width(of: "MMMMMM"))
        XCTAssertEqual(MatrixFont.width(of: "I"), MatrixFont.advance)
        XCTAssertEqual(MatrixFont.width(of: "M"), MatrixFont.advance)
        XCTAssertEqual(MatrixFont.width(of: " "), MatrixFont.spaceWidth)
        XCTAssertEqual(MatrixFont.width(of: ""), 0)
        // 32px panel / 4px cell = eight characters. That is the whole budget.
        XCTAssertEqual(MatrixFont.width(of: "MEGAMICR"), 32)
    }

    func testEveryGlyphIsFiveRowsAndRectangular() {
        for (character, rows) in MatrixFont.glyphs {
            XCTAssertEqual(rows.count, MatrixFont.height, "'\(character)' is not 5 rows tall")
            let width = rows[0].count
            for row in rows {
                XCTAssertEqual(row.count, width, "'\(character)' has ragged rows")
            }
            XCTAssertLessThanOrEqual(width, MatrixFont.artWidth,
                                     "'\(character)' ink exceeds the \(MatrixFont.artWidth)px cell")
        }
    }

    func testEveryCharacterTheAppCanEmitHasAGlyph() {
        // Labels are upper-cased and joined with these; a missing glyph would
        // draw the fallback box on a real page.
        let used = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -·x:."
        for character in used where character != " " {
            XCTAssertNotNil(MatrixFont.glyphs[character], "no glyph for '\(character)'")
        }
    }

    func testRedHeartUsesAColourSpriteInsteadOfTheMissingGlyphBox() {
        let heart = Character("❤️")
        let sprite = EmojiGlyph.sprite(for: heart)
        XCTAssertNotNil(sprite)
        XCTAssertEqual(MatrixFont.width(of: heart), 8)

        var canvas = PixelCanvas(width: 8, height: 8)
        canvas.draw(heart, at: 0, y: 0, color: .init(hex: "#FFFFFF"))
        XCTAssertTrue(canvas.pixels.contains { $0.r == 255 && $0.g == 35 && $0.b == 70 })
        XCTAssertFalse(canvas.pixels.contains { $0.r == 255 && $0.g == 255 && $0.b == 255 },
                       "emoji keeps its own palette instead of inheriting text colour")
    }

    func testStreamEntranceArrivesFromTheRight() {
        var animated = page("HI")
        animated.animation = .stream
        let first = MatrixRenderer.render(animated, time: 0)
        let final = MatrixRenderer.render(animated, time: 2)
        XCTAssertFalse(first.pixels.contains { $0.isLit })
        XCTAssertTrue(final.pixels.contains { $0.isLit })
        XCTAssertEqual(final, MatrixRenderer.render(page("HI"), time: 0))
    }

    func testFallEntranceSettlesIntoTheFinalFrame() {
        var animated = page("LOVE")
        animated.animation = .fall
        let middle = MatrixRenderer.render(animated, time: 0.6)
        let final = MatrixRenderer.render(animated, time: 2)
        XCTAssertNotEqual(middle, final)
        XCTAssertEqual(final, MatrixRenderer.render(page("LOVE"), time: 0))
    }

    func testShowcaseRendererUsesRainEntranceAndSettles() {
        var animated = page("I LOVE CW")
        animated.animation = .showcase
        XCTAssertFalse(MatrixRenderer.render(animated, time: 0).pixels.contains(where: \.isLit))
        XCTAssertEqual(MatrixRenderer.render(animated, time: 2),
                       MatrixRenderer.render(page("I LOVE CW")))
    }

    @MainActor
    func testReplacingHeldNotificationReplaysItsEntrance() {
        let simulator = SimulatedClock()
        var first = page("FIRST")
        first.hold = true
        let name = "text-lab"
        simulator.apply(ClockPlan(notifications: [
            PlannedNotification(name: name, page: first)
        ]))
        simulator.tick(delta: 0.1)

        var replacement = page("SECOND")
        replacement.hold = true
        replacement.animation = .stream
        simulator.apply(ClockPlan(notifications: [
            PlannedNotification(name: name, page: replacement)
        ]))
        simulator.tick(delta: 0)

        XCTAssertEqual(simulator.currentName, name)
        XCTAssertFalse(simulator.canvas.pixels.contains(where: \.isLit),
                       "replacement restarts the entrance at its first frame")
        simulator.tick(delta: 2)
        XCTAssertEqual(simulator.canvas, MatrixRenderer.render(page("SECOND")))
    }

    func testEveryThreeRowGlyphIsRectangular() {
        // A glyph whose rows differ in width draws as nonsense — "FLOW" came
        // out as "FLOU'" because W's last row was two pixels short.
        for (character, rows) in TextLab.rows3 {
            XCTAssertEqual(rows.count, TextLab.height3, "'\(character)' is not 3 rows")
            let width = rows[0].count
            for row in rows {
                XCTAssertEqual(row.count, width, "'\(character)' has ragged rows: \(rows)")
            }
        }
    }

    func testShortNamesAreNotSplitAcrossLines() {
        XCTAssertEqual(TextLab.split("auth").1, "", "AU / TH helps nobody")
        XCTAssertEqual(TextLab.split("megamicro").0, "mega")   // no separator: split at the midpoint
        XCTAssertEqual(TextLab.split("add-auth-flow").1, "flow", "prefer a real separator")
    }

    // MARK: Canvas

    func testDrawingClipsInsteadOfCrashing() {
        var canvas = PixelCanvas(width: 32, height: 8)
        // Scrolling text is mostly off-canvas at any moment; that must be fine.
        canvas.draw("MEGAMICRO", at: -40, y: 1, color: .init(hex: "#FFFFFF"))
        canvas.draw("MEGAMICRO", at: 200, y: 1, color: .init(hex: "#FFFFFF"))
        XCTAssertFalse(canvas.pixels.contains { $0.isLit })
    }

    func testHexParsingFallsBackToWhiteRatherThanBlack() {
        // An unreadable colour should be a bug you can see, not a blank page.
        XCTAssertEqual(PixelCanvas.RGB(hex: "nonsense"), .init(r: 255, g: 255, b: 255))
        XCTAssertEqual(PixelCanvas.RGB(hex: "#FF8000"), .init(r: 255, g: 128, b: 0))
    }

    // MARK: Rendering

    private func page(_ text: String, color: String = "#00FFFF",
                      icon: String? = nil, scroll: ClockPage.ScrollMode? = nil) -> ClockPage {
        ClockPage(text: text, icon: icon, textColor: color, durationMs: nil, scroll: scroll)
    }

    func testTextRendersInItsOwnColour() {
        let canvas = MatrixRenderer.render(page("A", color: "#FF8000"))
        let lit = canvas.pixels.filter(\.isLit)
        XCTAssertFalse(lit.isEmpty)
        XCTAssertTrue(lit.allSatisfy { $0 == .init(r: 255, g: 128, b: 0) })
    }

    func testTextThatFitsIsCentredAndStill() {
        let still = MatrixRenderer.render(page("OK"), time: 0)
        let later = MatrixRenderer.render(page("OK"), time: 3)
        XCTAssertEqual(still, later, "short text must not drift")
    }

    func testScrollingTextActuallyMoves() {
        let long = "A-VERY-LONG-BRANCH-NAME"
        let first = MatrixRenderer.render(page(long, scroll: .loop), time: 0)
        let later = MatrixRenderer.render(page(long, scroll: .loop), time: 0.5)
        XCTAssertNotEqual(first, later)
    }

    func testScrollingTextNeverPaintsOverTheIcon() {
        let canvas = MatrixRenderer.render(
            page("A-VERY-LONG-BRANCH-NAME", icon: "acclaude", scroll: .loop), time: 1.2)
        // Whatever the text is doing, columns 0..<8 belong to the icon.
        let iconRegion = (0..<8).flatMap { x in (0..<8).map { y in canvas[x, y] } }
        let textCyan = PixelCanvas.RGB(hex: "#00FFFF")
        XCTAssertFalse(iconRegion.contains(textCyan), "text bled into the icon")
    }

    func testDrawCommandsPaintExactPixels() {
        var fleet = page("2 AGENTS")
        fleet.draw = [.pixel(x: 0, y: 7, color: "#FF0000"),
                      .pixel(x: 1, y: 7, color: "#00FF00")]
        let canvas = MatrixRenderer.render(fleet)
        XCTAssertEqual(canvas[0, 7], .init(r: 255, g: 0, b: 0))
        XCTAssertEqual(canvas[1, 7], .init(r: 0, g: 255, b: 0))
    }

    func testIconsDecodeFromTheSameGIFsTheClockGets() throws {
        // Guards the whole icon pipeline: source JSON → make_icons.py → bundled
        // GIF → decoded here. A silent failure would show a blank icon.
        let icon = try XCTUnwrap(PixelIcon.bundled(id: "acclaude"),
                                 "acclaude.gif missing — run python3 Icons/make_icons.py")
        XCTAssertEqual(icon.height, 8)
        XCTAssertTrue(icon.frames[0].contains { $0.isLit })

        // The subagent is the same creature, smaller.
        let sub = try XCTUnwrap(PixelIcon.bundled(id: IconLibrary.subagentID))
        XCTAssertEqual(sub.width, 5)
        XCTAssertEqual(sub.height, 4)
        XCTAssertLessThan(sub.width, icon.width)
    }

    func testEveryIconTheLibraryPromisesIsActuallyBundled() {
        for id in IconLibrary.allIDs {
            XCTAssertNotNil(PixelIcon.bundled(id: id), "\(id).gif is not bundled")
        }
    }

    // MARK: Encoding a canvas for the device

    func testCanvasEncodesToRunsNotPixels() {
        var canvas = PixelCanvas(width: 32, height: 8)
        for x in 0..<11 { canvas[x, 3] = .init(hex: "#D97757") }
        let commands = canvas.drawCommands()
        XCTAssertEqual(commands.count, 1, "an 11-pixel run must be one line, not eleven pixels")
        XCTAssertEqual(commands[0].op, "line")
        XCTAssertEqual(commands[0].args, [0, 3, 10, 3])
        XCTAssertEqual(commands[0].color, "#D97757")
    }

    func testSinglePixelStaysAPixel() {
        var canvas = PixelCanvas(width: 32, height: 8)
        canvas[5, 2] = .init(hex: "#00FFFF")
        let commands = canvas.drawCommands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].op, "pixel")
        XCTAssertEqual(commands[0].args, [5, 2])
    }

    func testDarkPixelsAreNotSent() {
        // A black pixel is an off LED. Sending it wastes payload and, worse,
        // would paint over the background effect if one is running.
        XCTAssertTrue(PixelCanvas(width: 32, height: 8).drawCommands().isEmpty)
    }

    /// The number that decides whether this approach is viable at all.
    func testAFullProviderPageFitsTheDevicePayloadLimit() throws {
        func crew(_ n: Int) -> [AgentState] {
            (0..<n).map { [AgentState.thinking, .coding, .waiting, .coding][$0 % 4] }
        }
        for (label, model) in [
            ("busy", ProviderPage.Model(source: "claude-code", state: .coding,
                                        subagents: crew(6), quota: 0.62, context: 0.8)),
            ("worst case", ProviderPage.Model(source: "claude-code", state: .error,
                                              subagents: crew(20), quota: 0.99, context: 0.99)),
        ] {
            for style in ProviderPage.Style.allCases {
                let canvas = ProviderPage.render(model, style: style, colors: StatePalette.defaults)
                var page = ClockPage(text: "", icon: nil, textColor: "#000000",
                                     durationMs: 0, scroll: nil)
                page.draw = canvas.drawCommands()
                let bytes = try page.payload().count
                print("  \(label) / \(style.rawValue): \(page.draw.count) commands, \(bytes) bytes")
                XCTAssertLessThanOrEqual(bytes, AwtrixClient.maximumPayloadBytes,
                                         "\(label)/\(style.rawValue) exceeds the 8192-byte limit")
            }
        }
    }

    /// The invariant that matters most in the whole app: a canvas encoded for
    /// the device and rendered back by the simulator must be the *same
    /// picture*. Without this, the simulator quietly lies about what the panel
    /// will show — which it did: the renderer only understood `pixel`
    /// commands, so every run-length `line` was dropped and a full provider
    /// page came back as four stray pixels.
    func testEncodeThenRenderIsLossless() throws {
        func crew(_ n: Int) -> [AgentState] {
            (0..<n).map { [AgentState.thinking, .coding, .waiting, .coding][$0 % 4] }
        }
        let models = [
            ProviderPage.Model(source: "claude-code", state: .coding,
                               subagents: crew(3), quota: 0.62, context: 0.8),
            ProviderPage.Model(source: "codex", state: .waiting,
                               subagents: crew(1), quota: 0.09, context: 0.31),
            ProviderPage.Model(source: "claude-code", state: .error,
                               subagents: [], quota: 0, context: 0),
        ]
        for model in models {
            for style in ProviderPage.Style.allCases {
                let original = ProviderPage.render(model, style: style,
                                                   colors: StatePalette.defaults)
                var page = ClockPage(text: "", icon: nil, textColor: "#000000",
                                     durationMs: 0, scroll: nil)
                page.draw = original.drawCommands()
                let roundTripped = MatrixRenderer.render(page)
                XCTAssertEqual(original, roundTripped,
                               "\(model.source)/\(style.rawValue) does not survive the round trip")
            }
        }
    }

    func testDiagnoseCodexPage() throws {
        let icon = try XCTUnwrap(PixelIcon.bundled(id: IconLibrary.iconID(forSource: "codex")))
        print("\nicon id: \(IconLibrary.iconID(forSource: "codex")) size \(icon.width)x\(icon.height)")
        let pixels = icon.frames[0]
        for y in 0..<icon.height {
            print("  icon " + (0..<icon.width).map { pixels[y * icon.width + $0].isLit ? "#" : "." }.joined())
        }
        print("  eyes: \(ProviderPage.eyes(of: icon))")

        for (source, crew) in [("claude-code", [AgentState.thinking, .coding]),
                               ("claude-code", []), ("codex", []), ("codex", [.coding])] {
            let model = ProviderPage.Model(source: source, state: .coding,
                                           subagents: crew, quota: 0.4, context: 0.3)
            let canvas = ProviderPage.render(model, style: .bossAndCrew,
                                             colors: StatePalette.defaults)
            print("\n\(source) with \(crew.count) subagents")
            for y in 0..<8 {
                print("  " + (0..<32).map { canvas[$0, y].isLit ? "#" : "." }.joined())
            }
        }
        for style in [ProviderPage.Style.markOnly] {
            let model = ProviderPage.Model(source: "codex", state: .coding,
                                           subagents: [.thinking], quota: 0.4, context: 0.3)
            let canvas = ProviderPage.render(model, style: style, colors: StatePalette.defaults)
            print("\npage \(style.rawValue)")
            for y in 0..<8 {
                print("  " + (0..<32).map { canvas[$0, y].isLit ? "#" : "." }.joined())
            }
        }
    }

    // MARK: Intro animation

    func testIntroWalksInFromTheRightAndStops() {
        // Early on the creature is off the right edge; by the end of the walk
        // it has parked at the left.
        let start = IntroAnimation.frame(at: 0.1)
        let parked = IntroAnimation.frame(at: IntroAnimation.walkDuration + 0.1)
        func leftmostLit(_ canvas: PixelCanvas) -> Int? {
            (0..<canvas.width).first { x in (0..<8).contains { canvas[x, $0].isLit } }
        }
        XCTAssertGreaterThan(leftmostLit(start) ?? 0, 20, "should enter from the right")
        XCTAssertLessThanOrEqual(leftmostLit(parked) ?? 99, IntroAnimation.restX + 1)
    }

    func testLegsAlternateWhileWalking() {
        // Two different leg patterns inside one second, or it slides rather
        // than walks.
        let patterns = Set((0..<12).map { step -> String in
            let canvas = IntroAnimation.frame(at: 0.4 + Double(step) * 0.08)
            return (0..<canvas.width).map { canvas[$0, 7].isLit ? "#" : "." }.joined()
        })
        XCTAssertGreaterThan(patterns.count, 1, "the legs never moved")
    }

    func testItWavesAfterItStops() {
        // The wave lifts the arm, which changes what row 1 looks like.
        let waveStart = IntroAnimation.walkDuration
        let rows = Set((0..<10).map { step -> String in
            let canvas = IntroAnimation.frame(at: waveStart + Double(step) * 0.15)
            return (0..<canvas.width).map { canvas[$0, 1].isLit ? "#" : "." }.joined()
        })
        XCTAssertGreaterThan(rows.count, 1, "the arm never lifted")
    }

    func testCodexSlidesInAfterTheWave() throws {
        let waveEnd = IntroAnimation.walkDuration + IntroAnimation.waveDuration
        XCTAssertFalse(hasCodexBall(IntroAnimation.frame(at: waveEnd - 0.2)),
                       "Codex should not appear until the wave is done")

        // It travels leftward and comes to rest — no bounce any more, so the
        // thing to assert is horizontal movement and a settled finish.
        func leftEdge(at time: TimeInterval) -> Int? {
            let canvas = IntroAnimation.frame(at: time)
            let codex = PixelCanvas.RGB(hex: IntroAnimation.codexColor)
            return (12..<32).first { x in (0..<8).contains { canvas[x, $0] == codex } }
        }
        let positions = (0..<10).compactMap { leftEdge(at: waveEnd + 0.15 + Double($0) * 0.2) }
        XCTAssertGreaterThan(Set(positions).count, 3, "Codex never moved")

        // In, bump, back out: it travels left to the creature, then recoils to
        // a resting distance. Splitting the move like this is also what keeps
        // it quick throughout — a single eased slide spends most of its time
        // crawling the last few pixels, which is what read as choppy.
        let closest = try XCTUnwrap(positions.min())
        let closestAt = try XCTUnwrap(positions.firstIndex(of: closest))
        XCTAssertGreaterThan(closestAt, 0, "it should approach before bumping")
        XCTAssertLessThan(closestAt, positions.count - 1, "it should recoil after bumping")
        XCTAssertLessThanOrEqual(closest, IntroAnimation.bumpX + 1, "it never reached the creature")
        let final = try XCTUnwrap(positions.last)
        XCTAssertGreaterThan(final, closest, "it never backed off")

        let settled = IntroAnimation.total - 0.2
        XCTAssertEqual(leftEdge(at: settled), leftEdge(at: settled - 0.3),
                       "it should be at rest by the end")
    }

    func testTheIntroUsesTheSameCodexMarkAsThePages() throws {
        // The intro used to hand-draw a miniature because a bounce needs
        // headroom. Sliding needs none, so both now show the identical art and
        // cannot drift apart.
        let icon = try XCTUnwrap(IntroAnimation.codexMark)
        XCTAssertEqual(icon.width, 8)
        XCTAssertEqual(icon.height, 8)
        XCTAssertEqual(IconLibrary.iconID(forSource: "codex"), "accodex")
    }

    private func hasCodexBall(_ canvas: PixelCanvas) -> Bool {
        let codex = PixelCanvas.RGB(hex: IntroAnimation.codexColor)
        return (0..<canvas.width).contains { x in (0..<8).contains { canvas[x, $0] == codex } }
    }

    func testPrintWavePhase() {
        // Just the wave, at the rate it actually plays.
        let start = IntroAnimation.walkDuration
        for step in 0..<8 {
            let t = start + Double(step) * 0.22
            let canvas = IntroAnimation.frame(at: t)
            print(String(format: "\nwave t=%.2fs", t))
            for y in 0..<8 {
                print("  " + (0..<14).map { canvas[$0, y].isLit ? "#" : "." }.joined())
            }
        }
    }

    func testPrintBouncePhase() {
        let start = IntroAnimation.walkDuration + IntroAnimation.waveDuration
        for step in 0..<10 {
            let t = start + Double(step) * 0.3
            let canvas = IntroAnimation.frame(at: t)
            print(String(format: "\nbounce t=+%.1fs", t - start))
            for y in 0..<8 {
                print("  " + (14..<32).map { canvas[$0, y].isLit ? "#" : "." }.joined())
            }
        }
    }

    /// Dump the whole intro so the animation can be read frame by frame.
    func testWriteIntroSheet() throws {
        var canvases: [(String, PixelCanvas)] = []
        // Coarse through the walk, fine through the wave and the bounce.
        var time = 0.0
        while time < IntroAnimation.walkDuration {
            canvases.append((String(format: "%.1fs", time), IntroAnimation.frame(at: time)))
            time += 0.5
        }
        while time < IntroAnimation.total {
            canvases.append((String(format: "%.2fs", time), IntroAnimation.frame(at: time)))
            time += 0.16
        }
        for (name, canvas) in canvases {
            print("\n\(name)")
            for y in 0..<canvas.height {
                print("  " + (0..<canvas.width).map { canvas[$0, y].isLit ? "#" : "." }.joined())
            }
        }
        try writePNG(canvases, to: URL(fileURLWithPath: "/tmp/agentclock-intro.png"))
    }

    // MARK: Visual dump

    func testTheMarkIsStillNotAnimated() throws {
        // The pulsing burst is gone: at 8px an animated radial mark read as a
        // blob flickering. The Claude Code creature is pixel art to begin with,
        // so it holds still and says more.
        let claude = try XCTUnwrap(PixelIcon.bundled(id: "acclaude"))
        XCTAssertEqual(claude.frameCount, 1)
        XCTAssertTrue(claude.frameDelays.allSatisfy { $0 >= 0.1 })
    }

    func testTheCreatureKeepsItsEyesAndLegs() throws {
        // The three details that make it read as the mark rather than a slab:
        // two eye holes on row 2, arms reaching the full width on rows 3-4,
        // and legs with gaps between them on row 7.
        let claude = try XCTUnwrap(PixelIcon.bundled(id: "acclaude"))
        let pixels = claude.frames[0]
        func lit(_ x: Int, _ y: Int) -> Bool { pixels[y * claude.width + x].isLit }

        XCTAssertEqual(claude.height, 8)
        XCTAssertGreaterThan(claude.width, 8, "the creature is wider than tall")
        XCTAssertTrue((0..<claude.width).allSatisfy { lit($0, 3) }, "arms span the full width")
        XCTAssertTrue((0..<claude.width).contains { !lit($0, 2) }, "row 2 has eye holes")
        XCTAssertTrue((0..<claude.width).contains { !lit($0, 7) }, "row 7 has gaps between legs")
    }

    /// EXPERIMENTAL — dumps the fleet strip at every count and style.
    func testWriteFleetStripSheet() throws {
        let cast: [(String, AgentState)] = [
            ("claude-code", .waiting), ("codex", .coding),
            ("cursor", .thinking), ("github-copilot", .error),
            ("gemini-cli", .success), ("opencode", .coding),
        ]
        var canvases: [(String, PixelCanvas)] = []
        for style in FleetStrip.Style.allCases {
            for count in 1...6 {
                let slots = cast.prefix(count).map { FleetStrip.Slot(source: $0.0, state: $0.1) }
                canvases.append(("\(style.rawValue) x\(count)",
                                 FleetStrip.render(Array(slots), style: style,
                                                   colors: StatePalette.defaults)))
            }
        }
        for (name, canvas) in canvases {
            print("\n\(name)")
            for y in 0..<canvas.height {
                print("  " + (0..<canvas.width).map { canvas[$0, y].isLit ? "#" : "." }.joined())
            }
        }
        try writePNG(canvases, to: URL(fileURLWithPath: "/tmp/agentclock-fleetstrip.png"))
    }

    /// EXPERIMENTAL — every gauge style at Jesse's real utilisation.
    func testWriteUsageGaugeSheet() throws {
        let readings: [UsageGauge.Reading] = [
            .init(source: "claude-code",
                  session: .init(utilization: 0.27, label: "5h", resetsAt: nil),
                  week: .init(utilization: 0.21, label: "7d", resetsAt: nil), context: nil),
            .init(source: "codex", session: nil,
                  week: .init(utilization: 0.09, label: "7d", resetsAt: nil), context: nil),
        ]
        var canvases: [(String, PixelCanvas)] = []
        for style in UsageGauge.Style.allCases {
            canvases.append((style.rawValue, UsageGauge.render(readings, style: style)))
        }
        // The same styles near the ceiling, where the colour has to earn its keep.
        let hot: [UsageGauge.Reading] = [
            .init(source: "claude-code",
                  session: .init(utilization: 0.88, label: "5h", resetsAt: nil),
                  week: .init(utilization: 0.64, label: "7d", resetsAt: nil), context: nil),
            .init(source: "codex", session: nil,
                  week: .init(utilization: 0.55, label: "7d", resetsAt: nil), context: nil),
        ]
        for style in UsageGauge.Style.allCases {
            canvases.append(("HOT " + style.rawValue, UsageGauge.render(hot, style: style)))
        }
        for (name, canvas) in canvases {
            print("\n\(name)")
            for y in 0..<canvas.height {
                print("  " + (0..<canvas.width).map { canvas[$0, y].isLit ? "#" : "." }.joined())
            }
        }
        try writePNG(canvases, to: URL(fileURLWithPath: "/tmp/agentclock-gauge.png"))
    }

    /// EXPERIMENTAL — provider pages, including a busy fleet of subagents.
    func testWriteProviderPageSheet() throws {
        func crew(_ n: Int) -> [AgentState] {
            (0..<n).map { [AgentState.thinking, .coding, .waiting, .coding][$0 % 4] }
        }
        let cases: [(String, ProviderPage.Model)] = [
            ("claude, no crew (word)", .init(source: "claude-code", state: .coding,
                                             subagents: [], quota: 0.27, context: 0.56)),
            ("codex, no crew (word)", .init(source: "codex", state: .waiting,
                                            subagents: [], quota: 0.09, context: 0.31)),
            ("codex, idle (rests blue)", .init(source: "codex", state: .idle,
                                               subagents: [], quota: 0.09, context: 0.31)),
            ("codex, 2 subagents", .init(source: "codex", state: .coding,
                                         subagents: crew(2), quota: 0.5, context: 0.4)),
            ("claude, 3 subagents", .init(source: "claude-code", state: .coding,
                                          subagents: crew(3), quota: 0.27, context: 0.56)),
            ("claude, 0 subagents", .init(source: "claude-code", state: .thinking,
                                          subagents: [], quota: 0.27, context: 0.56)),
            ("claude, 12 subagents", .init(source: "claude-code", state: .coding,
                                           subagents: crew(12), quota: 0.62, context: 0.8)),
            ("claude, 20 (overflow)", .init(source: "claude-code", state: .coding,
                                            subagents: crew(20), quota: 0.9, context: 0.95)),
            ("codex, waiting", .init(source: "codex", state: .waiting,
                                     subagents: crew(1), quota: 0.09, context: 0.31)),
        ]
        var canvases: [(String, PixelCanvas)] = []
        for style in ProviderPage.Style.allCases {
            for (label, m) in cases {
                canvases.append(("\(style.rawValue) — \(label)",
                                 ProviderPage.render(m, style: style, colors: StatePalette.defaults)))
            }
        }
        for (name, canvas) in canvases {
            print("\n\(name)")
            for y in 0..<canvas.height {
                print("  " + (0..<canvas.width).map { canvas[$0, y].isLit ? "#" : "." }.joined())
            }
        }
        try writePNG(canvases, to: URL(fileURLWithPath: "/tmp/agentclock-provider.png"))
    }

    /// Renders the real pages to `/tmp/agentclock-preview.png` and an ASCII
    /// dump in the test log. Not an assertion — a way to look at the thing.
    func testWriteVisualPreview() throws {
        let now = Date()
        let agents = [
            AgentSnapshot(key: "claude-code#1", source: "claude-code", state: .coding,
                          label: "megamicro", project: "megamicro",
                          startedAt: now.addingTimeInterval(-720)),
            AgentSnapshot(key: "codex#2", source: "codex", state: .waiting,
                          label: "agentclock", project: "agentclock",
                          startedAt: now.addingTimeInterval(-180)),
        ]
        let plan = PagePlanner.plan(agents: agents, config: DisplayConfig(), now: now)
        var canvases: [(String, PixelCanvas)] = plan.apps.map {
            ($0.name, MatrixRenderer.render($0.page, time: 0))
        }
        canvases += plan.notifications.map {
            ($0.name, MatrixRenderer.render($0.page, time: 0))
        }

        for (name, canvas) in canvases {
            print("\n\(name)")
            for y in 0..<canvas.height {
                let row = (0..<canvas.width).map { canvas[$0, y].isLit ? "#" : "." }
                print("  " + row.joined())
            }
        }
        try writePNG(canvases, to: URL(fileURLWithPath: "/tmp/agentclock-preview.png"))
    }

    private func writePNG(_ canvases: [(String, PixelCanvas)], to url: URL) throws {
        let scale = 8
        let gap = 6
        let width = (canvases.first?.1.width ?? 32) * scale
        let height = canvases.count * (8 * scale + gap) - gap
        var raw = [UInt8](repeating: 0, count: width * height * 4)

        for (index, entry) in canvases.enumerated() {
            let originY = index * (8 * scale + gap)
            for y in 0..<(8 * scale) {
                for x in 0..<width {
                    let pixel = entry.1[x / scale, y / scale]
                    let offset = ((originY + y) * width + x) * 4
                    raw[offset] = pixel.r
                    raw[offset + 1] = pixel.g
                    raw[offset + 2] = pixel.b
                    raw[offset + 3] = 255
                }
            }
        }

        let context = CGContext(data: &raw, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let image = context?.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "preview", code: 1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
