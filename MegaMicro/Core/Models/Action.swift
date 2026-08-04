import Foundation

/// Modifier keys, independent of AppKit/CoreGraphics so Core stays pure.
/// Converted to CGEventFlags at the ExecutionEngine boundary.
struct Modifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int
    static let command = Modifiers(rawValue: 1 << 0)
    static let option  = Modifiers(rawValue: 1 << 1)
    static let control = Modifiers(rawValue: 1 << 2)
    static let shift   = Modifiers(rawValue: 1 << 3)
    /// Fn/Globe 🌐. Injected as the secondary-fn flag; note macOS handles
    /// some Globe behaviors (emoji picker, dictation) below the event layer,
    /// so not every Globe shortcut responds to synthetic presses.
    static let fn      = Modifiers(rawValue: 1 << 4)

    static let hyper: Modifiers = [.command, .option, .control, .shift]

    var symbols: String {
        var s = ""
        if contains(.fn) { s += "🌐" }
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A keyboard chord described with macOS virtual key codes.
struct KeyChord: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: Modifiers

    var display: String {
        modifiers.symbols + (KeyCodes.name(for: keyCode) ?? "vk\(keyCode)")
    }
}

/// Which app a keystroke should be delivered to.
enum TargetApp: Codable, Hashable, Sendable {
    case frontmost
    case bundleID(String)
}

/// Press phase, for actions that distinguish press from release.
enum PressPhase: Sendable {
    case down, up
}

/// What happens when a mapped control fires.
enum Action: Codable, Hashable, Sendable {
    case keystroke(chord: KeyChord, target: TargetApp)
    /// Push-to-talk style: chord keyDown on press, keyUp on release — the
    /// chord stays held exactly as long as the physical/on-screen key is.
    case holdKeystroke(chord: KeyChord, target: TargetApp)
    case openURL(String)
    case shell(command: String)
    case typeText(String)
    /// Invoke a skill by typing a request for it into the frontmost app and
    /// pressing return — works with any agent CLI, since it's just the text
    /// you'd have typed yourself. See `ExecutionEngine` for the exact wording.
    case runSkill(name: String)
    case switchProfile(String)
    /// Advance to the next profile (wraps). The dedicated mode-switch key.
    case cycleProfile
    case none

    var summary: String {
        switch self {
        case .keystroke(let chord, _): chord.display
        case .holdKeystroke(let chord, _): "hold \(chord.display)"
        case .openURL(let url): url
        case .shell(let cmd): "$ \(cmd)"
        case .typeText(let text): "type \(text.replacingOccurrences(of: "\r", with: "⏎").replacingOccurrences(of: "\u{1B}", with: "⎋"))"
        case .runSkill(let name): ClaudeCommands.contains(name) ? "/\(name)" : "skill: \(name)"
        case .switchProfile(let id): "profile → \(id)"
        case .cycleProfile: "next profile"
        case .none: "—"
        }
    }
}

/// macOS virtual key codes (ANSI layout) used by default profiles.
enum KeyCodes {
    static let a: UInt16 = 0x00, s: UInt16 = 0x01, d: UInt16 = 0x02
    static let h: UInt16 = 0x04, c: UInt16 = 0x08, v: UInt16 = 0x09
    static let b: UInt16 = 0x0B, w: UInt16 = 0x0D, e: UInt16 = 0x0E
    static let y: UInt16 = 0x10, t: UInt16 = 0x11, o: UInt16 = 0x1F
    static let u: UInt16 = 0x20, i: UInt16 = 0x22, p: UInt16 = 0x23
    static let l: UInt16 = 0x25, j: UInt16 = 0x26, k: UInt16 = 0x28
    static let n: UInt16 = 0x2D, m: UInt16 = 0x2E, f: UInt16 = 0x03
    static let x: UInt16 = 0x07, g: UInt16 = 0x05, z: UInt16 = 0x06
    static let q: UInt16 = 0x0C, r: UInt16 = 0x0F
    static let space: UInt16 = 0x31
    static let leftArrow: UInt16 = 0x7B, rightArrow: UInt16 = 0x7C
    static let downArrow: UInt16 = 0x7D, upArrow: UInt16 = 0x7E
    static let returnKey: UInt16 = 0x24
    static let tab: UInt16 = 0x30
    static let escape: UInt16 = 0x35
    static let delete: UInt16 = 0x33          // backspace
    static let leftBracket: UInt16 = 0x21
    static let rightBracket: UInt16 = 0x1E
    static let f13: UInt16 = 0x69, f14: UInt16 = 0x6B, f15: UInt16 = 0x71
    static let f16: UInt16 = 0x6A, f17: UInt16 = 0x40, f18: UInt16 = 0x4F
    static let f19: UInt16 = 0x50, f20: UInt16 = 0x5A

    static func name(for code: UInt16) -> String? {
        let names: [UInt16: String] = [
            a: "A", b: "B", c: "C", d: "D", e: "E", f: "F", g: "G", h: "H",
            i: "I", j: "J", k: "K", l: "L", m: "M", n: "N", o: "O", p: "P",
            q: "Q", r: "R", s: "S", t: "T", u: "U", v: "V", w: "W", x: "X",
            y: "Y", z: "Z",
            0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
            0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9", 0x1D: "0",
            returnKey: "↵", tab: "⇥", escape: "⎋", delete: "⌫", space: "Space",
            leftBracket: "[", rightBracket: "]",
            leftArrow: "←", rightArrow: "→", downArrow: "↓", upArrow: "↑",
            f13: "F13", f14: "F14", f15: "F15", f16: "F16",
            f17: "F17", f18: "F18", f19: "F19", f20: "F20",
        ]
        return names[code]
    }
}
