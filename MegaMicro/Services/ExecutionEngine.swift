import AppKit
import CoreGraphics

/// Executes mapped actions: keystroke injection, URL opening (conductor://
/// deep links), shell commands, and literal text typing.
@MainActor
final class ExecutionEngine {
    var log: (String) -> Void = { _ in }

    /// `preferredBundleID` is the active profile's app: when a keystroke
    /// targets .frontmost but that app isn't frontmost (e.g. simulate-mode
    /// click, or pressing a Conductor key while in a browser), we activate it
    /// first so the shortcut lands where the user meant it to.
    /// `phase` matters only for .holdKeystroke; every other action fires on
    /// .down and ignores .up.
    func perform(_ action: Action, phase: PressPhase = .down, preferredBundleID: String? = nil) {
        if case .holdKeystroke(let chord, _) = action {
            switch phase {
            case .down: postPhase(chord, keyDown: true)
            case .up: postPhase(chord, keyDown: false)
            }
            return
        }
        guard phase == .down else { return }
        switch action {
        case .none, .holdKeystroke, .cycleProfile:
            break   // cycleProfile is handled by AppState before the engine
        case .keystroke(let chord, let target):
            sendChord(chord, target: target, preferredBundleID: preferredBundleID)
        case .openURL(let urlString):
            guard let url = URL(string: urlString) else {
                log("bad URL: \(urlString)")
                return
            }
            NSWorkspace.shared.open(url)
        case .shell(let command):
            runShell(command)
        case .typeText(let text):
            Task { await self.typeText(text) }
        case .runSkill(let name):
            // Exactly what you'd type: the slash command, then return.
            Task { await self.typeText("/\(name)\r") }
        case .switchProfile:
            break   // handled by AppState before reaching the engine
        }
    }

    // MARK: Keystrokes

    private func sendChord(_ chord: KeyChord, target: TargetApp, preferredBundleID: String?) {
        var bundleToActivate: String?
        switch target {
        case .bundleID(let id):
            bundleToActivate = id
        case .frontmost:
            if let preferred = preferredBundleID,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier != preferred {
                bundleToActivate = preferred
            }
        }

        Task {
            if let bundleID = bundleToActivate {
                await self.activate(bundleID: bundleID)
            }
            self.post(chord)
        }
    }

    private func activate(bundleID: String) async {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            running.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else {
            log("app not found: \(bundleID)")
            return
        }
        // Give the app a beat to take key focus before the keystroke lands.
        try? await Task.sleep(for: .milliseconds(180))
    }

    /// One half of a held chord (push-to-talk down or up).
    private func postPhase(_ chord: KeyChord, keyDown: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: keyDown) else { return }
        event.flags = chord.modifiers.cgFlags
        event.post(tap: .cghidEventTap)
    }

    private func post(_ chord: KeyChord) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: false)
        else { return }
        down.flags = chord.modifiers.cgFlags
        up.flags = chord.modifiers.cgFlags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: Text

    /// Types `text` into the frontmost app.
    ///
    /// Characters that exist on the US layout are sent as REAL key events.
    /// Terminals (Ghostty, iTerm, Terminal.app) read the virtual keycode and
    /// ignore any attached Unicode payload — so a Unicode-only event built
    /// with `virtualKey: 0` arrives as the letter "a", which is the keycode
    /// for 0. Anything outside the table still rides the Unicode path, which
    /// is fine for the GUI apps that honour it.
    private func typeText(_ text: String) async {
        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            if let (code, needsShift) = Self.usKeyCode(for: character) {
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
                else { continue }
                if needsShift {
                    down.flags.insert(.maskShift)
                    up.flags.insert(.maskShift)
                }
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            } else {
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                else { continue }
                var units = Array(String(character).utf16)
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(6))
        }
    }

    /// US-ANSI virtual keycodes: character → (keycode, shift needed).
    static func usKeyCode(for character: Character) -> (UInt16, Bool)? {
        let unshifted: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
            "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "`": 50,
            "\r": 36, "\n": 36, "\t": 48, " ": 49, "\u{1B}": 53,
        ]
        if let code = unshifted[character] { return (code, false) }

        // Shifted pairs share the unshifted key.
        let shifted: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
            "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\",
            ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
        ]
        if let base = shifted[character], let code = unshifted[base] { return (code, true) }
        if character.isUppercase,
           let lower = character.lowercased().first,
           let code = unshifted[lower] { return (code, true) }
        return nil
    }

    // MARK: Shell

    private func runShell(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let logger = log
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                logger("$ \(command) → exit \(status)")
            }
        }
        do {
            try process.run()
        } catch {
            log("shell failed: \(error.localizedDescription)")
        }
    }
}

private extension Collection where Element == UInt16 {
    func chunked(into size: Int) -> [[UInt16]] {
        var result: [[UInt16]] = []
        var chunk: [UInt16] = []
        for unit in self {
            chunk.append(unit)
            if chunk.count == size {
                result.append(chunk)
                chunk = []
            }
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
}
