import Foundation

/// The Teenage Engineering EP-2350 FX-MIC, as far as the Mac can see it.
///
/// Pointedly **not** a `KeyboardDevice`: that protocol is frame/LED-shaped —
/// `apply(_ frame:)`, `sendRaw(_:)` — and this device has no light we can drive
/// and no data channel at all. It lives in its own slot on `AppState` next to
/// `hardwareDevice`, which is what lets it run at the same time as the Creator
/// Micro 2: that one is IOKit HID, this one is CoreAudio, and they never contend.
///
/// All this class does today is own an audio input and publish a level. M2 adds
/// the tone detector on the same block stream, and M3 the voice gate.
final class FXMicDevice {
    let layout = FXMicLayout.layout

    /// Smoothed 0…1 meter level and a clip flag, on the audio thread. Callers
    /// hop to the main actor themselves, matching how `VOAIDevice` hands off.
    var onLevel: ((_ level: Float, _ clipping: Bool) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private let service = AudioInputService()

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
        service.onBlock = { [weak self] _, rms, peak in
            self?.meter(rms: rms, peak: peak)
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
        onConnectionChange?(true)
    }

    func disconnect() {
        guard isConnected else { return }
        service.stop()
        isConnected = false
        inputName = nil
        inputUID = nil
        smoothed = 0
        onLevel?(0, false)
        onConnectionChange?(false)
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
