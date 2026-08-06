import Foundation

/// Built-in profiles shipped with the app. All user-editable; these are just
/// sensible defaults derived from the official Conductor shortcut cheatsheet
/// (Docs/conductor-keyboard-shortcuts.pdf, Conductor 0.68.0) and Ghostty.
enum DefaultProfiles {
    static let conductorBundleID = "com.conductor.app"
    static let ghosttyBundleID = "com.mitchellh.ghostty"
    static let mosaicBundleID = "mosaic.com.emergent.app"
    static let iTerm2BundleID = "com.googlecode.iterm2"
    static let vsCodeBundleID = "com.microsoft.VSCode"
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    static let warpBundleIDs = ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"]
    static let kittyBundleID = "net.kovidgoyal.kitty"
    static let wezTermBundleID = "com.github.wez.wezterm"

    static var all: [Profile] { [conductor, ghostty, mosaic, iTerm2, cursor, vsCode, warp, kitty, wezTerm] }

    private static func terminalProfile(id: String, name: String, bundleIDs: [String],
                                        launchCommand: String,
                                        nextTab: KeyChord, previousTab: KeyChord,
                                        nextPane: KeyChord, previousPane: KeyChord) -> Profile {
        var m: [ControlID: [ControlGesture: Action]] = [:]
        m[.key(6)] = [.press: .keystroke(chord: KeyChord(keyCode: KeyCodes.f13, modifiers: []), target: .frontmost)]
        m[.key(7)] = [.press: .typeText("\r")]
        m[.key(8)] = [.press: .typeText("\u{1B}")]
        m[.key(9)] = [.press: .keystroke(
            chord: KeyChord(keyCode: KeyCodes.c, modifiers: .control), target: .frontmost)]
        m[.key(10)] = [.press: .cycleProfile]
        m[.key(11)] = [.press: .holdKeystroke(
            chord: KeyChord(keyCode: KeyCodes.z, modifiers: .command), target: .frontmost)]
        m[.key(12)] = [.press: .shell(command: launchCommand)]
        m[.dial] = [
            .clockwise: .keystroke(chord: nextTab, target: .frontmost),
            .counterclockwise: .keystroke(chord: previousTab, target: .frontmost),
            .press: .keystroke(chord: KeyChord(keyCode: KeyCodes.returnKey, modifiers: []), target: .frontmost),
        ]
        m[.joystick] = [
            .up: .keystroke(chord: previousPane, target: .frontmost),
            .down: .keystroke(chord: nextPane, target: .frontmost),
            .left: .keystroke(chord: previousTab, target: .frontmost),
            .right: .keystroke(chord: nextTab, target: .frontmost),
        ]
        return Profile(id: id, name: name, appBundleIDs: bundleIDs,
                       mappings: m, rgbRules: .standard)
    }

    // MARK: Conductor

    static let conductor: Profile = {
        func key(_ code: UInt16, _ mods: Modifiers = []) -> Action {
            .keystroke(chord: KeyChord(keyCode: code, modifiers: mods), target: .frontmost)
        }
        var m: [ControlID: [ControlGesture: Action]] = [:]
        // Keys 0–5 are the translucent AGENT keys: they display agent state
        // and are reserved for agent interactions — no shortcut defaults.
        // Row 3: the agent-control keys (match printed keycaps ⚡✓⊗⑂ region)
        m[.key(6)] = [.press: key(KeyCodes.returnKey, [.command, .shift])]     // ✓ approve plan ⌘⇧↵
        m[.key(7)] = [.press: key(KeyCodes.returnKey)]                         // approve tool request ↵
        m[.key(8)] = [.press: key(KeyCodes.delete, [.command, .shift])]        // ⊗ cancel agent ⌘⇧⌫
        m[.key(9)] = [.press: key(KeyCodes.p, [.command, .shift])]             // ⑂ create PR ⌘⇧P
        // Bottom row
        m[.key(10)] = [.press: .cycleProfile]                                  // the round mode-switch button
        m[.key(11)] = [.press: .holdKeystroke(                                 // the wide Talk key: push-to-talk
            chord: KeyChord(keyCode: KeyCodes.z, modifiers: .command), target: .frontmost)]
        m[.key(12)] = [.press: key(KeyCodes.a, [.command, .shift])]            // archive workspace ⌘⇧A
        // Dial: model dial — press opens Conductor's model picker (⌥P),
        // rotate moves through it, confirm with ✓/↵.
        m[.dial] = [
            .press: key(KeyCodes.p, .option),
            .clockwise: key(KeyCodes.downArrow),
            .counterclockwise: key(KeyCodes.upArrow),
        ]
        // Joystick: diff navigation + tabs
        m[.joystick] = [
            .up: key(KeyCodes.k),                                              // prev file in diff
            .down: key(KeyCodes.j),                                            // next file in diff
            .left: key(KeyCodes.h, .option),                                   // prev needs-attention ⌥H
            .right: key(KeyCodes.l, .option),                                  // next needs-attention ⌥L
        ]
        return Profile(
            id: "conductor",
            name: "Conductor",
            appBundleIDs: [conductorBundleID],
            mappings: m,
            rgbRules: .standard)
    }()

