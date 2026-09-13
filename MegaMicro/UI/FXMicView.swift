import SwiftUI

/// Reconstruction of the Teenage Engineering EP-2350 FX-MIC, drawn the way
/// `KeyboardView` draws the Codex Micro: pure SwiftUI shapes, no bitmap. The
/// product render in `Assets/` is reference only.
///
/// The device can't report anything, so everything that moves here is inferred
/// from the audio stream: the grille lights from the bottom with the input
/// level, the strips show which cue bank and slot last fired, and the handle
/// leans in while there's voice. That makes the drawing the diagnostic — you can
/// see the mic working without reading a log.
struct FXMicView: View {
    /// Smoothed input level, 0…1. Kept for the clip flag; the grille itself
    /// stays dark like the real one.
    var level: Double = 0
    /// Peak hit full scale — the signal is too hot for the input.
    var clipping: Bool = false
    /// How many of the four red page LEDs are lit: 0 on the clean page, then
    /// one more per FX2 press, exactly as the mic shows it.
    var pageLevel: Int = 0
    /// Which of the four white sample LEDs is lit (0–3), or none.
    var lastSlot: Int?
    /// True while voice is being captured — the handle leans in.
    var voiceActive: Bool = false
    /// Which side buttons are physically down right now (FX2, FX3, FX4).
    var fxPressed = false
    var selectPressed = false
    var playPressed = false
    /// Draw FX1–FX4 beside the device, in the drawing's own coordinates so
    /// they can never sit next to the wrong control. The caller reserves
    /// `calloutWidth` of horizontal room on each side.
    var showCallouts = false
    static let calloutWidth: CGFloat = 60

    // Proportions measured off the product render, as fractions of the whole
    // art box — which includes the handle, the protruding buttons and the
    // cable, not just the body. Deliberately not dimmed when disconnected: the
    // device is white and light grey, and fading it over a dark window turns
    // the whole thing muddy grey. Connection state belongs in a label.
    /// Width ÷ height of the whole art box.
    ///
    /// The view deliberately does **not** apply its own `.aspectRatio` — it
    /// fills whatever frame it's given. Sizing from both ends (an internal
    /// aspect ratio *and* a caller's frame) is what made the drawing overhang
    /// its own layout height, putting the cable on top of the caption beneath
    /// it. Callers set one dimension and derive the other from this.
    static let aspect: CGFloat = 645.0 / 955.0

    private enum P {

        static let bodyX: CGFloat = 0.175, bodyW: CGFloat = 0.752
        static let bodyH: CGFloat = 0.796
        static let grilleH: CGFloat = 0.435          // grille ends / faceplate starts

        static let handleW: CGFloat = 0.175
        static let handleTop: CGFloat = 0.120, handleBottom: CGFloat = 0.571

        static let buttonLeft: CGFloat = 0.927       // flush with the body edge
        static let presetTop: CGFloat = 0.094, presetBottom: CGFloat = 0.178
        static let presetRight: CGFloat = 1.0
        static let slotTop: CGFloat = 0.267, slotBottom: CGFloat = 0.330
        static let slotRight: CGFloat = 0.988
        static let triggerTop: CGFloat = 0.571, triggerBottom: CGFloat = 0.649
        static let triggerRight: CGFloat = 0.994

        static let stripLeft: CGFloat = 0.783, stripRight: CGFloat = 0.845
        static let stripATop: CGFloat = 0.063, stripABottom: CGFloat = 0.199
        static let stripBTop: CGFloat = 0.236, stripBBottom: CGFloat = 0.372

        static let screwX: (CGFloat, CGFloat) = (0.225, 0.857)
        static let screwY: (CGFloat, CGFloat) = (0.464, 0.761)

        /// The cable leaves left of body centre on the real device.
        static let cableCenter: CGFloat = 0.375
    }

