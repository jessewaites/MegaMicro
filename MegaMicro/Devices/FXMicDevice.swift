import Foundation

/// The Teenage Engineering EP-2350 FX-MIC, as far as the Mac can see it.
///
/// Pointedly **not** a `KeyboardDevice`: that protocol is frame/LED-shaped —
/// `apply(_ frame:)`, `sendRaw(_:)` — and this device has no light we can drive
/// and no data channel at all. It lives in its own slot on `AppState` next to
/// `hardwareDevice`, which is what lets it run at the same time as the Creator
/// Micro 2: that one is IOKit HID, this one is CoreAudio, and they never contend.
///
/// It owns an audio input, publishes a level, and runs the `ToneDetector` on
/// the same block stream so a sample-button press on the mic comes out the far
/// end as a cue index. The voice gate is still to come.
final class FXMicDevice {
    let layout = FXMicLayout.layout

    /// Smoothed 0…1 meter level and a clip flag, on the audio thread. Callers
    /// hop to the main actor themselves, matching how `VOAIDevice` hands off.
    var onLevel: ((_ level: Float, _ clipping: Bool) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    /// A cue tone was heard and confirmed. Audio thread.
    var onCue: ((ToneDetector.Detection) -> Void)?
    /// What the detector is hearing this block, fired or not. Audio thread.
    var onToneReading: ((ToneDetector.Reading?) -> Void)?
    /// The handle went down (audio appeared) or came up (it stayed quiet for
    /// the hangover). Pressing the handle is what powers the mic, so the line
    /// goes from dead silent to carrying the capsule's floor the instant it's
    /// squeezed — usually well before the first word. Audio thread.
    var onHandle: ((Bool) -> Void)?
    /// Block RMS in dBFS, every block, for the sensitivity readout.
    var onLevelDB: ((Float) -> Void)?

    /// Anything above this counts as the handle being pressed. Line level from
    /// a powered mic sits far above a dead input; set from the UI.
    var handleThresholdDB: Float = -50
    /// Blocks of quiet before the handle is considered released (16 × 50 ms).
    static let handleHangoverBlocks = 16
    private var handleDown = false
    private var quietBlocks = 0

    private let service = AudioInputService()
    private let detector = ToneDetector(sampleRate: AudioInputService.sampleRate)

    private(set) var isConnected = false
    private(set) var inputName: String?
    private(set) var inputUID: String?

    /// Meter ballistics: jump to a new peak immediately, fall away slowly. A
    /// meter that decays as fast as it rises reads as noise rather than speech.
    private static let attack: Float = 0.6
    private static let release: Float = 0.12
    /// Anything below -60 dBFS is floor. Speech into a hot mic-level dongle sits
    /// around -25 dBFS, so this leaves plenty of visible travel.
    private static let floorDB: Float = -60
    private var smoothed: Float = 0

    init() {
        service.onBlock = { [weak self] block, rms, peak in
            guard let self else { return }
            self.meter(rms: rms, peak: peak)
            self.gateHandle(rms: rms)
            let detection = self.detector.process(block, rms: rms)
            self.onToneReading?(self.detector.lastReading)
            if let detection { self.onCue?(detection) }
        }
    }

    /// Devices with input channels, for the picker.
    static func availableInputs() -> [AudioInputService.Input] { AudioInputService.inputs() }

    /// Fires when audio devices come and go, so the UI can re-offer the picker
    /// and a saved-but-absent device can reattach on its own.
    var onDevicesChanged: (() -> Void)? {
        get { service.onDevicesChanged }
        set { service.onDevicesChanged = newValue }
    }

    func startWatchingDevices() { service.startWatchingDevices() }

    func connect(to input: AudioInputService.Input) throws {
        try service.start(on: input)
        isConnected = true
        inputName = input.name
        inputUID = input.id
        smoothed = 0
        detector.reset()
        onConnectionChange?(true)
    }

    func disconnect() {
        guard isConnected else { return }
        service.stop()
        if handleDown {
            handleDown = false
            onHandle?(false)
        }
        quietBlocks = 0
        isConnected = false
        inputName = nil
        inputUID = nil
        smoothed = 0
        onLevel?(0, false)
        onConnectionChange?(false)
    }

    /// Instant attack, slow release: the first loud block presses the handle,
    /// and only a sustained silence lets it go — a pause between words must
    /// not release the push-to-talk.
    private func gateHandle(rms: Float) {
        let db = rms > 0 ? 20 * log10(rms) : -120
        onLevelDB?(db)
        if db >= handleThresholdDB {
            quietBlocks = 0
            if !handleDown {
                handleDown = true
                onHandle?(true)
            }
        } else if handleDown {
            quietBlocks += 1
            if quietBlocks >= Self.handleHangoverBlocks {
                handleDown = false
                onHandle?(false)
            }
        }
    }

    /// RMS → dBFS → 0…1, then smoothed. Working in dB is what makes the meter
    /// track how loud something *sounds*; a linear RMS bar spends most of its
    /// life pinned near zero.
    private func meter(rms: Float, peak: Float) {
        let db = rms > 0 ? 20 * log10(rms) : Self.floorDB
        let normalized = max(0, min(1, (db - Self.floorDB) / -Self.floorDB))
        let coefficient = normalized > smoothed ? Self.attack : Self.release
        smoothed += (normalized - smoothed) * coefficient
        onLevel?(smoothed, peak >= 0.99)
    }
}
