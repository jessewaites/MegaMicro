import SwiftUI
import AppKit

/// Fleet management: what the whole-device signals (underglow halo, aggregate
/// status) represent, and which agents count toward them.
struct FleetPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                Text("Your fleet is every agent reporting to MegaMicro. Each agent lights its own key; the fleet signals below answer the bigger question — \"does anything, anywhere, need me?\"")
                    .font(.callout)
            }

            Section("Current Fleet Notification") {
                let notice = appState.fleetNotification
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color(hsv: appState.activeProfile.rgbRules.spec(for: notice.state).color))
                        .frame(width: 11, height: 11)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(notice.headline).font(.headline)
                        Text(notice.detail).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Picker("Perimeter glow shows", selection: underglowModeBinding) {
                    Text("Fleet status (most urgent agent)").tag(GlowChoice.aggregate)
                    Text("Rainbow, red when blocked").tag(GlowChoice.rainbowUnlessAlert)
                    Text("Solid color").tag(GlowChoice.solid)
                    Text("Off").tag(GlowChoice.off)
                }
                if case .solid(let hsv) = appState.activeProfile.underglow {
                    ColorPicker("Underglow color", selection: underglowColorBinding(current: hsv), supportsOpacity: false)
                }
            } header: {
                Text("Underglow")
            } footer: {
                Text("The ring of light around the device (and the on-screen board). Fleet status: red halo = an agent failed, yellow blink = someone needs input, breathing = the fleet is working. Applies to the active profile (\(appState.activeProfile.name)).")
                    .font(.caption)
            }

            Section {
                if fleetMembers.isEmpty {
                    Text("No agents or workspaces yet. Agents join the fleet automatically when they report in.")
                        .foregroundStyle(.secondary)
                }
                ForEach(fleetMembers, id: \.path) { member in
                    HStack {
                        if let asset = member.brandAsset {
                            BrandIcon(asset: asset, size: 15)
                        } else {
                            SourceIcon(source: member.source ?? "", size: 15)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(member.name).font(.headline)
                            Text(member.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: membershipBinding(path: member.path))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            } header: {
                Text("Fleet Membership")
            } footer: {
                Text("Toggle an agent off to mute it fleet-wide: its own key keeps lighting, but it no longer drives the halo or aggregate status. Useful for a noisy side project you don't want waking the whole board.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Members

    private struct FleetMember {
        let name: String
        let detail: String
        let path: String
        let brandAsset: String?
        let source: String?
    }

    private var fleetMembers: [FleetMember] {
        var members: [FleetMember] = []
        var coveredPaths: [String] = []
        for workspace in appState.workspaces {
            let path = appState.workspacesRoot + "/" + workspace.id
            coveredPaths.append(path)
            members.append(FleetMember(
                name: workspace.displayName,
                detail: "Conductor · \(workspace.project)",
                path: path,
                brandAsset: "conductor",
                source: nil))
        }
        for session in appState.sessionStore.sessions.values.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard let cwd = session.cwd else { continue }
            // Workspace rows already represent their sessions.
            guard !coveredPaths.contains(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) else { continue }
            guard !members.contains(where: { $0.path == cwd }) else { continue }
            members.append(FleetMember(
                name: appState.folderAgentLabel(forPath: cwd),
                detail: "\(session.source) · \(session.state.wireName)",
                path: cwd,
                brandAsset: nil,
                source: session.source))
        }
        return members
    }

    private func membershipBinding(path: String) -> Binding<Bool> {
        Binding(
            get: { !appState.config.fleetExclusions.contains(path) },
            set: { appState.setFleetMembership(path: path, inFleet: $0) })
    }

    // MARK: Underglow (moved here from States & Colors)

    private enum GlowChoice: Hashable { case aggregate, solid, off, rainbowUnlessAlert }

    private var underglowModeBinding: Binding<GlowChoice> {
        Binding(
            get: {
                switch appState.activeProfile.underglow {
                case .aggregate: .aggregate
                case .solid: .solid
                case .off: .off
                case .rainbowUnlessAlert: .rainbowUnlessAlert
                }
            },
            set: { choice in
                let mode: UnderglowMode = switch choice {
                case .aggregate: .aggregate
                case .solid: .solid(HSV(h: 150, s: 180, v: 120))
                case .off: .off
                case .rainbowUnlessAlert: .rainbowUnlessAlert
                }
                updateUnderglow(mode)
            })
    }

    private func underglowColorBinding(current: HSV) -> Binding<Color> {
        Binding(
            get: { Color(hsv: current) },
            set: { newColor in
                guard let rgb = NSColor(newColor).usingColorSpace(.sRGB) else { return }
                updateUnderglow(.solid(HSV(r: rgb.redComponent, g: rgb.greenComponent, b: rgb.blueComponent)))
            })
    }

    private func updateUnderglow(_ mode: UnderglowMode) {
        guard let index = appState.config.profiles.firstIndex(where: { $0.id == appState.config.activeProfileID }) else { return }
        appState.config.profiles[index].underglow = mode
    }
}
