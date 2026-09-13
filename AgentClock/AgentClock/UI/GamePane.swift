import SwiftUI

/// Full-panel games streamed to the clock over Art-Net.
struct GamePane: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Game.pong

    private enum Game: String, CaseIterable, Identifiable {
        case pong = "Pong"
        case tetris = "Tetris"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Games").font(.title2.bold())
                    Spacer()
                    Picker("Game", selection: $selection) {
                        ForEach(Game.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
                if selection == .pong { pongContent } else { tetrisContent }
            }
            .frame(maxWidth: 660, alignment: .leading)
        }
        .onChange(of: selection) {
            model.stopGame()
            model.stopPong()
        }
        .onDisappear {
            model.stopGame()
            model.stopPong()
        }
    }

    private var pongContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            MatrixView(canvas: model.pong.canvas, pixelSize: 18)
            HStack(spacing: 10) {
                Button(model.pong.isPlaying ? "Stop" : "Play") {
                    model.pong.isPlaying ? model.stopPong() : model.startPong()
                }
                .keyboardShortcut(.defaultAction)
                if model.pong.isPlaying {
                    Text("You \(model.pong.game.playerScore)  ·  \(model.pong.game.computerScore) Computer  ·  lv \(model.pong.game.level)")
                        .font(.headline.monospacedDigit())
                }
                Spacer()
                streamingLabel(isPlaying: model.pong.isPlaying)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow { key("↑ / joystick"); Text("move your left paddle up") }
                GridRow { key("↓ / joystick"); Text("move your left paddle down") }
            }
            .font(.caption).foregroundStyle(.secondary)
            Label(model.pong.controllerStatus, systemImage: "gamecontroller")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("Your cyan paddle is on the left; the pink computer paddle is on the right. Every three total points raises the level, making the computer and serves faster.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tetrisContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            MatrixView(canvas: model.game.canvas, pixelSize: 18)
            HStack(spacing: 10) {
                Button(model.game.isPlaying ? "Stop" : "Play") {
                    model.game.isPlaying ? model.stopGame() : model.startGame()
                }
                .keyboardShortcut(.defaultAction)
                if model.game.isPlaying {
                    Button("Restart") { model.restartGame() }
                    Text("\(model.game.game.score) · lv \(model.game.game.level)")
                        .font(.headline.monospacedDigit())
                }
                Toggle("Landing shadow", isOn: Binding(
                    get: { model.game.showsGhost }, set: { model.game.showsGhost = $0 }))
                    .toggleStyle(.checkbox).controlSize(.small)
                Spacer()
                streamingLabel(isPlaying: model.game.isPlaying)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow { key("↑ ↓"); Text("move across the well") }
                GridRow { key("←"); Text("hurry it along") }
                GridRow { key("space"); Text("drop it now") }
                GridRow { key("→ / Z"); Text("rotate") }
                GridRow { key("R"); Text("restart") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func streamingLabel(isPlaying: Bool) -> some View {
        if model.config.clockHost.isEmpty {
            Label("On-screen only", systemImage: "display.trianglebadge.exclamationmark")
                .font(.caption).foregroundStyle(.secondary)
        } else if isPlaying {
            Label("Streaming", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func key(_ label: String) -> some View {
        Text(label).font(.caption.monospaced())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.controlSurface, in: RoundedRectangle(cornerRadius: 4))
    }
}