    // MARK: Ghostty

    static let ghostty: Profile = {
        func key(_ code: UInt16, _ mods: Modifiers = []) -> Action {
            .keystroke(chord: KeyChord(keyCode: code, modifiers: mods), target: .frontmost)
        }
        var m: [ControlID: [ControlGesture: Action]] = [:]
        // Keys 0–5: agent keys, no shortcut defaults.
        m[.key(6)] = [.press: .keystroke(chord: KeyChord(keyCode: KeyCodes.f13, modifiers: []), target: .frontmost)]                                // approve Claude confirmation only
        m[.key(7)] = [.press: .typeText("\r")]                                 // plain enter
        m[.key(8)] = [.press: .typeText("\u{1B}")]                             // ⊗ escape / interrupt
        m[.key(9)] = [.press: key(KeyCodes.c, .control)]                       // hard interrupt ^C
        m[.key(10)] = [.press: .cycleProfile]                                  // the round mode-switch button
        m[.key(11)] = [.press: .holdKeystroke(                                 // the wide Talk key: push-to-talk
            chord: KeyChord(keyCode: KeyCodes.z, modifiers: .command), target: .frontmost)]
        m[.key(12)] = [.press: .shell(command: "open -a Ghostty")]
        m[.dial] = [
            .clockwise: key(KeyCodes.rightBracket, [.command, .shift]),        // next tab
            .counterclockwise: key(KeyCodes.leftBracket, [.command, .shift]),  // prev tab
            .press: key(KeyCodes.returnKey),
        ]
        m[.joystick] = [
            .up: key(KeyCodes.leftBracket, [.command, .option]),               // prev split
            .down: key(KeyCodes.rightBracket, [.command, .option]),            // next split
            .left: key(KeyCodes.leftBracket, [.command, .shift]),
            .right: key(KeyCodes.rightBracket, [.command, .shift]),
        ]
        return Profile(
            id: "ghostty",
            name: "Ghostty",
            appBundleIDs: [ghosttyBundleID],
            mappings: m,
            rgbRules: .standard)
    }()

    static let mosaic = terminalProfile(
        id: "mosaic",
        name: "Mosaic",
        bundleIDs: [mosaicBundleID],
        launchCommand: "open -a Mosaic",
        nextTab: KeyChord(keyCode: KeyCodes.rightBracket, modifiers: [.command, .shift]),
        previousTab: KeyChord(keyCode: KeyCodes.leftBracket, modifiers: [.command, .shift]),
        nextPane: KeyChord(keyCode: KeyCodes.rightBracket, modifiers: [.command, .option]),
        previousPane: KeyChord(keyCode: KeyCodes.leftBracket, modifiers: [.command, .option]))

    // MARK: iTerm2

