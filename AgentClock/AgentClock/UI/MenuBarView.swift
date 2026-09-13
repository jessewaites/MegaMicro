import SwiftUI

/// The menu-bar panel: who is running, what they're doing, how long.
/// Deliberately narrow — this is a glance surface, the clock is the other one.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// Drives elapsed-time relabelling without the model publishing per second.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            SimulatedClockView(pixelSize: 8, showsCaption: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            if model.liveSessions.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.liveSessions, id: \.key) { session in
                            row(session)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            Divider()
            footer
        }
        .frame(width: 300)
        .onReceive(tick) { now = $0 }
        .onAppear { model.startSimulatorTick() }
        .onDisappear { model.stopSimulatorTick() }
    }

    private var header: some View {
        HStack {
            Text("AgentClock").font(.headline)
            Spacer()
            Text(model.clockStatusText)
                .font(.caption)
                .foregroundStyle(model.clockIsReachable ? .secondary : Color.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var empty: some View {
        Text("No agents reporting.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }

    private func row(_ session: AgentSession) -> some View {
        HStack(spacing: 10) {
            SourceIcon(source: session.source, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.workContext(for: session)
                     ?? model.projectName(for: session)
                     ?? AppModel.readableSourceName(session.source))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(session.state.wireName.capitalized)
                    .font(.caption)
                    .foregroundStyle(color(for: session.state))
            }
            Spacer()
            Text(AppModel.elapsed(since: session.startedAt, now: now))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { openWindow(id: "settings"); model.showSettingsWindow() }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.link)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Same colours the clock uses, so the panel and the desk agree.
    private func color(for state: AgentState) -> Color {
        Color(hex: StatePalette.color(for: state, in: model.config.display.stateColors)) ?? .secondary
    }
}
