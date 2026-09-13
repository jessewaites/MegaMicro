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
    private var voiceActive: Bool { previewing ? previewLevel > 0.12 : appState.micVoiceActive }

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
        // The Keyboard pane hosts this same sheet; only one pane is mounted at
        // a time, so the two never present together.
        .sheet(item: Binding(
            get: { appState.editTarget },
            set: { appState.editTarget = $0 }
        )) { target in
            MappingEditorView(target: target)
        }
    }

    // MARK: Left — the device

    /// Width of the mic column. The drawing's height follows from its aspect,
    /// so the caption below always clears the cable.
    private static let deviceWidth: CGFloat = 250

    private static var deviceHeight: CGFloat { deviceWidth / FXMicView.aspect }
    private static var artWidth: CGFloat { deviceWidth + 2 * (FXMicView.calloutWidth + 8) }

    private var deviceColumn: some View {
        VStack(spacing: 18) {
            FXMicView(level: level,
                      clipping: clipping,
                      pageLevel: bank,
                      lastSlot: slot,
                      voiceActive: voiceActive,
                      fxPressed: appState.micLinkButtons.fx,
                      selectPressed: appState.micLinkButtons.select,
                      playPressed: appState.micLinkButtons.play,
                      showCallouts: true)
                .frame(width: Self.deviceWidth, height: Self.deviceHeight)
                .padding(.horizontal, FXMicView.calloutWidth + 8)
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
        .frame(width: Self.artWidth)
    }

    // MARK: Right — everything you can change

    private var controlColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("""
            Two cables, two jobs. The 3.5 mm line out carries your voice to the audio \
            adapter, and that's all the "Listening on" input is for. The USB-C port under \
            the lower lid carries the controls: over it MegaMicro reads \(FXMicControlName.handle) (the handle), \
            \(FXMicControlName.fxButton) (the small orange page button), \(FXMicControlName.middleButton) and \(FXMicControlName.bottomButton) straight from the mic's \
            firmware. Labels beside the drawing light as you press.
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
            cueSection
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

    // MARK: Controls

    private enum ControlSource { case usb, script, none }
    private var controlSource: ControlSource {
        if appState.micUSBConnected { return .usb }
        if appState.micScriptLastHeard != nil { return .script }
        return .none
    }

    private var cueSection: some View {
        GroupBox("Mic controls") {
            VStack(alignment: .leading, spacing: 12) {
                sourceLine

                VStack(alignment: .leading, spacing: 4) {
                    Text("How the four controls work")
                        .font(.caption.weight(.semibold))
                    Text("• \(FXMicControlName.handle), the handle, does the same thing on every page.")
                    Text("• \(FXMicControlName.fxButton), the small orange button, changes the page. The mic's red LEDs count the page.")
                    Text("• \(FXMicControlName.middleButton) and \(FXMicControlName.bottomButton) do whatever the current page says — five pages, so ten mappings between them.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text("Every page")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                usbHandleRow
                Divider()
                Text("Per page — \(FXMicControlName.fxButton) picks the page")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                pageGrid
                Divider()
                diskTweaks
                if controlSource != .usb {
                    Divider()
                    detectorStatus
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(controlSource == .none ? Color.secondary.opacity(0.4) : Color.green)
                .frame(width: 7, height: 7)
            Group {
                switch controlSource {
                case .usb:
                    Text("Controls arriving over USB-C from the mic's firmware. Handy for setup; for everyday use the audio cable alone is enough once the script is on the mic.")
                case .script:
                    Text("Controls arriving over the audio cable — the mic's script chirps a code for every press and MegaMicro decodes it from the line-in. Last heard \(appState.micScriptLastHeard!.formatted(date: .omitted, time: .standard)).")
                case .none:
                    Text(appState.micConnected
                         ? "Listening, but nothing from the mic yet. Squeeze the handle: if the script is installed you'll see the row below flip. If not, install it under \"On the mic's disk\"."
                         : "Not listening. Press Listen on the mic's line input above.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The one file set that turns the mic into a control surface.
    @State private var diskRefresh = 0
    private var diskTweaks: some View {
        let volume = appState.micDiskVolume()
        _ = diskRefresh
        return VStack(alignment: .leading, spacing: 8) {
            Text("On the mic's disk")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let volume {
                Toggle("MegaMicro control script (v\(FXMicScript.version)) — makes every button and the handle speak over the audio cable",
                       isOn: Binding(
                        get: { FXMicDisk.isApplied(.controlScript, on: volume) },
                        set: { appState.setMicDiskTweak(.controlScript, enabled: $0); diskRefresh += 1 }))
                Text("Turning it on writes main.py and four chirp samples and ejects the disk; turning it off removes them. Either way, power-cycle the mic afterwards.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("To install or remove the script: take off the mic's lower lid, squeeze the handle so it's on, plug its USB-C port into this Mac, and the toggle appears here. Once installed you can unplug USB for good.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = appState.micDiskMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var usbHandleRow: some View {
        let action = appState.action(for: FXMicLayout.handle, gesture: .press)
        let down = appState.micVoiceActive
        return HStack(spacing: 12) {
            Circle()
                .fill(down ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
                .animation(.easeOut(duration: 0.15), value: down)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(FXMicControlName.handle) · handle")
                Text(down ? "squeezed" : "released")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 130, alignment: .leading)
            Text(action == .none ? "Nothing" : action.summary)
                .font(.body.monospaced())
                .foregroundStyle(action == .none ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Button("Edit…") { appState.editHandle() }
        }
    }

    private var pageGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Page").frame(width: 130, alignment: .leading)
                ForEach(FXMicProtocol.Button.allCases, id: \.self) { button in
                    Text(button.label).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(0..<FXMicProtocol.pageCount, id: \.self) { page in
                pageRow(page)
            }
        }
    }

    private func pageRow(_ page: Int) -> some View {
        let current = appState.micLinkPage == page
        return HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(current ? Color.orange : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(FXMicProtocol.pageLabel(page))
                        .fontWeight(current ? .semibold : .regular)
                    Text(page == 0 ? "no red LEDs" : "\(page) red LED\(page == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 130, alignment: .leading)
            ForEach(FXMicProtocol.Button.allCases, id: \.self) { button in
                pageCell(page: page, button: button)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(current ? Color.orange.opacity(0.10) : Color.clear))
        .animation(.easeOut(duration: 0.15), value: current)
    }

    private func pageCell(page: Int, button: FXMicProtocol.Button) -> some View {
        let action = appState.action(for: FXMicProtocol.control(page: page, button: button), gesture: .press)
        let pressed = appState.micLinkPage == page
            && (button == .play ? appState.micLinkButtons.play : appState.micLinkButtons.select)
        return HStack(spacing: 8) {
            Text(action == .none ? "Nothing" : action.summary)
                .font(.callout.monospaced())
                .foregroundStyle(action == .none ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(pressed ? Color.green.opacity(0.35) : Color.clear))
            Spacer(minLength: 4)
            Button("Test") { appState.testMicButton(page: page, button: button) }
                .controlSize(.small)
                .disabled(action == .none)
            Button("Edit…") { appState.editMicButton(page: page, button: button) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One line on what the chirp decoder hears, so a mis-set level or a
    /// missing script is visible without opening the log.
    private var detectorStatus: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !appState.micConnected {
                Text("Chirp decoder idle — not listening.")
            } else if let reading = appState.micToneReading {
                Text("Hearing symbol \(reading.cue) at \(Int(reading.purity * 100))% purity\(reading.purity >= ToneDetector.minPairPurity ? "" : " — below the \(Int(ToneDetector.minPairPurity * 100))% it takes to count")")
            } else {
                Text("Chirp decoder listening — nothing in the input right now.")
            }
            if let last = appState.micLastCueSummary {
                Text("Last symbol: \(last)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
                    Picker("Page", selection: $previewBank) {
                        ForEach(0..<FXMicProtocol.pageCount, id: \.self) { Text("\($0 + 1)").tag($0) }
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
