import SwiftUI

/// The FX-MIC's tab of Manage Devices: the reconstruction on the left, and
/// everything you can actually change on the right.
struct MicrophonePane: View {
    @Environment(AppState.self) private var appState

    /// Drives the drawing from a slider when no hardware is attached, so the
    /// art can be judged before the USB audio adapter arrives.
    @State private var previewing = false
    @State private var previewLevel: Double = 0.45
    @State private var previewClipping = false
    @State private var previewBank = 0
    @State private var previewSlot: Int? = nil

    private var level: Double { previewing ? previewLevel : appState.micLevel }
    private var clipping: Bool { previewing ? previewClipping : appState.micClipping }
    private var bank: Int { previewing ? previewBank : appState.micPresetBank }
    private var slot: Int? { previewing ? previewSlot : appState.micLastSlot }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 72) {
                deviceColumn
                controlColumn
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { appState.refreshMicInputs() }
    }

    // MARK: Left — the device

    /// Width of the mic column. The drawing's height follows from its aspect,
    /// so the caption below always clears the cable.
    private static let deviceWidth: CGFloat = 250

    private var deviceColumn: some View {
        VStack(spacing: 18) {
            FXMicView(level: level,
                      clipping: clipping,
                      presetBank: bank,
                      lastSlot: slot,
                      voiceActive: level > 0.12)
                .frame(width: Self.deviceWidth,
                       height: Self.deviceWidth / FXMicView.aspect)
                // The cable runs to the very bottom of the art box, so the
                // caption needs real clearance under it, not just VStack
                // spacing.
                .padding(.bottom, 44)

            HStack(spacing: 6) {
                Circle()
                    .fill(appState.micConnected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(appState.micConnected
                     ? (appState.micName ?? "Listening")
                     : "Not listening")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("EP–2350 FX–MIC")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: Self.deviceWidth)
    }

    // MARK: Right — everything you can change

    private var controlColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("""
            The EP–2350 has no data connection to your Mac — its USB-C port is storage \
            only, and the handle and buttons report nothing. Everything MegaMicro knows \
            about it arrives as audio, so the drawing is the diagnostic: the grille \
            lights with the input level, and the handle leans in while you're talking.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let error = appState.micError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            inputSection
            outputSection
            previewSection
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var inputSection: some View {
        GroupBox("Listening on") {
            VStack(alignment: .leading, spacing: 10) {
                if appState.micInputs.isEmpty {
                    Text("""
                    No audio inputs found. The mic's 3.5 mm cable is a stereo TRS \
                    line-out, which a Mac's own jack reads as headphones — you need a \
                    USB audio adapter with a separate mic input for it to show up here.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(appState.micInputs) { input in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(input.name)
                                Text(input.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            if appState.micConnected && appState.micName == input.name {
                                Label("Live", systemImage: "waveform")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Button("Listen") { appState.connectMic(to: input) }
                            }
                        }
                    }
                }

                // A remembered-but-absent device stays visible, so the choice
                // survives an unplug rather than silently reverting.
                if let saved = appState.config.micInputName,
                   !appState.micInputs.contains(where: { $0.name == saved }) {
                    Text("\(saved) — not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                HStack {
                    Toggle("Reconnect at launch", isOn: Binding(
                        get: { appState.config.micEnabled },
                        set: { appState.setMicEnabled($0) }))
                    Spacer(minLength: 12)
                    Button("Rescan") { appState.refreshMicInputs() }
                    if appState.micConnected {
                        Button("Stop") { appState.disconnectMic() }
                    }
                }
                Text("MegaMicro opens this input directly, so the mic never becomes your system microphone — other apps keep whatever they were using.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var outputSection: some View {
        GroupBox("Keep sound on the speakers") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Hold system output where I put it", isOn: Binding(
                    get: { appState.config.micKeepOutputOnSpeakers },
                    set: { appState.setMicKeepOutputOnSpeakers($0) }))

                Text("""
                macOS moves audio output to whatever you just plugged in, so a USB audio \
                adapter can take sound off your speakers without asking. This puts it \
                back, and stands down on its own if something else is fighting it.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if appState.config.micKeepOutputOnSpeakers {
                    Picker("Output", selection: Binding(
                        get: { appState.config.micPreferredOutputUID ?? "" },
                        set: { appState.setMicPreferredOutput($0.isEmpty ? nil : $0) })) {
                        Text("Current default").tag("")
                        ForEach(appState.micOutputs) { output in
                            Text(output.name).tag(output.id)
                        }
                    }
                    .frame(maxWidth: 380)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var previewSection: some View {
        GroupBox("Preview") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Drive the drawing by hand", isOn: $previewing)
                if previewing {
                    HStack {
                        Text("Level").frame(width: 46, alignment: .leading)
                        Slider(value: $previewLevel, in: 0...1)
                    }
                    Toggle("Clipping", isOn: $previewClipping)
                    Picker("Bank", selection: $previewBank) {
                        Text("A").tag(0)
                        Text("B").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    Picker("Slot", selection: $previewSlot) {
                        Text("—").tag(Int?.none)
                        ForEach(0..<4, id: \.self) { Text("\($0 + 1)").tag(Int?.some($0)) }
                    }
                    .frame(maxWidth: 240)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
