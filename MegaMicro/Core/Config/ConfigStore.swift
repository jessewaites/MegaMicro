import Foundation

/// What one key slot represents. Absent from `keyBindings` = auto:
/// the key is in the shared pool and the next unhomed agent claims it.
enum KeyAgentBinding: Codable, Hashable, Sendable {
    /// Key never lights and is excluded from the auto pool.
    case off
    /// Reserved for a Conductor workspace ("project/workspace" id).
    case workspace(String)
    /// Reserved for any agent working under this directory — one key per
    /// agent-in-a-program, whatever the program is.
    case path(String)
}

/// Per-layout state: which agent lives on which key, and the user's keycap
/// labels. Keyed by layout id in AppConfig so switching boards never loses
/// either board's setup.
struct LayoutSettings: Codable, Hashable, Sendable {
    var keyBindings: [Int: KeyAgentBinding] = [:]
    var keyLegends: [ControlID: String] = [:]
    /// Keys pinned to a fixed colour, by key index. These ignore agent state
    /// entirely — for keys that run a command rather than host an agent, so a
    /// steady colour is the useful signal.
    var keyColors: [Int: HSV] = [:]

    init() {}

    enum CodingKeys: String, CodingKey { case keyBindings, keyLegends, keyColors }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyBindings = try c.decodeIfPresent([Int: KeyAgentBinding].self, forKey: .keyBindings) ?? [:]
        keyLegends = try c.decodeIfPresent([ControlID: String].self, forKey: .keyLegends) ?? [:]
        keyColors = try c.decodeIfPresent([Int: HSV].self, forKey: .keyColors) ?? [:]
    }
}

/// The whole persisted configuration, one versioned Codable document.
struct AppConfig: Codable, Hashable, Sendable {
    static let currentVersion = 31

    var version: Int = AppConfig.currentVersion
    var webhookPort: UInt16 = 48802
    /// Put the factory keycodes back when MegaMicro quits, so the pad types
    /// letters again with the app closed. Off by default: bound keys are the
    /// working state, and reprogramming on every quit is churn.
    var restoreKeyboardOnQuit: Bool = false
    var activeProfileID: String = "conductor"
    var triggerBindings: [TriggerBinding] = DefaultTriggers.codexMicro
    var profiles: [Profile] = DefaultProfiles.all
    var hooksInstalled: Bool = false
    /// Legacy (pre-v3): Conductor workspace → key slot. Migrated into
    /// `keyBindings` on load; kept only so old files still decode.
    var workspaceKeyPins: [String: Int] = [:]
    /// Legacy (pre-v5): key slot → binding. Migrated into layoutSettings.
    var keyBindings: [Int: KeyAgentBinding] = [:]
    /// Which keyboard layout is active ("codex-micro" or a custom import).
    var activeLayoutID: String = "codex-micro"
    /// User-imported layouts (VIA/KLE definitions).
    var customLayouts: [KeyboardLayout] = []
    /// Per-layout key bindings and labels, keyed by layout id.
    var layoutSettings: [String: LayoutSettings] = [:]
    /// Folders whose agents are excluded from fleet-wide signals (the
    /// underglow halo and aggregate status). Their own keys still light.
    var fleetExclusions: [String] = []
    /// App appearance: "system", "light", or "dark".
    var appearance: String = "system"
    /// Optional native macOS alerts for meaningful agent transitions.
    /// Off by default: the keyboard remains the primary attention surface.
    var macNotificationsEnabled: Bool = false
    /// Local, user-editable prompt templates. Built-ins have stable IDs so
    /// their original text can be restored without touching custom snippets.
    var promptSnippets: [PromptSnippet] = DefaultPromptSnippets.all
    /// First-run welcome sheet shown and dismissed.
    var onboardingComplete: Bool = false
    /// A friendly, user-chosen name for the physical desk device.
    var deviceName: String = "My MegaMicro"
    /// Render agent states as a solid color instead of pulsing/flashing. Steadier
    /// for photos and less distracting; applies everywhere the board is shown
    /// (device, on-screen simulator, and synced companions).
    var steadyGlow: Bool = false
    /// Hook event → reported state, per agent CLI. Editable so a future
    /// Claude Code / Codex release renaming or adding events is a config
    /// tweak, not an app update.
    var claudeHookEvents: [String: String] = AppConfig.defaultClaudeHookEvents
    var codexHookEvents: [String: String] = AppConfig.defaultCodexHookEvents
    /// The board's own lighting, set aside while MegaMicro has it switched
    /// off. The firmware relights the keyboard the moment we stop driving it,
    /// so turning it off means writing darkness into the device — and this is
    /// what puts the user's colours back when they switch it on again.
    /// Non-nil means the board is currently blanked, empty means it had
    /// nothing worth saving.
    var savedDeviceLights: [String: String]?

