import SwiftUI

/// Guided one-time setup for the EP-2350: puts MegaMicro's script on the mic
/// and proves the audio path works. Each step watches the hardware and ticks
/// itself off — the disk mounting, the script landing, the line-in going
/// live, the first chirp decoding — so the user only ever does the physical
/// bit and glances back.
struct MicSetupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Chirps heard before the sheet opened don't count as proof.
    @State private var openedAt = Date()
    @State private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var disk: URL? { _ = tick; return appState.micDiskVolume() }
    private var scriptOnDisk: Bool { disk.map { FXMicDisk.isApplied(.controlScript, on: $0) } ?? false }
    private var installedThisSession: Bool { appState.micScriptInstalledAt.map { $0 > openedAt } ?? false }
    private var heardSinceOpen: Bool { appState.micScriptLastHeard.map { $0 > openedAt } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up the FX-MIC")
                    .font(.title2.bold())
                Text("Five minutes, once. Afterwards the mic talks to MegaMicro over its own audio cable — no USB.")
                    .foregroundStyle(.secondary)
            }

            Text("You'll need: the mic, two AAA batteries, a USB-C cable that carries data, and a USB audio adapter with a **line-in** jack (the Cubilux HLMS-C4 is known good). A Mac's headphone jack can't take the mic's line-level output.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            step(1, done: disk != nil || installedThisSession, title: "Open the mic and plug in USB-C",
                 detail: "Slide off the lower white faceplate. Squeeze the handle until the mic lights up. Plug the USB-C port under the lid straight into this Mac. A disk named \"FX MIC DISK\" appears; this step ticks itself when it does.") {
                statusLine(disk != nil ? "Found \(disk!.lastPathComponent)" : "Waiting for the mic's disk…",
                           active: disk != nil)
            }

            step(2, done: installedThisSession, title: "Install MegaMicro's script",
                 detail: "Writes main.py and four short chirp samples to the disk, then ejects it. The mic's own firmware stays as it is; the script is a file it loads at power-on. Delete the file and the mic is stock again.") {
                HStack(spacing: 10) {
                    Button(installedThisSession ? "Installed" : (scriptOnDisk ? "Reinstall script" : "Install script")) {
                        appState.setMicDiskTweak(.controlScript, enabled: true)
                    }
                    .disabled(disk == nil || installedThisSession)
                    if scriptOnDisk && !installedThisSession {
                        Text("A copy is already on the disk.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            step(3, done: installedThisSession && disk == nil && appState.micConnected, title: "Close it up and connect audio",
                 detail: "Unplug USB-C. Put the two AAA batteries in and slide the faceplate back on. Plug the mic's 3.5 mm cable into the adapter's jack marked with the waves symbol — that's line-in, not the microphone symbol. Then press Listen on that input below.") {
                VStack(alignment: .leading, spacing: 6) {
                    if appState.micInputs.isEmpty {
                        statusLine("No audio inputs found — plug the adapter into the Mac.", active: false)
                    }
                    ForEach(appState.micInputs) { input in
                        HStack {
                            Text(input.name).font(.callout)
                            Spacer(minLength: 12)
                            if appState.micConnected && appState.micName == input.name {
                                Label("Live", systemImage: "waveform").font(.caption).foregroundStyle(.green)
                            } else {
                                Button("Listen") { appState.connectMic(to: input) }.controlSize(.small)
                            }
                        }
                    }
                    if let error = appState.micError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            step(4, done: heardSinceOpen, title: "Squeeze the handle",
                 detail: "The mic boots, runs the script, and announces itself with a chirp code. When MegaMicro decodes it, this step ticks and you're done. If nothing happens: check the plug is in the waves jack, and that the mic is lit.") {
                statusLine(heardSinceOpen ? "Heard the mic. FX1–FX4 are live." : (appState.micConnected ? "Listening for the first chirp…" : "Waiting for a live input first."),
                           active: heardSinceOpen)
            }

            Text("One rule going forward: don't install Teenage Engineering firmware updates on this mic. The script depends on the firmware it was written against (1.0.9), and the mic can't update itself, so nothing changes unless someone does it by hand.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let message = appState.micDiskMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(heardSinceOpen ? "Done" : "Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onReceive(timer) { _ in
            tick += 1
            appState.refreshMicInputs()
        }
    }

    private func step<Content: View>(_ number: Int, done: Bool, title: String, detail: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.bold()).foregroundStyle(.secondary)
                }
            }
            .animation(.easeOut(duration: 0.2), value: done)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    private func statusLine(_ text: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(active ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