    /// iTerm2 uses the same terminal-oriented agent controls as Ghostty. The
    /// navigation keys use iTerm2's standard tab shortcuts; exact agent
    /// focusing is handled separately through its reveal-session URL.
    static let iTerm2: Profile = {
        func key(_ code: UInt16, _ mods: Modifiers = []) -> Action {
            .keystroke(chord: KeyChord(keyCode: code, modifiers: mods), target: .frontmost)
        }
        var m: [ControlID: [ControlGesture: Action]] = [:]
        m[.key(6)] = [.press: .keystroke(chord: KeyChord(keyCode: KeyCodes.f13, modifiers: []), target: .frontmost)]
        m[.key(7)] = [.press: .typeText("\r")]
        m[.key(8)] = [.press: .typeText("\u{1B}")]
        m[.key(9)] = [.press: key(KeyCodes.c, .control)]
        m[.key(10)] = [.press: .cycleProfile]
        m[.key(11)] = [.press: .holdKeystroke(
            chord: KeyChord(keyCode: KeyCodes.z, modifiers: .command), target: .frontmost)]
        m[.key(12)] = [.press: .shell(command: "open -a iTerm")]
        m[.dial] = [
            .clockwise: key(KeyCodes.rightArrow, .command),
            .counterclockwise: key(KeyCodes.leftArrow, .command),
            .press: key(KeyCodes.returnKey),
        ]
        m[.joystick] = [
            .up: key(KeyCodes.upArrow, [.command, .option]),
            .down: key(KeyCodes.downArrow, [.command, .option]),
            .left: key(KeyCodes.leftArrow, .command),
            .right: key(KeyCodes.rightArrow, .command),
        ]
        return Profile(
            id: "iterm2",
            name: "iTerm2",
            appBundleIDs: [iTerm2BundleID],
            mappings: m,
            rgbRules: .standard)
    }()

    static let vsCode = terminalProfile(
        id: "vscode", name: "Visual Studio Code", bundleIDs: [vsCodeBundleID],
        launchCommand: "open -a 'Visual Studio Code'",
        nextTab: KeyChord(keyCode: KeyCodes.rightBracket, modifiers: [.command, .shift]),
        previousTab: KeyChord(keyCode: KeyCodes.leftBracket, modifiers: [.command, .shift]),
        nextPane: KeyChord(keyCode: KeyCodes.downArrow, modifiers: [.command, .option]),
        previousPane: KeyChord(keyCode: KeyCodes.upArrow, modifiers: [.command, .option]))

    static let cursor = terminalProfile(
        id: "cursor", name: "Cursor", bundleIDs: [cursorBundleID],
        launchCommand: "open -a Cursor",
        nextTab: KeyChord(keyCode: KeyCodes.rightBracket, modifiers: [.command, .shift]),
        previousTab: KeyChord(keyCode: KeyCodes.leftBracket, modifiers: [.command, .shift]),
        nextPane: KeyChord(keyCode: KeyCodes.downArrow, modifiers: [.command, .option]),
        previousPane: KeyChord(keyCode: KeyCodes.upArrow, modifiers: [.command, .option]))

    static let warp = terminalProfile(
        id: "warp", name: "Warp", bundleIDs: warpBundleIDs,
        launchCommand: "open -a Warp",
        nextTab: KeyChord(keyCode: KeyCodes.rightArrow, modifiers: .command),
        previousTab: KeyChord(keyCode: KeyCodes.leftArrow, modifiers: .command),
        nextPane: KeyChord(keyCode: KeyCodes.rightBracket, modifiers: .command),
        previousPane: KeyChord(keyCode: KeyCodes.leftBracket, modifiers: .command))

    static let kitty = terminalProfile(
        id: "kitty", name: "Kitty", bundleIDs: [kittyBundleID],
        launchCommand: "open -a kitty",
        nextTab: KeyChord(keyCode: KeyCodes.rightArrow, modifiers: [.command, .shift]),
        previousTab: KeyChord(keyCode: KeyCodes.leftArrow, modifiers: [.command, .shift]),
        nextPane: KeyChord(keyCode: KeyCodes.rightBracket, modifiers: [.command, .shift]),
        previousPane: KeyChord(keyCode: KeyCodes.leftBracket, modifiers: [.command, .shift]))

    static let wezTerm = terminalProfile(
        id: "wezterm", name: "WezTerm", bundleIDs: [wezTermBundleID],
        launchCommand: "open -a WezTerm",
        nextTab: KeyChord(keyCode: KeyCodes.rightArrow, modifiers: [.command, .shift]),
        previousTab: KeyChord(keyCode: KeyCodes.leftArrow, modifiers: [.command, .shift]),
        nextPane: KeyChord(keyCode: KeyCodes.rightBracket, modifiers: [.command, .shift]),
        previousPane: KeyChord(keyCode: KeyCodes.leftBracket, modifiers: [.command, .shift]))
}
