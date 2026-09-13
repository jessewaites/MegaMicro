import SwiftUI

/// EXPERIMENTAL — the panel divided by agent instead of filled with text.
/// Delete with `FleetStrip` once a direction is settled.
struct FleetLabPane: View {
    @Environment(AppModel.self) private var model

    @State private var slots: [FleetStrip.Slot] = [
        .init(source: "claude-code", state: .coding),
        .init(source: "codex", state: .waiting),
    ]
    @State private var time: TimeInterval = 0
    private let tick = Timer.publish(every: 1.0 / 20, on: .main, in: .common).autoconnect()

    private let sources = ["claude-code", "codex", "cursor", "github-copilot",
                           "gemini-cli", "opencode"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                roster
                ForEach(FleetStrip.Style.allCases) { style in
                    panel(style)
                }
                scaling
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
        .onReceive(tick) { _ in time += 1.0 / 20 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Fleet strip").font(.title2.bold())
            Text("One slice per running agent. 32 ÷ 4 = 8 pixels, which is exactly one mark — so up to four agents each get a full logo, and colour carries the state. Nothing scrolls, nothing rotates, nothing is cut.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var roster: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(slots.count) agent\(slots.count == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
                Button("Add") {
                    slots.append(.init(source: sources[slots.count % sources.count],
                                       state: .thinking))
                }
                .disabled(slots.count >= 8)
                Button("Remove") { if !slots.isEmpty { slots.removeLast() } }
                    .disabled(slots.isEmpty)
            }
            ForEach(slots.indices, id: \.self) { index in
                HStack {
                    SourceIcon(source: slots[index].source, size: 16)
                    Picker("", selection: Binding(
                        get: { slots[index].source },
                        set: { slots[index] = .init(source: $0, state: slots[index].state) })) {
                        ForEach(sources, id: \.self) { source in
                            Text(AppModel.readableSourceName(source)).tag(source)
                        }
                    }
                    .frame(width: 170)
                    Picker("", selection: Binding(
                        get: { slots[index].state },
                        set: { slots[index] = .init(source: slots[index].source, state: $0) })) {
                        ForEach(AgentState.allCases, id: \.self) { state in
                            Text(state.wireName.capitalized).tag(state)
                        }
                    }
                    .frame(width: 130)
                }
            }
        }
    }

    private func panel(_ style: FleetStrip.Style) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(style.rawValue).font(.headline)
            MatrixView(canvas: FleetStrip.render(slots, style: style,
                                                 colors: model.config.display.stateColors,
                                                 time: time), pixelSize: 15)
            Text(style.detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// How each count actually lays out — the thing that decides whether this
    /// idea survives contact with a busy afternoon.
    private var scaling: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("How it scales").font(.headline)
            ForEach(1...6, id: \.self) { count in
                HStack(spacing: 10) {
                    Text("\(count)").font(.caption.monospaced()).frame(width: 14)
                    MatrixView(canvas: FleetStrip.render(
                        (0..<count).map { index in
                            .init(source: sources[index % sources.count],
                                  state: AgentState.allCases[(index % 5) + 1])
                        },
                        style: .markAndBar,
                        colors: model.config.display.stateColors, time: time),
                               pixelSize: 7, showsBezel: false)
                    Text(count <= FleetStrip.maximumMarks
                         ? "\(32 / count)px per slice"
                         : "no room for marks — falls back to blocks")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }
}
