import SwiftUI

struct PermissionsView: View {
    @Environment(AppState.self) private var appState
    @State private var refreshTimer: Timer?

    var body: some View {
        Form {
            Section {
                permissionRow(
                    title: "Accessibility",
                    granted: appState.accessibilityGranted,
                    why: "Lets MegaMicro capture the macro pad's F-key chords system-wide (and consume them so they don't leak into apps), and send shortcuts to Conductor and Ghostty.",
                    request: {
                        PermissionsService.requestAccessibility()
                        PermissionsService.openAccessibilitySettings()
                    })
                permissionRow(
                    title: "Input Monitoring",
                    granted: appState.inputMonitoringGranted,
                    why: "Fallback listening mode, and raw HID access to the keyboard's LEDs when the device is connected.",
                    request: {
                        PermissionsService.requestInputMonitoring()
                        PermissionsService.openInputMonitoringSettings()
                    })
                permissionRow(
                    title: "Microphone",
                    granted: appState.microphoneGranted,
                    why: "Lets MegaMicro listen to the FX-MIC. It opens that input directly, so the mic never becomes your system microphone and other apps keep whatever they were using.",
                    request: {
                        PermissionsService.requestMicrophone { _ in }
                        PermissionsService.openMicrophoneSettings()
                    })
            } header: {
                Text("Permissions")
            } footer: {
                Text("""
                After granting a permission in System Settings, MegaMicro picks it up within a few \
                seconds. If the System Settings toggle already shows ON but this pane still shows \
                orange, the grant went stale (this happens when a development build is re-signed): \
                in System Settings, remove MegaMicro with the − button, then re-add it with + and \
                enable it again.
                """)
                    .font(.caption)
            }

            Section("Status") {
                LabeledContent("Keystroke listener", value: appState.listenerMode.rawValue)
                if appState.listenerMode != .tap {
                    Button("Retry Event Tap") {
                        appState.refreshPermissions()
                        appState.restartListener()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            appState.refreshPermissions()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in
                    appState.refreshPermissions()
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, granted: Bool, why: String, request: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                    .font(.headline)
                Spacer()
                if !granted {
                    Button("Grant…", action: request)
                }
            }
            Text(why)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
