import Foundation

/// Physical/logical layout of the Teenage Engineering EP-2350 FX-MIC.
///
/// Unlike the Codex Micro, none of this device's controls are visible to the
/// host: its USB-C port (under the battery lid) is mass storage only, and the
/// handle, the three buttons and the shake sensor report nothing. What *is*
/// observable is audio — so the mic's four sample slots are loaded with cue
/// tones and decoded back out of the input stream (see `ToneDetector`).
///
/// On the mic, the white button selects one of the four sample slots and the
/// grey button plays the selected one; the orange button picks a voice effect
/// and makes no sound of its own. That makes the mappable controls the four
/// decodable *cues* — one per slot — plus the handle, whose press powers the
/// mic on and so reads as voice activity. The three physical buttons are drawn
/// in `FXMicView` as indicators; they are not controls we can bind, because we
/// never see them pressed — only the tone they produce.
///
/// Geometry here is the *cue column* used by the mapping UI, not the shape of
/// the hardware; `FXMicView` draws the device itself.
enum FXMicLayout {
    /// Stable id. Deliberately kept out of `AppState.allLayouts` — this is a
    /// separate device, not an alternative keyboard, and must never show up in
    /// the layout switcher. Per-control settings still work, because
    /// `config.layoutSettings` is keyed by this string.
    static let id = "fx-mic"

    /// Cue index → the slot the mic's white button has to be on.
    static func cueLabel(_ cue: Int) -> String { CueTones.label(cue) }

    /// `mic.cue.0` … `mic.cue.3`. String-backed like every other `ControlID`,
    /// so `Profile.mappings` and `MappingEditorView` take them unchanged.
    static func cue(_ index: Int) -> ControlID { ControlID(rawValue: "mic.cue.\(index)") }

    /// The handle. Pressing it powers the mic and enables the capsule, so we
    /// infer it from voice activity rather than from any reported signal.
    static let handle = ControlID(rawValue: "mic.handle")

    static let cueCount = CueTones.cueCount

    static let layout = KeyboardLayout(
        id: id,
        name: "EP–2350 FX–MIC",
        columns: 2,
        rows: 5,
        controls: (0..<cueCount).map { cue in
            ControlSpec(id: Self.cue(cue),
                        kind: .key,
                        frame: GridRect(x: 0, y: Double(cue), w: 2, h: 1),
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
