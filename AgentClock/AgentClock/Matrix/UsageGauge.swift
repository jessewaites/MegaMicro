import Foundation

/// EXPERIMENTAL — the panel as a usage meter.
///
/// This is what 32×8 is actually good at. A bar needs no font, no truncation
/// and no 8-pixel logo: the three things that defeated every text and mark
/// layout we tried. It carries one number, and you read it from across the
/// room without focusing.
///
/// Delete alongside `TextLab` / `FleetStrip` once a direction is chosen.
enum UsageGauge {

    /// One quota window, from either provider.
    struct Window: Equatable {
        /// 0...1.
        let utilization: Double
        /// "5h", "7d" — what the window is.
        let label: String
        let resetsAt: Date?
    }

    struct Reading: Equatable {
        let source: String          // "claude-code" / "codex"
        let session: Window?        // the short window; Codex often has none
        let week: Window?
        /// Current context fullness of the busiest live session, 0...1.
        let context: Double?
    }

    enum Style: String, CaseIterable, Identifiable {
        case singleBar = "One bar — the window closest to running out"
        case dualBar = "Two bars — session on top, week below"
        case perProvider = "One row per provider, with its mark"
        case segmented = "Segmented, like a VU meter"
        case markAndBar = "Mark on the left, bar filling the rest"

        var id: String { rawValue }

        var detail: String {
            switch self {
            case .singleBar:
                "The simplest thing that answers the question. Whichever window is furthest along wins the panel."
            case .dualBar:
                "Both horizons at once — the five-hour burst and the weekly budget behave very differently."
            case .perProvider:
                "Claude and Codex side by side, each with its own mark and bar. Answers \"which one am I burning\"."
            case .segmented:
                "Discrete blocks rather than a smooth fill, so you can count rather than estimate."
            case .markAndBar:
                "Keeps this morning's mark, but the bar carries a number instead of a state."
            }
        }
    }

    /// Green while there's plenty, amber as it tightens, red near the ceiling.
    /// Thresholds rather than a gradient: the point is to be readable at a
    /// glance, and a continuous hue ramp reads as "some colour" at 8 pixels.
    static func color(for utilization: Double) -> PixelCanvas.RGB {
        switch utilization {
        case ..<0.5: PixelCanvas.RGB(hex: "#02FF00")
        case ..<0.8: PixelCanvas.RGB(hex: "#FFEF00")
        default: PixelCanvas.RGB(hex: "#FF0000")
        }
    }

    static func render(_ readings: [Reading], style: Style,
                       width: Int = 32, time: TimeInterval = 0) -> PixelCanvas {
        var canvas = PixelCanvas(width: width, height: 8)
        guard !readings.isEmpty else { return canvas }

        switch style {
        case .singleBar:
            let worst = readings.compactMap { [$0.session, $0.week].compactMap { $0 } }
                .flatMap { $0 }
                .max { $0.utilization < $1.utilization }
            if let worst {
                bar(&canvas, utilization: worst.utilization, x: 0, y: 2, width: width, height: 4)
            }

        case .dualBar:
            let session = readings.compactMap(\.session).max { $0.utilization < $1.utilization }
            let week = readings.compactMap(\.week).max { $0.utilization < $1.utilization }
            if let session { bar(&canvas, utilization: session.utilization, x: 0, y: 1, width: width, height: 2) }
            if let week { bar(&canvas, utilization: week.utilization, x: 0, y: 5, width: width, height: 2) }

        case .perProvider:
            // A three-row slot is too short for a mark — downsampling one just
            // produces a dash. A solid block of the provider's brand colour
            // identifies the row in three pixels and stays legible.
            let rows = min(readings.count, 2)
            for (index, reading) in readings.prefix(rows).enumerated() {
                let y = index * 4
                let brand = brandColor(for: reading.source)
                for x in 0..<3 {
                    for row in y..<(y + 3) { canvas[x, row] = brand }
                }
                let value = reading.session?.utilization ?? reading.week?.utilization ?? 0
                bar(&canvas, utilization: value, x: 5, y: y, width: width - 5, height: 3)
            }

        case .segmented:
            let worst = readings.compactMap { [$0.session, $0.week].compactMap { $0 } }
                .flatMap { $0 }
                .max { $0.utilization < $1.utilization }
            guard let worst else { break }
            // 16 blocks of two pixels, one dark column between.
            let blocks = 16
            let lit = Int((worst.utilization * Double(blocks)).rounded())
            let color = color(for: worst.utilization)
            for index in 0..<blocks where index < lit {
                for y in 2..<6 { canvas[index * 2, y] = color }
            }

        case .markAndBar:
            let reading = readings[0]
            mark(&canvas, source: reading.source, x: 0, y: 0, height: 8, time: time)
            let value = reading.session?.utilization ?? reading.week?.utilization ?? 0
            bar(&canvas, utilization: value, x: 9, y: 2, width: width - 9, height: 4)
        }
        return canvas
    }

    /// The provider's own colour, for rows too short to carry its mark. Taken
    /// from the icon art so the tag and the logo can never drift apart.
    static func brandColor(for source: String) -> PixelCanvas.RGB {
        guard let icon = PixelIcon.bundled(id: IconLibrary.iconID(forSource: source)),
              let lit = icon.frames.first?.first(where: { $0.isLit }) else {
            return PixelCanvas.RGB(r: 200, g: 200, b: 200)
        }
        return lit
    }

    /// A filled bar with its unfilled remainder shown dim, so the *scale* is
    /// visible. A bare fill with nothing behind it reads as "a short bar",
    /// which is ambiguous between 20% used and a 20%-wide gauge.
    private static func bar(_ canvas: inout PixelCanvas, utilization: Double,
                            x: Int, y: Int, width: Int, height: Int) {
        let clamped = max(0, min(1, utilization))
        let filled = Int((Double(width) * clamped).rounded())
        let color = color(for: clamped)
        let track = PixelCanvas.RGB(r: 60, g: 60, b: 60)
        for column in 0..<width {
            for row in y..<(y + height) {
                canvas[x + column, row] = column < filled ? color : track
            }
        }
    }

    private static func mark(_ canvas: inout PixelCanvas, source: String,
                             x: Int, y: Int, height: Int, time: TimeInterval) {
        guard let icon = PixelIcon.bundled(id: IconLibrary.iconID(forSource: source)) else { return }
        let pixels = icon.frame(at: time)
        if height >= 8 {
            for iy in 0..<icon.height {
                for ix in 0..<icon.width where pixels[iy * icon.width + ix].isLit {
                    canvas[x + ix, y + iy] = pixels[iy * icon.width + ix]
                }
            }
        } else {
            // Too short for the mark: downsample it to `height` rows so the
            // provider is still identifiable in a per-provider row.
            for iy in 0..<height {
                for ix in 0..<icon.width {
                    let sourceY0 = iy * icon.height / height
                    let sourceY1 = max(sourceY0 + 1, (iy + 1) * icon.height / height)
                    var lit: PixelCanvas.RGB?
                    for sy in sourceY0..<sourceY1 {
                        let pixel = pixels[sy * icon.width + ix]
                        if pixel.isLit { lit = pixel; break }
                    }
                    if let lit { canvas[x + ix, y + iy] = lit }
                }
            }
        }
    }
}
