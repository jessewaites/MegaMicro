import SwiftUI

/// Sheet for editing what one control gesture does in the active profile.
struct MappingEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: EditTarget

    private enum ActionType: String, CaseIterable, Identifiable {
        case keystroke = "Keystroke"
        case holdKeystroke = "Hold Keystroke (push-to-talk)"
        case openURL = "Open URL"
        case shell = "Shell Command"
        case typeText = "Type Text"
        case runSkill = "Run Skill"
        case slashCommand = "Claude Command"
        case switchProfile = "Switch Profile"
        case cycleProfile = "Cycle Profiles"
        case none = "Nothing"
        var id: String { rawValue }
    }

    @State private var actionType: ActionType = .none
    @State private var keyCode: UInt16 = KeyCodes.n
    @State private var modifiers: Modifiers = []
    @State private var text = ""
    @State private var profileID = ""
    @State private var skillName = ""
    @State private var skills: [Skill] = []
    @State private var pinColor = false
    @State private var pinnedColor = Color.red
    @State private var keyLabel = ""
    @State private var recording = false
    @State private var recordMonitor: Any?

    /// Mic cues get their slot name; everything else keeps the raw control id.
    private var title: String {
        if target.control == FXMicLayout.handle { return "FX-MIC · \(FXMicControlName.handle) handle (held while squeezed)" }
        if let cell = FXMicProtocol.describe(target.control) { return "FX-MIC · \(cell)" }
        if target.control.rawValue.hasPrefix("mic.cue."),
           let cue = Int(target.control.rawValue.dropFirst("mic.cue.".count)) {
            return "FX-MIC · \(CueTones.label(cue)) · grey button"
        }
        return "\(target.control.rawValue) · \(target.gesture.rawValue)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.bold())

            Picker("Action", selection: $actionType) {
                ForEach(ActionType.allCases) { Text($0.rawValue).tag($0) }
            }

            switch actionType {
            case .keystroke, .holdKeystroke:
                if actionType == .holdKeystroke {
                    Text("The shortcut is held down for as long as the key is held — for push-to-talk dictation and similar hold-to-activate tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Text(recording
                         ? "Press the shortcut now…"
                         : KeyChord(keyCode: keyCode, modifiers: modifiers).display)
                        .font(.title3.monospaced())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(recording ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(recording ? Color.accentColor : Color.secondary.opacity(0.3)))
                    Button(recording ? "Cancel" : "Record…") { toggleRecording() }
                }
                HStack(spacing: 12) {
                    Toggle("🌐", isOn: modifierBinding(.fn))
                    Toggle("⌃", isOn: modifierBinding(.control))
                    Toggle("⌥", isOn: modifierBinding(.option))
                    Toggle("⇧", isOn: modifierBinding(.shift))
                    Toggle("⌘", isOn: modifierBinding(.command))
                }
                .toggleStyle(.button)
                .disabled(recording)
                Text("Click Record, then press the real shortcut on your keyboard. Toggles let you adjust modifiers afterwards (e.g. add 🌐).")
                    .font(.caption).foregroundStyle(.secondary)
            case .openURL:
                TextField("conductor://prompt=Fix%20the%20tests", text: $text)
                    .textFieldStyle(.roundedBorder)
            case .shell:
                TextField("pnpm test", text: $text)
                    .textFieldStyle(.roundedBorder)
            case .typeText:
                TextField("y⏎ (use \\r for return)", text: $text)
                    .textFieldStyle(.roundedBorder)
            case .runSkill:
                if skills.isEmpty {
                    Text("No skills found in ~/.claude/skills or this project's .claude/skills.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Skill", selection: $skillName) {
                        ForEach(skills) { skill in
                            Text(skill.isPersonal ? skill.name : "\(skill.name)  ·  \(skill.projectName ?? "")")
                                .tag(skill.name)
                        }
                    }
                }
                TextField("or type a skill name", text: $skillName)
                    .textFieldStyle(.roundedBorder)
                if let match = skills.first(where: { $0.name == skillName }), !match.summary.isEmpty {
                    Text(match.summary).font(.caption).foregroundStyle(.secondary)
                }
                Text("Types “use the \(skillName.isEmpty ? "…" : skillName) skill” into whatever app is in front and presses return. Asking in words rather than with /\(skillName.isEmpty ? "…" : skillName) means it works in a Codex tab too, not just Claude Code.")
                    .font(.caption).foregroundStyle(.secondary)
            case .slashCommand:
                Picker("Command", selection: $skillName) {
                    ForEach(ClaudeCommands.all) { command in
                        Text("/\(command.name)").tag(command.name)
                    }
                }
                if let match = ClaudeCommands.all.first(where: { $0.name == skillName }) {
                    Text(match.summary).font(.caption).foregroundStyle(.secondary)
                }
                Text("Claude Code's own commands. /model opens the model picker — pair it with the dial to scroll the list.")
                    .font(.caption).foregroundStyle(.secondary)
            case .switchProfile:
                Picker("Profile", selection: $profileID) {
                    ForEach(appState.config.profiles) { Text($0.name).tag($0.id) }
                }
            case .cycleProfile:
                Text("Advances to the next profile each press, wrapping around — the mode-switch key.")
                    .foregroundStyle(.secondary)
            case .none:
                Text("This control does nothing.").foregroundStyle(.secondary)
            }

            if target.gesture == .press, target.control.rawValue.hasPrefix("key.") {
                Divider()
                Toggle("Always this colour", isOn: $pinColor)
                if pinColor {
                    ColorPicker("Key colour", selection: $pinnedColor, supportsOpacity: false)
                    Text("This key ignores agent state and stays the colour you pick — for keys that run a command rather than host an agent.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("This key follows the state of whatever agent is assigned to it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("Key glyph — match whatever physical keycap is on this key:")
                    .font(.callout)
                GlyphGrid(current: keyLabel.isEmpty ? nil : keyLabel) { selection in
                    keyLabel = selection ?? ""
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            loadCurrent()
            // Personal skills plus any project the live agents are working in,
            // so a key can be bound to a project-scoped skill.
            let projects = Set(appState.sessionStore.sessions.values.compactMap(\.cwd)).map { URL(fileURLWithPath: $0) }
            skills = SkillCatalog.discover(projectDirectories: projects)
            if skillName.isEmpty {
                skillName = actionType == .slashCommand ? "model" : (skills.first?.name ?? "")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    // MARK: Shortcut recording

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            keyCode = event.keyCode
            modifiers = Modifiers(cgFlags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
            stopRecording()
            return nil   // swallow the recorded press
        }
    }

    private func stopRecording() {
        if let recordMonitor {
            NSEvent.removeMonitor(recordMonitor)
        }
        recordMonitor = nil
        recording = false
    }

    private func modifierBinding(_ flag: Modifiers) -> Binding<Bool> {
        Binding(
            get: { modifiers.contains(flag) },
            set: { on in if on { modifiers.insert(flag) } else { modifiers.remove(flag) } })
    }

    private func loadCurrent() {
        switch appState.action(for: target.control, gesture: target.gesture) {
        case .keystroke(let chord, _):
            actionType = .keystroke
            keyCode = chord.keyCode
            modifiers = chord.modifiers
        case .holdKeystroke(let chord, _):
            actionType = .holdKeystroke
            keyCode = chord.keyCode
            modifiers = chord.modifiers
        case .openURL(let url):
            actionType = .openURL; text = url
        case .shell(let command):
            actionType = .shell; text = command
        case .typeText(let value):
            actionType = .typeText
            text = value.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\u{1B}", with: "\\e")
        case .runSkill(let name):
            actionType = ClaudeCommands.contains(name) ? .slashCommand : .runSkill
            skillName = name
        case .switchProfile(let id):
            actionType = .switchProfile; profileID = id
        case .cycleProfile:
            actionType = .cycleProfile
        case .none:
            actionType = .none
        }
        if profileID.isEmpty { profileID = appState.config.profiles.first?.id ?? "" }
        keyLabel = appState.activeLayoutSettings.keyLegends[target.control] ?? ""
        if let index = Int(target.control.rawValue.dropFirst("key.".count)),
           let existing = appState.activeLayoutSettings.keyColors[index] {
            pinColor = true
            let rgb = existing.rgb
            pinnedColor = Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        } else {
            pinColor = false
        }
    }

    private func save() {
        let action: Action
        switch actionType {
        case .keystroke:
            action = .keystroke(chord: KeyChord(keyCode: keyCode, modifiers: modifiers), target: .frontmost)
        case .holdKeystroke:
            action = .holdKeystroke(chord: KeyChord(keyCode: keyCode, modifiers: modifiers), target: .frontmost)
        case .openURL:
            action = .openURL(text)
        case .shell:
            action = .shell(command: text)
        case .typeText:
            let unescaped = text
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\e", with: "\u{1B}")
            action = .typeText(unescaped)
        case .runSkill, .slashCommand:
            action = .runSkill(name: skillName.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")))
        case .switchProfile:
            action = .switchProfile(profileID)
        case .cycleProfile:
            action = .cycleProfile
        case .none:
            action = .none
        }
        appState.setAction(action, for: target.control, gesture: target.gesture)
        if let index = Int(target.control.rawValue.dropFirst("key.".count)) {
            if pinColor, let rgb = NSColor(pinnedColor).usingColorSpace(.deviceRGB) {
                appState.setPinnedColor(HSV(r: rgb.redComponent,
                                            g: rgb.greenComponent,
                                            b: rgb.blueComponent), forKey: index)
            } else {
                appState.setPinnedColor(nil, forKey: index)
            }
        }
        let trimmed = keyLabel.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            appState.activeLayoutSettings.keyLegends.removeValue(forKey: target.control)
        } else {
            appState.activeLayoutSettings.keyLegends[target.control] = trimmed
        }
    }
}
