import SwiftUI

/// The panel, on screen. Drawn as discrete rounded LEDs on a black field with
/// a faint bloom, because that is what the real thing looks like through its
/// diffuser — and because a smooth bitmap would flatter artwork that reads
/// badly in the flesh. Unlit pixels stay faintly visible for the same reason:
/// on the hardware you can see the whole grid.
struct MatrixView: View {
    let canvas: PixelCanvas
    /// Side of one LED in points.
    var pixelSize: CGFloat = 10
    var showsBezel: Bool = true

    private var gap: CGFloat { max(1, pixelSize * 0.14) }
    private var matrixWidth: CGFloat { CGFloat(canvas.width) * pixelSize }
    private var matrixHeight: CGFloat { CGFloat(canvas.height) * pixelSize }

    var body: some View {
        Canvas { context, _ in
            for y in 0..<canvas.height {
                for x in 0..<canvas.width {
                    let pixel = canvas[x, y]
                    let rect = CGRect(
                        x: CGFloat(x) * pixelSize + gap / 2,
                        y: CGFloat(y) * pixelSize + gap / 2,
                        width: pixelSize - gap,
                        height: pixelSize - gap)
                    let shape = Path(roundedRect: rect, cornerRadius: (pixelSize - gap) * 0.18)

                    guard pixel.isLit else {
                        // The dark grid, just visible — same as the real panel.
                        context.fill(shape, with: .color(.white.opacity(0.045)))
                        continue
                    }
                    let color = Color(.sRGB,
                                      red: Double(pixel.r) / 255,
                                      green: Double(pixel.g) / 255,
                                      blue: Double(pixel.b) / 255)
                    // Bloom first, then the LED over it.
                    context.fill(
                        Path(roundedRect: rect.insetBy(dx: -pixelSize * 0.22,
                                                       dy: -pixelSize * 0.22),
                             cornerRadius: pixelSize * 0.4),
                        with: .color(color.opacity(0.22)))
                    context.fill(shape, with: .color(color))
                }
            }
        }
        .frame(width: matrixWidth, height: matrixHeight)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: showsBezel ? 3 : 0))
        .padding(showsBezel ? pixelSize * 0.5 : 0)
        .background {
            if showsBezel {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.black)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
            }
        }
    }
}

/// The simulator with its caption: which page is showing, and whether the panel
/// would be dark right now.
struct SimulatedClockView: View {
    @Environment(AppModel.self) private var model
    var pixelSize: CGFloat = 10
    var showsCaption: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MatrixView(canvas: model.simulator.canvas, pixelSize: pixelSize)
            if showsCaption { caption }
        }
    }

    private var caption: some View {
        HStack(spacing: 6) {
            if model.simulator.isIdle {
                Image(systemName: "moon.zzz")
                Text("Panel idle — the clock shows its own apps")
            } else {
                Image(systemName: model.simulator.isShowingNotification
                      ? "exclamationmark.bubble.fill" : "rectangle.on.rectangle")
                Text(model.simulator.currentName)
                if model.simulator.isShowingNotification {
                    Text("· interrupt").foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isDemoRunning {
                Label("Demo", systemImage: "play.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
