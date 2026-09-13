import SwiftUI

/// EXPERIMENTAL — every gauge style at once, driven by sliders so each one can
/// be judged full and empty rather than at a single flattering value.
/// Delete with `UsageGauge`.
struct UsageLabPane: View {
    @State private var claudeSession = 0.27   // your real 5h utilisation
    @State private var claudeWeek = 0.21      // your real 7d utilisation
    @State private var codexWeek = 0.09       // Codex, straight off disk
    @State private var time: TimeInterval = 0

    private let tick = Timer.publish(every: 1.0 / 20, on: .main, in: .common).autoconnect()

    private var readings: [UsageGauge.Reading] {
        [
            .init(source: "claude-code",
                  session: .init(utilization: claudeSession, label: "5h", resetsAt: nil),
                  week: .init(utilization: claudeWeek, label: "7d", resetsAt: nil),
                  context: nil),
            .init(source: "codex",
                  session: nil,
                  week: .init(utilization: codexWeek, label: "7d", resetsAt: nil),
                  context: nil),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                sliders
                ForEach(UsageGauge.Style.allCases) { style in
                    panel(style)
                }
                thresholds
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
        .onReceive(tick) { _ in time += 1.0 / 20 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Usage gauge").font(.title2.bold())
            Text("A bar needs no font, no truncation and no 8-pixel logo — the three things that defeated every text and mark layout. Sliders start at your real numbers.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sliders: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            row("Claude 5-hour", $claudeSession)
            row("Claude 7-day", $claudeWeek)
            row("Codex 7-day", $codexWeek)
        }
        .frame(maxWidth: 460)
    }

    private func row(_ label: String, _ value: Binding<Double>) -> some View {
        GridRow {
            Text(label).font(.callout).frame(width: 110, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text("\(Int(value.wrappedValue * 100))%")
                .font(.callout.monospacedDigit()).frame(width: 44, alignment: .trailing)
        }
    }

    private func panel(_ style: UsageGauge.Style) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(style.rawValue).font(.headline)
            MatrixView(canvas: UsageGauge.render(readings, style: style, time: time),
                       pixelSize: 15)
            Text(style.detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var thresholds: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("How the colour behaves").font(.headline)
            ForEach([0.1, 0.45, 0.6, 0.79, 0.85, 0.97], id: \.self) { value in
                HStack(spacing: 10) {
                    Text("\(Int(value * 100))%")
                        .font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
                    MatrixView(canvas: UsageGauge.render(
                        [.init(source: "claude-code",
                               session: .init(utilization: value, label: "5h", resetsAt: nil),
                               week: nil, context: nil)],
                        style: .singleBar), pixelSize: 7, showsBezel: false)
                }
            }
            Text("Green under 50%, amber to 80%, red above. Thresholds rather than a gradient — a continuous hue ramp just reads as \"some colour\" at this size.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}