    static let defaultClaudeHookEvents: [String: String] = [
        "SessionStart": "idle",       // announce on boot, before any activity
        "UserPromptSubmit": "thinking",
        "PreToolUse": "coding",
        "PostToolUse": "thinking",
        "PostToolUseFailure": "error",
        "PermissionRequest": "waiting",
        "SubagentStart": "thinking",
        "SubagentStop": "success",
        "Stop": "success",
        "StopFailure": "error",
        "SessionEnd": "idle",
        "TeammateIdle": "idle",
        "Notification": "waiting", // bridge filters metadata; never grants permission
    ]
    static let defaultCodexHookEvents: [String: String] = [
        "SessionStart": "idle",
        "UserPromptSubmit": "thinking",
        "PreToolUse": "coding",
        "PostToolUse": "thinking",
        "PostToolUseFailure": "error",
        "PermissionRequest": "waiting",
        "Stop": "success",
    ]
    /// User-chosen on-screen labels matching whatever physical keycaps are
    /// installed (Codex Micro caps are blank/swappable). Empty = show the
    /// mapped action's shortcut instead.
    var keyLegends: [ControlID: String] = [:]

    init() {}

    func profile(id: String) -> Profile? {
        profiles.first { $0.id == id }
    }

    // Tolerant decoding: a config written by an older version (missing newer
    // keys) must never reset the user's whole configuration — each missing
    // field independently falls back to its default.
    enum CodingKeys: String, CodingKey {
        case version, webhookPort, restoreKeyboardOnQuit, activeProfileID, triggerBindings,
             profiles, hooksInstalled, workspaceKeyPins, keyLegends, keyBindings,
             claudeHookEvents, codexHookEvents,
             activeLayoutID, customLayouts, layoutSettings, fleetExclusions, appearance,
             macNotificationsEnabled, promptSnippets, onboardingComplete, deviceName,
             steadyGlow, savedDeviceLights
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version
        webhookPort = try c.decodeIfPresent(UInt16.self, forKey: .webhookPort) ?? defaults.webhookPort
        restoreKeyboardOnQuit = try c.decodeIfPresent(Bool.self, forKey: .restoreKeyboardOnQuit) ?? defaults.restoreKeyboardOnQuit
        activeProfileID = try c.decodeIfPresent(String.self, forKey: .activeProfileID) ?? defaults.activeProfileID
        triggerBindings = try c.decodeIfPresent([TriggerBinding].self, forKey: .triggerBindings) ?? defaults.triggerBindings
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? defaults.profiles
        hooksInstalled = try c.decodeIfPresent(Bool.self, forKey: .hooksInstalled) ?? defaults.hooksInstalled
        workspaceKeyPins = try c.decodeIfPresent([String: Int].self, forKey: .workspaceKeyPins) ?? defaults.workspaceKeyPins
        keyLegends = try c.decodeIfPresent([ControlID: String].self, forKey: .keyLegends) ?? defaults.keyLegends
        keyBindings = try c.decodeIfPresent([Int: KeyAgentBinding].self, forKey: .keyBindings) ?? defaults.keyBindings
        claudeHookEvents = try c.decodeIfPresent([String: String].self, forKey: .claudeHookEvents) ?? defaults.claudeHookEvents
        codexHookEvents = try c.decodeIfPresent([String: String].self, forKey: .codexHookEvents) ?? defaults.codexHookEvents
        activeLayoutID = try c.decodeIfPresent(String.self, forKey: .activeLayoutID) ?? defaults.activeLayoutID
        customLayouts = try c.decodeIfPresent([KeyboardLayout].self, forKey: .customLayouts) ?? defaults.customLayouts
        layoutSettings = try c.decodeIfPresent([String: LayoutSettings].self, forKey: .layoutSettings) ?? defaults.layoutSettings
        fleetExclusions = try c.decodeIfPresent([String].self, forKey: .fleetExclusions) ?? defaults.fleetExclusions
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? defaults.appearance
        macNotificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .macNotificationsEnabled) ?? defaults.macNotificationsEnabled
        promptSnippets = try c.decodeIfPresent([PromptSnippet].self, forKey: .promptSnippets) ?? defaults.promptSnippets
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? defaults.onboardingComplete
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? defaults.deviceName
        steadyGlow = try c.decodeIfPresent(Bool.self, forKey: .steadyGlow) ?? defaults.steadyGlow
        savedDeviceLights = try c.decodeIfPresent([String: String].self, forKey: .savedDeviceLights)
    }
}

