import SwiftUI

/// EXPERIMENTAL — shows every text treatment on the same label at once, so the
/// choice is made by looking rather than by arithmetic. Delete with `TextLab`
/// once it's settled.
struct TextLabPane: View {
    @Environment(AppModel.self) private var model

    @State private var label = "megamicro"
    @State private var state: AgentState = .coding
    @State private var elapsed = "14m"
    @State private var showIcon = true
    @State private var time: TimeInterval = 0
    @State private var message = "I ❤️ CW"
    @State private var messageAnimation = MessageAnimation.showcase

    private let tick = Timer.publish(every: 1.0 / 20, on: .main, in: .common).autoconnect()

    /// Names worth checking: one that fits, one that just doesn't, one with a
    /// natural break, and a real Conductor-style branch.
    private let samples = ["auth", "megamicro", "agentclock",
                           "add-auth-flow", "fix-payment-bug", "refactor-api"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                messageComposer
                controls
                ForEach(TextLab.Treatment.allCases) { treatment in
                    panel(treatment)
                }
                footnote
            }
            .frame(maxWidth: 660, alignment: .leading)
        }
        .onReceive(tick) { _ in time += 1.0 / 20 }
    }

    private var messageComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Send a message").font(.headline)
            HStack {
                TextField("Message", text: $message)
                Picker("Entrance", selection: $messageAnimation) {
                    ForEach(MessageAnimation.allCases) { animation in
                        Text(animation.label).tag(animation)
                    }
                }
                .frame(width: 180)
                Button(model.messagePlayback.isPlaying ? "Stop" : "Play") {
                    if model.messagePlayback.isPlaying {
                        model.stopMessagePlayback()
                    } else {
                        model.startMessagePlayback(text: message, animation: messageAnimation)
                    }
                }
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            MatrixView(canvas: model.messagePlayback.isPlaying
                       ? model.messagePlayback.canvas
                       : messagePreview, pixelSize: 13)
            Text(model.messagePlayback.isPlaying
                 ? "Looping at 30 fps on the simulator and clock. It keeps playing if you leave this pane; press Stop to return to the agent rotation."
                 : "Play loops the selected animation on the simulator and clock until you press Stop.")
                .font(.caption).foregroundStyle(.secondary)
            if model.messagePlayback.isPlaying {
                Label("Keeping Mac awake · display may turn off", systemImage: "moon.stars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var messagePreview: PixelCanvas {
        let page = ClockPage(text: message, icon: nil, textColor: "#FFFFFF",
                             durationMs: nil, scroll: .static, scrollSpeed: nil,
                             animation: nil)
        return MatrixRenderer.render(page, width: model.panelWidth)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Text lab").font(.title2.bold())
            Text("The same label in every treatment. 32×8 fits eight characters of the firmware's font; everything below is a different way of spending that budget.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Label", text: $label).frame(width: 200)
                Toggle("Icon", isOn: $showIcon)
                Picker("", selection: $state) {
                    ForEach(AgentState.allCases, id: \.self) { state in
                        Text(state.wireName.capitalized).tag(state)
                    }
                }
                .frame(width: 130)
            }
            HStack(spacing: 6) {
                ForEach(samples, id: \.self) { sample in
                    Button(sample) { label = sample }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private func panel(_ treatment: TextLab.Treatment) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(treatment.rawValue).font(.headline)
            MatrixView(canvas: TextLab.render(
                label, state: state, elapsed: elapsed, treatment: treatment,
                colors: model.config.display.stateColors,
                iconID: showIcon ? IconLibrary.iconID(forSource: "claude-code") : nil,
                time: time), pixelSize: 13)
            Text(treatment.detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnote: some View {
        Text("The 5-row form is the firmware's own font, so it scrolls natively and needs no custom drawing. The 3-row forms would be drawn by AgentClock as pixel commands — which costs the native scrolling but makes the simulator pixel-exact instead of an approximation.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }
}