    private static let orange = Color(red: 0.90, green: 0.36, blue: 0.16)
    /// Holes across and down the grille, counted off the render.
    private static let holeColumns = 15
    private static let holeRows = 14
    /// LEDs per strip: four red for the page, four white for the sample.
    private static let stripDots = 4

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                handle(w: w, h: h)
                cable(w: w, h: h)
                sideButtons(w: w, h: h)
                bodyShell(w: w, h: h)
                if showCallouts { calloutLabels(w: w, h: h) }
            }
            .frame(width: w, height: h)
        }
    }

    // MARK: Body — grille over faceplate

    private func bodyShell(w: CGFloat, h: CGFloat) -> some View {
        let bw = P.bodyW * w
        let bh = P.bodyH * h
        let grilleH = P.grilleH * h
        let radius = bw * 0.035

        return VStack(spacing: 0) {
            grille(width: bw, height: grilleH)
            faceplateView(width: bw, height: bh - grilleH)
        }
        .frame(width: bw, height: bh)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        .offset(x: P.bodyX * w, y: 0)
    }

    /// The perforated grille, plus the level meter that lights it from the
    /// bottom. Drawn in a single `Canvas` — ~200 holes as individual `Circle`
    /// views would be the one place the app's view-per-element idiom stops
    /// paying for itself.
    private func grille(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.62), Color(white: 0.52)],
                           startPoint: .top, endPoint: .bottom)

            Canvas { context, size in
                let insetX = size.width * 0.045
                let insetY = size.height * 0.035
                let stepX = (size.width - insetX * 2) / CGFloat(Self.holeColumns)
                let stepY = (size.height - insetY * 2) / CGFloat(Self.holeRows)
                // Holes nearly touch on the real grille — the webbing between
                // them is thin, which is what makes it read as drilled metal
                // rather than a polka dot.
                let radius = min(stepX, stepY) * 0.43

                // The real grille never lights; `level` is shown by the caller
                // as a bar under the drawing, not painted onto the mic.
                let litRows = 0.0

                for row in 0..<Self.holeRows {
                    let fromBottom = Self.holeRows - 1 - row
                    // Fractional fill lands on the boundary row, so the meter
                    // slides rather than stepping.
                    let fill = max(0, min(1, litRows - Double(fromBottom)))
                    for column in 0..<Self.holeColumns {
                        let center = CGPoint(
                            x: insetX + stepX * (CGFloat(column) + 0.5),
                            y: insetY + stepY * (CGFloat(row) + 0.5))
                        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2)

                        // Bevel: a bright arc on the lower-right lip and a dark
                        // one up top, so each hole reads as punched through.
                        context.stroke(Path(ellipseIn: rect.insetBy(dx: -1.1, dy: -1.1)),
                                       with: .color(Color.white.opacity(0.34)), lineWidth: 1.6)
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .radialGradient(
                                Gradient(colors: [Color(white: 0.05), Color(white: 0.22)]),
                                center: CGPoint(x: center.x + radius * 0.25,
                                                y: center.y + radius * 0.3),
                                startRadius: 0, endRadius: radius * 1.5))

                        if fill > 0.01 {
                            let color = meterColor(fromBottom: fromBottom)
                            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(fill * 0.92)))
                            context.fill(Path(ellipseIn: rect.insetBy(dx: -radius * 0.55, dy: -radius * 0.55)),
                                         with: .color(color.opacity(fill * 0.22)))
                        }
                    }
                }
            }
            .animation(.easeOut(duration: 0.06), value: level)

            ledStrips(width: width, height: height)
        }
        .frame(width: width, height: height)
    }

    /// Green through the working range, amber near the top, red once the input
    /// is actually clipping — the conventional meter reading, which is what
    /// makes it usable for setting the mic's `level` against a hot input.
    private func meterColor(fromBottom row: Int) -> Color {
        if clipping && row >= Self.holeRows - 2 { return Color(red: 0.95, green: 0.24, blue: 0.2) }
        if row >= Self.holeRows - 3 { return Color(red: 0.98, green: 0.72, blue: 0.16) }
        return Color(red: 0.31, green: 0.84, blue: 0.42)
    }

    /// The two recessed LED strips on the grille. Upper: four red, a bar graph
    /// of the page (none lit on clean, all four on the last page). Lower: four
    /// white, one lit for the selected sample slot.
    private func ledStrips(width: CGFloat, height: CGFloat) -> some View {
        // Strip fractions are of the whole art box; convert to grille-local.
        let x = (P.stripLeft - P.bodyX) / P.bodyW * width
        let stripW = (P.stripRight - P.stripLeft) / P.bodyW * width
        let aTop = P.stripATop / P.grilleH * height
        let aH = (P.stripABottom - P.stripATop) / P.grilleH * height
        let bTop = P.stripBTop / P.grilleH * height
        let bH = (P.stripBBottom - P.stripBTop) / P.grilleH * height

        let level = max(0, min(Self.stripDots, pageLevel))
        return ZStack(alignment: .topLeading) {
            strip(width: stripW, height: aH,
                  lit: { $0 < level },
                  on: Color(red: 1.0, green: 0.25, blue: 0.2), glow: .red)
                .offset(x: x, y: aTop)
            strip(width: stripW, height: bH,
                  lit: { $0 == lastSlot },
                  on: Color(white: 0.98), glow: .white)
                .offset(x: x, y: bTop)
        }
    }

    private func strip(width: CGFloat, height: CGFloat,
                       lit: @escaping (Int) -> Bool, on: Color, glow: Color) -> some View {
        let dot = min(width * 0.36, height / CGFloat(Self.stripDots + 3))
        return VStack(spacing: 0) {
            ForEach(0..<Self.stripDots, id: \.self) { index in
                Circle()
                    .fill(lit(index) ? on : Color(white: 0.34))
                    .frame(width: dot, height: dot)
                    .shadow(color: lit(index) ? glow.opacity(0.9) : .clear, radius: dot)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: width, height: height)
        .background(
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.80), Color(white: 0.62)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.22), lineWidth: 0.9))
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1))
        .animation(.easeOut(duration: 0.1), value: lastSlot)
        .animation(.easeOut(duration: 0.1), value: pageLevel)
    }

    /// Brushed aluminium plate: the wordmark and four recessed screws.
    private func faceplateView(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.985), Color(white: 0.92)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            // Fine vertical striations — what makes it read as brushed metal
            // rather than painted plastic.
            Canvas { context, size in
                var x: CGFloat = 0
                var seed = 0
                while x < size.width {
                    seed += 1
                    let alpha = (seed % 3 == 0) ? 0.045 : 0.02
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(Color.black.opacity(alpha)), lineWidth: 0.7)
                    x += 2.5
                }
            }

            wordmark(width: width, height: height)
            screws(width: width, height: height)
        }
        .frame(width: width, height: height)
    }

    private func wordmark(width: CGFloat, height: CGFloat) -> some View {
        let size = width * 0.155
        return HStack(alignment: .firstTextBaseline, spacing: size * 0.18) {
            Text("MIC")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(Color.black.opacity(0.88))
            Text("FX")
                .font(.system(size: size * 0.62, weight: .regular))
                .foregroundStyle(Self.orange)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .padding(.leading, width * 0.128)
        .padding(.top, height * 0.155)
    }

    private func screws(width: CGFloat, height: CGFloat) -> some View {
        let d = width * 0.052
        // Screw fractions are of the whole art box; convert to plate-local.
        let xs = [(P.screwX.0 - P.bodyX) / P.bodyW * width,
                  (P.screwX.1 - P.bodyX) / P.bodyW * width]
        let plateH = P.bodyH - P.grilleH
        let ys = [(P.screwY.0 - P.grilleH) / plateH * height,
                  (P.screwY.1 - P.grilleH) / plateH * height]

        return ZStack(alignment: .topLeading) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.90), Color(white: 0.97)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.9))
                    .frame(width: d, height: d)
                    .offset(x: xs[index % 2] - d / 2, y: ys[index / 2] - d / 2)
            }
        }
    }

    // MARK: Handle

    /// The orange lever. On the real mic, squeezing it powers the capsule — so
    /// it leans in whenever there's voice, which is the closest thing to a
    /// "handle pressed" signal we can ever have.
    private func handle(w: CGFloat, h: CGFloat) -> some View {
        let width = P.handleW * w
        let top = P.handleTop * h
        let height = (P.handleBottom - P.handleTop) * h

        return Path { path in
            // A scythe: a near-flat top edge, a long belly bulging out to the
            // left, tapering to a point at the bottom.
            path.move(to: CGPoint(x: width, y: 0))
            path.addLine(to: CGPoint(x: width * 0.30, y: height * 0.02))
            path.addCurve(to: CGPoint(x: width * 0.02, y: height * 0.28),
                          control1: CGPoint(x: width * 0.14, y: height * 0.06),
                          control2: CGPoint(x: width * 0.03, y: height * 0.15))
            path.addCurve(to: CGPoint(x: width * 0.86, y: height),
                          control1: CGPoint(x: width * 0.01, y: height * 0.66),
                          control2: CGPoint(x: width * 0.52, y: height * 0.93))
            path.addLine(to: CGPoint(x: width, y: height))
            path.closeSubpath()
        }
        .fill(LinearGradient(colors: [Self.orange, Self.orange.opacity(0.86)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.25), radius: 5, x: -2, y: 3)
        .rotationEffect(.degrees(voiceActive ? 2.4 : 0), anchor: .bottomTrailing)
        .offset(x: 0, y: top)
        .animation(.easeOut(duration: 0.1), value: voiceActive)
    }

    // MARK: Side buttons

    /// FX1 at the handle's midpoint on the left; FX2–FX4 at each side
    /// button's midpoint on the right, with a leader out to the label. Same
    /// `P` fractions as the shapes, so the label is level with the control by
    /// construction.
    private func calloutLabels(w: CGFloat, h: CGFloat) -> some View {
        let gap: CGFloat = 8
        let leader: CGFloat = 14
        func label(_ text: String, active: Bool, y: CGFloat, left: Bool) -> some View {
            HStack(spacing: 4) {
                if left { Text(text) }
                Rectangle()
                    .fill(active ? Color.green : Color.secondary.opacity(0.6))
                    .frame(width: leader, height: 1)
                if !left { Text(text) }
            }
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(active ? Color.green : Color.secondary)
            .frame(width: Self.calloutWidth, height: 18, alignment: left ? .trailing : .leading)
            .position(x: left ? -(gap + Self.calloutWidth / 2) : w + gap + Self.calloutWidth / 2,
                      y: y * h)
            .animation(.easeOut(duration: 0.12), value: active)
        }
        return ZStack(alignment: .topLeading) {
            label(FXMicControlName.handle, active: voiceActive,
                  y: (P.handleTop + P.handleBottom) / 2, left: true)
            label(FXMicControlName.fxButton, active: fxPressed,
                  y: (P.presetTop + P.presetBottom) / 2, left: false)
            label(FXMicControlName.middleButton, active: selectPressed,
                  y: (P.slotTop + P.slotBottom) / 2, left: false)
            label(FXMicControlName.bottomButton, active: playPressed,
                  y: (P.triggerTop + P.triggerBottom) / 2, left: false)
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Indicators, not controls: they depress while the real button is held.
    private func sideButtons(w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            sideButton(w: w, h: h, right: P.presetRight,
                       top: P.presetTop, bottom: P.presetBottom,
                       color: Self.orange, active: fxPressed)
            sideButton(w: w, h: h, right: P.slotRight,
                       top: P.slotTop, bottom: P.slotBottom,
                       color: Color(white: 0.82), active: selectPressed)
            sideButton(w: w, h: h, right: P.triggerRight,
                       top: P.triggerTop, bottom: P.triggerBottom,
                       color: Color(white: 0.78), active: playPressed)
        }
    }

    private func sideButton(w: CGFloat, h: CGFloat, right: CGFloat,
                            top: CGFloat, bottom: CGFloat,
                            color: Color, active: Bool) -> some View {
        let width = (right - P.buttonLeft) * w
        let height = (bottom - top) * h
        return RoundedRectangle(cornerRadius: min(width, height) * 0.42)
            .fill(LinearGradient(colors: [color, color.opacity(0.78)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: min(width, height) * 0.42)
                .strokeBorder(Color.black.opacity(0.14), lineWidth: 0.8))
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.28), radius: 3, x: 2, y: 2)
            // Pushed in when the cue it produces has just fired.
            .offset(x: P.buttonLeft * w - (active ? width * 0.18 : 0), y: top * h)
            .animation(.easeOut(duration: 0.08), value: active)
    }

    // MARK: Cable

    private func cable(w: CGFloat, h: CGFloat) -> some View {
        let bodyBottom = P.bodyH * h
        let reliefW = w * 0.10
        let reliefH = (h - bodyBottom) * 0.62
        let centerX = P.cableCenter * w
        let ridges = 7

        return ZStack(alignment: .topLeading) {
            // Strain relief: a stack of washers, each a touch narrower than the
            // last, tapering away from the body.
            VStack(spacing: reliefH / CGFloat(ridges) * 0.22) {
                ForEach(0..<ridges, id: \.self) { index in
                    Capsule()
                        .fill(LinearGradient(colors: [Color(white: 0.88), Color(white: 0.70)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: reliefW * (1 - CGFloat(index) * 0.055),
                               height: reliefH / CGFloat(ridges) * 0.72)
                }
            }
            .frame(width: reliefW, alignment: .center)
            .offset(x: centerX - reliefW / 2, y: bodyBottom)

            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.93), Color(white: 0.80)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: reliefW * 0.34, height: h - bodyBottom - reliefH)
                .offset(x: centerX - reliefW * 0.17, y: bodyBottom + reliefH)
        }
    }
}
