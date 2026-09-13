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

    /// Width of one label gutter beside the drawing.
    private static let calloutWidth: CGFloat = 52
    private static let calloutGap: CGFloat = 10
    private static var deviceHeight: CGFloat { deviceWidth / FXMicView.aspect }
    private static var artWidth: CGFloat { deviceWidth + 2 * (calloutWidth + calloutGap) }

    private var deviceColumn: some View {
        VStack(spacing: 18) {
            ZStack {
                FXMicView(level: level,
                          clipping: clipping,
                          presetBank: bank,
                          lastSlot: slot,
                          voiceActive: voiceActive)
                    .frame(width: Self.deviceWidth, height: Self.deviceHeight)
                    .position(x: Self.artWidth / 2, y: Self.deviceHeight / 2)
                calloutLeaders
                ForEach(FXMicView.callouts) { callout in
                    calloutLabel(callout)
                        .frame(width: Self.calloutWidth, height: 18)
                        .position(x: calloutLabelX(callout.side),
                                  y: callout.yFraction * Self.deviceHeight)
                }
            }
            .frame(width: Self.artWidth, height: Self.deviceHeight)
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

    /// FX1–FX4 beside the drawing, each on a leader line to its control and
    /// lit while that control is pressed, so "press FX3" and the button under
    /// your thumb can't disagree. Positioned absolutely: a stack of offsets
    /// is exactly how a label ends up next to the wrong button.
    private func calloutLabelX(_ side: FXMicView.Callout.Side) -> CGFloat {
        side == .left ? Self.calloutWidth / 2
                      : Self.artWidth - Self.calloutWidth / 2
    }

    private var calloutLeaders: some View {
        Canvas { context, _ in
            for callout in FXMicView.callouts {
                let y = callout.yFraction * Self.deviceHeight
                var path = Path()
                if callout.side == .left {
                    path.move(to: CGPoint(x: Self.calloutWidth, y: y))
                    path.addLine(to: CGPoint(x: Self.calloutWidth + Self.calloutGap + 4, y: y))
                } else {
                    path.move(to: CGPoint(x: Self.artWidth - Self.calloutWidth, y: y))
                    path.addLine(to: CGPoint(x: Self.artWidth - Self.calloutWidth - Self.calloutGap - 4, y: y))
                }
                let active = calloutActive(callout.label)
                context.stroke(path, with: .color(active ? .green : Color.secondary.opacity(0.6)),
                               lineWidth: 1)
            }
        }
        .frame(width: Self.artWidth, height: Self.deviceHeight)
        .allowsHitTesting(false)
    }

    private func calloutLabel(_ callout: FXMicView.Callout) -> some View {
        let active = calloutActive(callout.label)
        return Text(callout.label)
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(active ? Color.green : Color.secondary)
            .frame(maxWidth: .infinity,
                   alignment: callout.side == .left ? .trailing : .leading)
            .animation(.easeOut(duration: 0.12), value: active)
    }

    private func calloutActive(_ label: String) -> Bool {
        switch label {
        case FXMicControlName.handle: return appState.micVoiceActive
        case FXMicControlName.fxButton: return appState.micLinkButtons.fx
        case FXMicControlName.middleButton: return appState.micLinkButtons.select
        case FXMicControlName.bottomButton: return appState.micLinkButtons.play
        default: return false
        }
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

    // MARK: Sample buttons → actions

    @ViewBuilder
    private var cueSection: some View {
        if appState.micUSBConnected {
            usbSection
        } else {
            audioFallbackSection
        }
    }

    /// The real thing: buttons, handle and page straight from the firmware.
    private var usbSection: some View {
        GroupBox("Mic controls") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("Connected over USB-C. The buttons, handle and page are read from the mic's firmware directly — nothing is inferred from audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("How the four controls work")
                        .font(.caption.weight(.semibold))
                    Text("• \(FXMicControlName.handle), the handle, does the same thing on every page.")
                    Text("• \(FXMicControlName.fxButton), the small orange button, changes the page. The mic's red dot shows which page you're on.")
                    Text("• \(FXMicControlName.middleButton) and \(FXMicControlName.bottomButton) do whatever the current page says — five pages, so ten mappings between them.")
                    Text("The mic also switches its own voice effect with the page; each page's effect is named under it.")
                        .foregroundStyle(.tertiary)
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
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Two files on the mic's own disk that turn it from an effects toy into
    /// a quiet control surface. Toggles rather than buttons: the state is
    /// read off the disk, so what's shown is what the mic will boot with.
    @State private var diskRefresh = 0
    private var diskTweaks: some View {
        let volume = appState.micDiskVolume()
        _ = diskRefresh
        return VStack(alignment: .leading, spacing: 8) {
            Text("On the mic's disk")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let volume {
                Toggle("Clean voice on every page — \(FXMicControlName.fxButton) changes the page, not the sound",
                       isOn: Binding(
                        get: { FXMicDisk.isApplied(.cleanPages, on: volume) },
                        set: { appState.setMicDiskTweak(.cleanPages, enabled: $0); diskRefresh += 1 }))
                Toggle("Silent samples — \(FXMicControlName.bottomButton) runs its mapping without playing a sound",
                       isOn: Binding(
                        get: { FXMicDisk.isApplied(.silentSamples, on: volume) },
                        set: { appState.setMicDiskTweak(.silentSamples, enabled: $0); diskRefresh += 1 }))
                Text("Changing either ejects the disk so the mic restarts. Turn one off to get the factory behaviour back.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("The disk shows up only while the USB-C cable is in and the mic is on; it's ejected after each change. Unplug and replug the cable to bring it back.")
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
                Text(down ? "squeezed \(Int(appState.micLinkHandle * 100))%" : "released")
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
                    Text(FXMicProtocol.pageEffect(page))
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

    /// No USB cable: all we have is the line-in, so the sample buttons are
    /// decoded as tones and the handle is guessed from the line going live.
    private var audioFallbackSection: some View {
        GroupBox("Mic controls") {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Plug the mic's USB-C port (under the lower lid) into this Mac and the buttons, handle and page are read directly. Until then MegaMicro can only hear the mic.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "cable.connector")
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                Text("""
                Over audio alone: pressing the handle powers the mic, so audio appearing on the \
                line *is* the handle going down. Each of the four sample slots gets a short \
                two-tone chirp; when \(FXMicControlName.bottomButton) plays one, the tone is decoded and its \
                action runs. \(FXMicControlName.middleButton) picks the sample and \(FXMicControlName.fxButton) picks a \
                voice effect — both silent, so neither can be heard.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                handleRow
                Divider()
                ForEach(0..<CueTones.cueCount, id: \.self) { cue in
                    cueRow(cue)
                }

                Divider()

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button("Export cue tones…") { appState.exportCueTones() }
                    Text(AppState.mountedMicDisks().isEmpty
                         ? "Mic disk not mounted — you'll pick a folder."
                         : "Mic disk is mounted — the tones go straight onto it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message = appState.micCueExportMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("""
                To load them: take off the mic's lower lid, press the handle so it's on, and \
                plug the USB-C port under the lid into the Mac. A disk named "fx-mic disk" \
                appears; the tones replace 1.wav–4.wav in its root. Eject it and the mic \
                restarts with the new sounds. The factory horn, applause, bell and censor \
                beep are overwritten — save them first if you want them back.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Divider()
                detectorStatus
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var handleRow: some View {
        let action = appState.action(for: FXMicLayout.handle, gesture: .press)
        let down = appState.micVoiceActive
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Circle()
                    .fill(down ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
                    .animation(.easeOut(duration: 0.15), value: down)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Handle")
                    Text(down ? "down" : "up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 110, alignment: .leading)
                Text(action == .none ? "Nothing" : action.summary)
                    .font(.body.monospaced())
                    .foregroundStyle(action == .none ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Button("Edit…") { appState.editHandle() }
            }
            HStack(spacing: 10) {
                Text("Sensitivity")
                    .font(.caption)
                    .frame(width: 110, alignment: .leading)
                Slider(value: Binding(
                    get: { appState.config.micHandleThresholdDB },
                    set: { appState.setMicHandleThreshold($0) }), in: -90 ... -10)
                Text("\(Int(appState.config.micHandleThresholdDB)) dB")
                    .font(.caption.monospaced())
                    .frame(width: 52, alignment: .trailing)
            }
            Text(appState.micConnected
                 ? "Line is at \(Int(appState.micLevelDB)) dB now. Handle counts as down above the threshold; it lets go after 0.8 s of quiet. Set it just above what you see with the handle released."
                 : "Handle counts as down when the line rises above the threshold; it lets go after 0.8 s of quiet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cueRow(_ cue: Int) -> some View {
        let (low, high) = CueTones.frequencies(for: cue)
        let action = appState.action(for: FXMicLayout.cue(cue), gesture: .press)
        let lit = appState.micLastSlot == cue
        return HStack(spacing: 12) {
            Circle()
                .fill(lit ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
                .animation(.easeOut(duration: 0.15), value: lit)
            VStack(alignment: .leading, spacing: 1) {
                Text(CueTones.label(cue))
                Text("\(Int(low)) + \(Int(high)) Hz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 110, alignment: .leading)
            Text(action == .none ? "Nothing" : action.summary)
                .font(.body.monospaced())
                .foregroundStyle(action == .none ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Button("Test") { appState.fireCue(cue) }
                .disabled(action == .none)
            Button("Edit…") { appState.editCue(cue) }
        }
    }

    /// One line on what the decoder hears, so a tone that's loaded wrong (or a
    /// level that's too low) is visible without opening the log.
    private var detectorStatus: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !appState.micConnected {
                Text("Detector idle — not listening.")
            } else if let reading = appState.micToneReading {
                Text("Hearing \(CueTones.label(reading.cue)) at \(Int(reading.purity * 100))% purity\(reading.purity >= ToneDetector.minPairPurity ? "" : " — below the \(Int(ToneDetector.minPairPurity * 100))% it takes to fire")")
            } else {
                Text("Detector listening — no cue tone in the input.")
            }
            if let last = appState.micLastCueSummary {
                Text("Last fired: \(last)")
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
