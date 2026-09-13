import Foundation

/// Installs Claude Code lifecycle hooks into ~/.claude/settings.json so every
/// Claude Code session on the machine — inside Conductor workspaces or Ghostty
/// terminals — reports its state to AgentClock's webhook.
///
/// Safety rules:
/// - The file is parsed with JSONSerialization and re-written whole, so keys
///   AgentClock doesn't know about are preserved untouched.
/// - A timestamped backup is written before every modification.
/// - Every installed command ends with the `#agentclock` marker; uninstall
///   removes exactly the entries carrying the marker and nothing else.
/// - Install is uninstall-then-add, so it is idempotent.
final class HooksInstaller {
    static let marker = "#agentclock"
    enum InstallError: LocalizedError {
        case malformedSettings
        var errorDescription: String? { "Claude settings.json is malformed; AgentClock left it untouched." }
    }

    let settingsURL: URL
    let backupDir: URL
    let port: UInt16
    let bridgeURL: URL?

    init(settingsURL: URL, backupDir: URL, port: UInt16, bridgeURL: URL? = nil) {
        self.settingsURL = settingsURL
        self.backupDir = backupDir
        self.port = port
        self.bridgeURL = bridgeURL
    }

    convenience init(port: UInt16) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(
            settingsURL: home.appendingPathComponent(".claude/settings.json"),
            backupDir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentClock/backups"),
            port: port)
    }

    /// Hook events → the agent state they report. Only documented Claude Code
    /// events; error states can still arrive via other webhook clients.
    struct HookSpec {
        let event: String
        let state: String
        let matcher: String?
    }

    /// Event → state, injectable so the mapping lives in user config and
    /// survives future Claude Code releases renaming or adding events.
    var eventStates: [String: String] = HookEvents.claude

    var specs: [HookSpec] {
        eventStates
            .sorted { $0.key < $1.key }
            .map { event, state in
                // Tool events take a matcher; "*" = all tools.
                HookSpec(event: event, state: state,
                         matcher: event.hasSuffix("ToolUse") ? "*" : nil)
            }
    }

    /// The shell command a hook runs. `session` falls back to $PWD so two
    /// workspaces never collide on one session key; `-m 2` + `|| true` mean a
    /// stopped AgentClock can never block or slow Claude Code.
    func command(state: String) -> String {
        let event = ["idle": "SessionStart", "thinking": "UserPromptSubmit", "coding": "PreToolUse",
                     "waiting": "PermissionRequest", "success": "Stop", "error": "StopFailure"][state] ?? state
        return command(event: event)
    }

    private func command(event: String) -> String {
        BridgeLocator.command(provider: "claude", event: event, port: port, url: bridgeURL)
    }

    // MARK: Status

    func isInstalled() -> Bool {
        let settings = loadSettings()
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains(where: entryHasMarker)
        }
    }

    // MARK: Install / uninstall

    func install() throws {
        var settings = try loadSettingsForMutation()
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        stripMarkedEntries(from: &hooks)

        for spec in specs {
            var entry: [String: Any] = [
                "hooks": [["type": "command", "command": command(event: spec.event), "timeout": 2]]
            ]
            if let matcher = spec.matcher { entry["matcher"] = matcher }
            var entries = (hooks[spec.event] as? [[String: Any]]) ?? []
            entries.append(entry)
            hooks[spec.event] = entries
        }
        settings["hooks"] = hooks
        try write(settings)
    }

    func uninstall() throws {
        var settings = try loadSettingsForMutation()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        stripMarkedEntries(from: &hooks)
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try write(settings)
    }

    // MARK: Internals

    private func entryHasMarker(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String)?.contains(Self.marker) == true }
    }

    private func stripMarkedEntries(from hooks: inout [String: Any]) {
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !entryHasMarker($0) }
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
    }

    private func loadSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private func loadSettingsForMutation() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: settingsURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.malformedSettings
        }
        return dict
    }

    private func write(_ settings: [String: Any]) throws {
        // Backup the existing file before touching it.
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backupURL = backupDir.appendingPathComponent("settings-\(stamp).json")
            try? PrivateFileStore.backup(settingsURL, to: backupURL)
            PrivateFileStore.pruneBackups(in: backupDir, prefix: "settings-")
        }
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try PrivateFileStore.write(data, to: settingsURL)
    }
}
