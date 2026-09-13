import SwiftUI

/// EXPERIMENTAL — one page per provider, and what the rotation between them
/// looks like. Delete with `ProviderPage`.
struct ProviderLabPane: View {
    @Environment(AppModel.self) private var model

    @State private var claudeState: AgentState = .coding
    @State private var claudeSubagents = 3
    @State private var claudeQuota = 0.27
    @State private var claudeContext = 0.56       // this session, measured

    @State private var codexState: AgentState = .waiting
    @State private var codexSubagents = 0
    @State private var codexQuota = 0.09
    @State private var codexContext = 0.31

    @State private var rotating = true
    @State private var time: TimeInterval = 0
    private let tick = Timer.publish(every: 1.0 / 20, on: .main, in: .common).autoconnect()

    /// Subagent states cycle so the blocks aren't all one colour.
    private func crew(_ count: Int) -> [AgentState] {
        (0..<count).map { [AgentState.thinking, .coding, .waiting, .coding][$0 % 4] }
    }

    private var claude: ProviderPage.Model {
        .init(source: "claude-code", state: claudeState, subagents: crew(claudeSubagents),
              quota: claudeQuota, context: claudeContext)
    }
    private var codex: ProviderPage.Model {
        .init(source: "codex", state: codexState, subagents: crew(codexSubagents),
              quota: codexQuota, context: codexContext)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                rotation
                controls
                ForEach(ProviderPage.Style.allCases) { style in
                    stylePanel(style)
                }
            }
            .frame(maxWidth: 700, alignment: .leading)
        }
        .onReceive(tick) { _ in time += 1.0 / 20 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Provider pages").font(.title2.bold())
            Text("One page each, rotating — which is what the device does natively with pushed apps. Each provider gets the whole panel instead of a quarter of it.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The thing you actually judge: not one page, but the alternation.
    private var rotation: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("The rotation, as you'd see it").font(.headline)
                Spacer()
                Toggle("Rotate", isOn: $rotating).toggleStyle(.switch).controlSize(.small)
            }
            let showClaude = !rotating || Int(time / 4) % 2 == 0
            MatrixView(canvas: ProviderPage.render(showClaude ? claude : codex,
                                                   style: .bossAndCrew,
                                                   colors: model.config.display.stateColors,
                                                   time: time), pixelSize: 15)
            Text(showClaude ? "Claude page" : "Codex page")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Claude").font(.headline).gridColumnAlignment(.leading)
                Picker("", selection: $claudeState) {
                    ForEach(AgentState.allCases, id: \.self) { Text($0.wireName.capitalized).tag($0) }
                }.frame(width: 120)
                Stepper("\(claudeSubagents) subagents", value: $claudeSubagents, in: 0...20)
                    .frame(width: 150)
            }
            GridRow {
                Text("").frame(width: 60)
                Text("quota").font(.caption)
                Slider(value: $claudeQuota, in: 0...1).frame(width: 200)
            }
            GridRow {
                Text("Codex").font(.headline)
                Picker("", selection: $codexState) {
                    ForEach(AgentState.allCases, id: \.self) { Text($0.wireName.capitalized).tag($0) }
                }.frame(width: 120)
                Stepper("\(codexSubagents) subagents", value: $codexSubagents, in: 0...20)
                    .frame(width: 150)
            }
            GridRow {
                Text("").frame(width: 60)
                Text("quota").font(.caption)
                Slider(value: $codexQuota, in: 0...1).frame(width: 200)
            }
        }
    }

    private func stylePanel(_ style: ProviderPage.Style) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(style.rawValue).font(.headline)
            MatrixView(canvas: ProviderPage.render(claude, style: style,
                                                   colors: model.config.display.stateColors,
                                                   time: time), pixelSize: 14)
            Text(style.detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
