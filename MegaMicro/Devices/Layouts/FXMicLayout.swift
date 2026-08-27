import Foundation

/// Physical/logical layout of the Teenage Engineering EP-2350 (sold as "ting",
/// marketed as FX-MIC).
///
/// Unlike the Codex Micro, none of this device's controls are visible to the
/// host: its USB-C port is mass storage only, and the handle, the three buttons
/// and the shake sensor report nothing. What *is* observable is audio — so the
/// mic's four sample slots are loaded with cue tones and decoded back out of the
/// input stream (see `ToneDetector`).
///
/// That makes the mappable controls the eight decodable *cues* (four sample
/// slots × two preset banks, the second pitched +10.5 semitones by the orange
/// button) plus the handle, whose squeeze powers the mic on and so reads as
/// voice activity. The three physical buttons are drawn in `FXMicView` as
/// indicators; they are not controls we can bind, because we never see them
/// pressed — only the tone they produce.
///
/// Geometry here is the *cue grid* used by the mapping UI (bank A column, bank B
/// column), not the shape of the hardware; `FXMicView` draws the device itself.
enum FXMicLayout {
    /// Stable id. Deliberately kept out of `AppState.allLayouts` — this is a
    /// separate device, not an alternative keyboard, and must never show up in
    /// the layout switcher. Per-control settings still work, because
    /// `config.layoutSettings` is keyed by this string.
    static let id = "fx-mic"

    /// Cue index → the physical press that produces it. Bank A is the mic's
    /// default preset; bank B is the orange button's second position.
    static func cueLabel(_ cue: Int) -> String {
        let bank = cue < 4 ? "A" : "B"
        return "\(bank)\(cue % 4 + 1)"
    }

    /// `mic.cue.0` … `mic.cue.7`. String-backed like every other `ControlID`,
    /// so `Profile.mappings` and `MappingEditorView` take them unchanged.
    static func cue(_ index: Int) -> ControlID { ControlID(rawValue: "mic.cue.\(index)") }

    /// The handle. Squeezing it powers the mic and enables the capsule, so we
    /// infer it from voice activity rather than from any reported signal.
    static let handle = ControlID(rawValue: "mic.handle")

    static let cueCount = 8

    static let layout = KeyboardLayout(
        id: id,
        name: "EP–2350 FX–MIC",
        columns: 2,
        rows: 5,
        controls: (0..<cueCount).map { cue in
            ControlSpec(id: Self.cue(cue),
                        kind: .key,
                        // Bank A down the left column, bank B down the right.
                        frame: GridRect(x: Double(cue / 4), y: Double(cue % 4), w: 1, h: 1),
                        ledIndex: nil,
                        legend: Self.cueLabel(cue),
                        gestures: [.press],
                        hostsAgents: false)
        } + [
            ControlSpec(id: Self.handle,
                        kind: .key,
                        frame: GridRect(x: 0, y: 4, w: 2, h: 1),
                        ledIndex: nil,
                        legend: "sf:mic",
                        gestures: [.press],
                        hostsAgents: false),
        ])
}