/// Loads/saves AppConfig as JSON. Pure logic, path injected for testability;
/// the app passes ~/Library/Application Support/MegaMicro/config.json.
final class ConfigStore {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MegaMicro/config.json")
    }

    func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return AppConfig() }
        let decoder = JSONDecoder()
        var config = (try? decoder.decode(AppConfig.self, from: data)) ?? AppConfig()
        migrate(&config)
        return config
    }

    /// Built-in profiles and default trigger bindings evolve with the app
    /// (layout corrections, animation tuning). Refresh them when the stored
    /// config predates the current version; user-created profiles, pins, and
    /// key labels are untouched.
    private func migrate(_ config: inout AppConfig) {
        guard config.version < AppConfig.currentVersion else { return }
        if config.version < 2 {
            let builtinIDs = Set(DefaultProfiles.all.map(\.id))
            config.profiles = DefaultProfiles.all + config.profiles.filter { !builtinIDs.contains($0.id) }
            config.triggerBindings = DefaultTriggers.codexMicro
        }
        if config.version < 3 {
            // Workspace pins become key bindings (key-centric model).
            for (workspace, slot) in config.workspaceKeyPins {
                config.keyBindings[slot] = .workspace(workspace)
            }
            config.workspaceKeyPins = [:]
        }
        if config.version < 30 {
            // The Creator Micro 2 encoder can only emit a bare keycode, so the
            // dial moved off its Hyper+F18/F19/F20 chords onto plain F18–F20.
            // Without this the dial's keystrokes match nothing and escape to
            // macOS instead of driving the mapped action.
            config.triggerBindings = DefaultTriggers.codexMicro
        }
        if config.version < 13 {
            // Template values are now supplied as a follow-up message. Remove
            // the former placeholder sections from built-ins while preserving
            // any other text the user may have edited.
            let obsoleteSections = [
                "Request:\n{{request}}\n\n",
                "Original request:\n{{request}}\n\n",
                "Project:\n{{project}}\n\n",
                "Assigned track:\n{{track}}\n\n",
                "Plan location:\n{{plan_path}}\n\n",
            ]
            for index in config.promptSnippets.indices where config.promptSnippets[index].builtIn {
                for section in obsoleteSections {
                    config.promptSnippets[index].prompt =
                        config.promptSnippets[index].prompt.replacingOccurrences(of: section, with: "")
                }
                config.promptSnippets[index].prompt =
                    config.promptSnippets[index].prompt.replacingOccurrences(
                        of: "Create a planning folder in the repository containing:",
                        with: "Create a planning folder named MegaPlan in the repository containing:")
            }
        }
        if config.version < 14,
           let index = config.promptSnippets.firstIndex(where: {
               $0.id == DefaultPromptSnippets.planner.id && $0.builtIn
           }) {
            config.promptSnippets[index] = DefaultPromptSnippets.planner
        }
        if config.version < 15,
           let index = config.promptSnippets.firstIndex(where: {
               $0.id == DefaultPromptSnippets.worker.id && $0.builtIn
           }) {
            config.promptSnippets[index] = DefaultPromptSnippets.worker
        }
        if config.version < 16,
           let index = config.promptSnippets.firstIndex(where: {
               $0.id == DefaultPromptSnippets.integrator.id && $0.builtIn
           }) {
            config.promptSnippets[index] = DefaultPromptSnippets.integrator
        }
        if config.version < 17,
           let index = config.promptSnippets.firstIndex(where: {
               $0.id == DefaultPromptSnippets.planner.id && $0.builtIn
           }) {
            config.promptSnippets[index] = DefaultPromptSnippets.planner
        }
        if config.version < 18 {
            // Built-in source text is now unwrapped into semantic paragraphs
            // so TextEditor performs the only visible line wrapping.
            let defaults = Dictionary(
                uniqueKeysWithValues: DefaultPromptSnippets.all.map { ($0.id, $0) })
            for index in config.promptSnippets.indices
            where config.promptSnippets[index].builtIn {
                if let updated = defaults[config.promptSnippets[index].id] {
                    config.promptSnippets[index] = updated
                }
            }
        }
        if config.version < 19,
           !config.promptSnippets.contains(where: {
               $0.id == DefaultPromptSnippets.howThisWorks.id
           }) {
            config.promptSnippets.insert(DefaultPromptSnippets.howThisWorks, at: 0)
        }
        if config.version < 20 {
            let updated = [
                DefaultPromptSnippets.howThisWorks.id: DefaultPromptSnippets.howThisWorks,
                DefaultPromptSnippets.planner.id: DefaultPromptSnippets.planner,
                DefaultPromptSnippets.worker.id: DefaultPromptSnippets.worker,
            ]
            for index in config.promptSnippets.indices
            where config.promptSnippets[index].builtIn {
                if let snippet = updated[config.promptSnippets[index].id] {
                    config.promptSnippets[index] = snippet
                }
            }
        }
        if config.version < 21 {
            let updated = [
                DefaultPromptSnippets.howThisWorks.id: DefaultPromptSnippets.howThisWorks,
                DefaultPromptSnippets.planner.id: DefaultPromptSnippets.planner,
                DefaultPromptSnippets.integrator.id: DefaultPromptSnippets.integrator,
            ]
            for index in config.promptSnippets.indices
            where config.promptSnippets[index].builtIn {
                if let snippet = updated[config.promptSnippets[index].id] {
                    config.promptSnippets[index] = snippet
                }
            }
        }
        if config.version < 22 {
            let updated = [
                DefaultPromptSnippets.howThisWorks.id: DefaultPromptSnippets.howThisWorks,
                DefaultPromptSnippets.worker.id: DefaultPromptSnippets.worker,
            ]
            for index in config.promptSnippets.indices
            where config.promptSnippets[index].builtIn {
                if let snippet = updated[config.promptSnippets[index].id] {
                    config.promptSnippets[index] = snippet
                }
            }
        }
        if config.version < 23 {
            let updated = [
                DefaultPromptSnippets.planner.id: DefaultPromptSnippets.planner,
                DefaultPromptSnippets.worker.id: DefaultPromptSnippets.worker,
                DefaultPromptSnippets.integrator.id: DefaultPromptSnippets.integrator,
            ]
            for index in config.promptSnippets.indices
            where config.promptSnippets[index].builtIn {
                if let snippet = updated[config.promptSnippets[index].id] {
                    config.promptSnippets[index] = snippet
                }
            }
        }
        if config.version < 24,
           let index = config.promptSnippets.firstIndex(where: {
               $0.id == DefaultPromptSnippets.howThisWorks.id && $0.builtIn
           }) {
            config.promptSnippets[index] = DefaultPromptSnippets.howThisWorks
        }
        if config.version < 25 {
            let defaults = Dictionary(
                uniqueKeysWithValues: DefaultPromptSnippets.all.map { ($0.id, $0) })
            for index in config.promptSnippets.indices
            where config.promptSnippets[index].builtIn {
                if let updated = defaults[config.promptSnippets[index].id] {
                    config.promptSnippets[index] = updated
                }
            }
        }
        if config.version < 26 {
            let defaults = Dictionary(
                uniqueKeysWithValues: DefaultPromptSnippets.all.map { ($0.id, $0) })
            for index in config.promptSnippets.indices
            where config.promptSnippets[index].builtIn {
                if let updated = defaults[config.promptSnippets[index].id] {
                    config.promptSnippets[index] = updated
                }
            }
        }
        if config.version < 27 {
            let defaults = Dictionary(
                uniqueKeysWithValues: DefaultPromptSnippets.all.map { ($0.id, $0) })
            for index in config.promptSnippets.indices
            where config.promptSnippets[index].builtIn {
                if let updated = defaults[config.promptSnippets[index].id] {
                    config.promptSnippets[index] = updated
                }
            }
        }
        if config.version < 28,
           let index = config.promptSnippets.firstIndex(where: {
               $0.id == DefaultPromptSnippets.howThisWorks.id && $0.builtIn
           }) {
            config.promptSnippets[index] = DefaultPromptSnippets.howThisWorks
        }
        if config.version < 29,
           let index = config.promptSnippets.firstIndex(where: {
               $0.id == DefaultPromptSnippets.howThisWorks.id && $0.builtIn
           }) {
            config.promptSnippets[index] = DefaultPromptSnippets.howThisWorks
        }
        if config.version < 4 {
            // Key 10 is the dedicated profile-switch key in every profile.
            for index in config.profiles.indices {
                config.profiles[index].mappings[.key(10), default: [:]][.press] = .cycleProfile
            }
        }
        if config.version < 5 {
            // Key bindings/legends become per-layout (Codex Micro was the
            // only layout before v5).
            var settings = config.layoutSettings["codex-micro"] ?? LayoutSettings()
            settings.keyBindings.merge(config.keyBindings) { existing, _ in existing }
            settings.keyLegends.merge(config.keyLegends) { existing, _ in existing }
            config.layoutSettings["codex-micro"] = settings
            config.keyBindings = [:]
            config.keyLegends = [:]
        }
        if config.version < 6 {
            // Agents self-announce at boot via SessionStart.
            config.claudeHookEvents["SessionStart"] = config.claudeHookEvents["SessionStart"] ?? "idle"
            config.codexHookEvents["SessionStart"] = config.codexHookEvents["SessionStart"] ?? "idle"
        }
        if config.version < 7 {
            // The wide bottom key is the Talk key (push-to-talk ⌘Z hold) in
            // every profile; the mic glyph now comes from the layout, so a
            // legacy "Talk" text label is retired.
            let talk = Action.holdKeystroke(
                chord: KeyChord(keyCode: KeyCodes.z, modifiers: .command), target: .frontmost)
            for index in config.profiles.indices {
                config.profiles[index].mappings[.key(11), default: [:]][.press] = talk
            }
            for (layoutID, var settings) in config.layoutSettings {
                if settings.keyLegends[.key(11)] == "Talk" {
                    settings.keyLegends.removeValue(forKey: .key(11))
                    config.layoutSettings[layoutID] = settings
                }
            }
        }
        if config.version < 8 {
            // Agent keys (0–5) carry agent state, not app shortcuts: clear
            // legacy keystroke defaults from the built-in profiles.
            let builtinIDs = Set(DefaultProfiles.all.map(\.id))
            for index in config.profiles.indices where builtinIDs.contains(config.profiles[index].id) {
                for slot in 0..<6 {
                    config.profiles[index].mappings[.key(slot)]?[.press] = nil
                    if config.profiles[index].mappings[.key(slot)]?.isEmpty == true {
                        config.profiles[index].mappings.removeValue(forKey: .key(slot))
                    }
                }
            }
        }
        if config.version < 10,
           !config.profiles.contains(where: { $0.id == DefaultProfiles.iTerm2.id }) {
            config.profiles.append(DefaultProfiles.iTerm2)
        }
        if config.version < 11 {
            let additions = [DefaultProfiles.cursor, DefaultProfiles.vsCode, DefaultProfiles.warp,
                             DefaultProfiles.kitty, DefaultProfiles.wezTerm]
            for profile in additions where !config.profiles.contains(where: { $0.id == profile.id }) {
                config.profiles.append(profile)
            }
        }
        if config.version < 31,
           !config.profiles.contains(where: { $0.id == DefaultProfiles.mosaic.id }) {
            config.profiles.append(DefaultProfiles.mosaic)
        }
        config.version = AppConfig.currentVersion
    }

    func save(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try PrivateFileStore.write(data, to: fileURL)
    }
}
