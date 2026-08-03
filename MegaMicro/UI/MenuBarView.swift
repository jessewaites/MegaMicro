import SwiftUI

/// The MM menu bar panel: a live mini agent board — who's on which key and
/// what state they're in — without opening the app.
struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Agent Fleet")
                    .font(.headline)
                if appState.demoModeEnabled {
                    Text("DEMO")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.orange))
                }
                Spacer()
                Text(appState.activeProfile.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            KeyboardView()
                .environment(\.agentBoardMode, true)
                .frame(width: 250, height: 235)

            let notice = appState.fleetNotification
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(notificationColor(notice.state))
                    .frame(width: 9, height: 9)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(compactHeadline(notice))
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(compactDetail(notice.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent Activity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if appState.activityFeed.isEmpty {
                    Text("No recent agent activity")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(appState.activityFeed.prefix(3)) { item in
                        HStack(alignment: .top, spacing: 7) {
                            SourceIcon(source: item.source, size: 14)
                                .frame(width: 17, height: 17)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(activityHeadline(item))
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text(activityContext(item))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Circle()
                                .fill(notificationColor(item.state))
                                .frame(width: 6, height: 6)
                                .padding(.top, 4)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button(appState.hardwareConnected ? "Turn Off Keyboard" : "Turn On Keyboard") {
                    if appState.hardwareConnected {
                        appState.disconnectHardware()
                    } else {
                        appState.connectHardware()
                    }
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.callout)

            HStack {
                Button(appState.demoModeEnabled ? "Stop Demo" : "Start Demo") {
                    appState.toggleDemoMode()
                }
                if appState.demoModeEnabled {
                    Button("Next Cast") { appState.nextDemoCast() }
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.callout)

            HStack {
                Button("Open MegaMicro") {
                    openWindow(id: "config")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(12)
        .frame(width: 280)
    }

    private func notificationColor(_ state: AgentState) -> Color {
        Color(hsv: appState.activeProfile.rgbRules.spec(for: state).color)
    }

    /// The full fleet notice belongs in the main window. In the narrow menu
    /// panel, keep the agent/key on line one and the actionable signal on
    /// line two so neither needs an ellipsis.
    private func compactHeadline(_ notice: FleetNotification) -> String {
        notice.headline.components(separatedBy: " — ").first ?? notice.headline
    }

    private func compactDetail(_ state: AgentState) -> String {
        switch state {
        case .error: "review error"
        case .waiting: "permission needed"
        case .thinking: "thinking"
        case .coding: "working"
        case .success: "finished"
        case .idle: "no action needed"
        }
    }

    private func activityHeadline(_ item: ActivityFeedItem) -> String {
        item.agentName + " " + item.message
    }

    private func activityContext(_ item: ActivityFeedItem) -> String {
        let time = item.at.formatted(.relative(presentation: .named))
        let key = item.keySlot.map { "Key \($0 + 1)" }
        return [item.project, key, time].compactMap { $0 }.joined(separator: " · ")
    }
}
