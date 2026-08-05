import SwiftUI

/// App settings: the device's name (how it appears to companions) and iPhone/
/// Watch pairing over the local network.
struct SettingsPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section {
                TextField("Device name", text: $state.config.deviceName)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Device")
            } footer: {
                Text("The name your iPhone and Apple Watch show when they find this Mac on the network.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Picker("Appearance", selection: Binding(
                    get: { appState.config.appearance },
                    set: { appState.setAppearance($0) }
                )) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Appearance")
            } footer: {
                Text("Dark keeps MegaMicro dark whatever the rest of the Mac is doing — the keyboard's own colors are unaffected. System follows your macOS setting.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Mac notifications", isOn: Binding(
                    get: { appState.config.macNotificationsEnabled },
                    set: { appState.setMacNotificationsEnabled($0) }
                ))
            } header: {
                Text("Notifications")
            } footer: {
                Text("Optional alerts appear when an agent needs input, encounters an error, or finishes, including during Demo Mode. Thinking and working updates stay on the keyboard and dashboard.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Steady glow", isOn: $state.config.steadyGlow)
            } header: {
                Text("Lighting")
            } footer: {
                Text("Show agent states as a solid color instead of pulsing or flashing — steadier for photos and less distracting. An error shows as solid red rather than a strobe.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Restore the keyboard when MegaMicro quits", isOn: $state.config.restoreKeyboardOnQuit)
            } header: {
                Text("Keyboard")
            } footer: {
                Text("MegaMicro reprograms the keys so they report to it instead of typing letters — that is what makes per-key color work, and it means the keys do nothing while the app is closed. Turn this on to put the factory keycodes back on quit. Either way the lights go out — switched off in the keyboard itself, since it relights on its own the moment MegaMicro stops driving it, and a board left on a desk shouldn't glow for an app that isn't running. Your lighting comes back when you turn the keyboard on again. To hand the keyboard to Codex or Work Louder Input, use Diagnostics → Release for Editing: only one app can drive it at a time.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(appState.syncServer.isRunning ? .green : .secondary)
                            .frame(width: 8, height: 8)
                        Text(appState.syncServer.isRunning
                             ? "On · port \(SyncServer.port)" : "Off")
                            .foregroundStyle(.secondary)
                    }
                }

                if let code = appState.currentPairingCode {
                    LabeledContent("Pairing code") {
                        Text(code)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text("On your iPhone, open MegaMicro, tap this Mac, and enter the code above.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                HStack {
                    Button(appState.currentPairingCode == nil ? "Pair a Device…" : "New Code") {
                        appState.startPairing()
                    }
                    Spacer()
                    Button("Unpair All Devices", role: .destructive) {
                        appState.unpairAllDevices()
                    }
                }
            } header: {
                Text("iPhone & Watch (Local Network)")
            } footer: {
                Text("Companions mirror your board and can reassign keys while on the same Wi-Fi. Unpairing revokes every device.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
