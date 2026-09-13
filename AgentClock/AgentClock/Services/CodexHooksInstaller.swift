import Foundation

/// Installs Codex CLI lifecycle hooks (~/.codex/hooks.json) so Codex agents
/// report state to AgentClock's webhook, mirroring the Claude Code installer.
/// Codex's hook system (v0.114+) is feature-flagged; `codex_hooks = true`
/// must be present under [features] in ~/.codex/config.toml.
///
/// Same safety rules as the Claude installer: whole-file JSON merge that
/// preserves unknown keys, timestamped backups, every command tagged
/// `#agentclock`, idempotent install.
final class CodexHooksInstaller {
    static let marker = HooksInstaller.marker
    enum InstallError: LocalizedError {
        case malformedHooks
        var errorDescription: String? { "Codex hooks.json is malformed; AgentClock left it untouched." }
    }

    let hooksURL: URL
    let configTomlURL: URL
    let backupDir: URL
    let port: UInt16
    let bridgeURL: URL?

    init(hooksURL: URL, configTomlURL: URL, backupDir: URL, port: UInt16, bridgeURL: URL? = nil) {
        self.hooksURL = hooksURL
        self.configTomlURL = configTomlURL
        self.backupDir = backupDir
        self.port = port
        self.bridgeURL = bridgeURL
    }

    convenience init(port: UInt16) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(
            hooksURL: home.appendingPathComponent(".codex/hooks.json"),
            configTomlURL: home.appendingPathComponent(".codex/config.toml"),
            backupDir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentClock/backups"),
            port: port)
    }

    var codexInstalled: Bool {
        FileManager.default.fileExists(atPath: configTomlURL.deletingLastPathComponent().path)
    }

    /// Event → state, injectable from user config (see claudeHookEvents).
    /// Codex has no notification/waiting event as of v0.114.
    var eventStates: [String: String] = HookEvents.codex

    var specs: [HooksInstaller.HookSpec] {
        eventStates
            .sorted { $0.key < $1.key }
            .map { event, state in
                HooksInstaller.HookSpec(event: event, state: state,
                                        matcher: event.hasSuffix("ToolUse") ? "*" : nil)
            }
    }

    /// Codex runs hook commands with the session cwd as working directory and
    /// supports shell expansion, so $PWD routes state to the right key.
    /// Silent success (exit 0, no stdout) means "continue normally" for every
    /// event including Stop.
    func command(state: String) -> String {
        let event = ["idle": "SessionStart", "thinking": "UserPromptSubmit", "coding": "PreToolUse",
                     "waiting": "PermissionRequest", "success": "Stop", "error": "PostToolUseFailure"][state] ?? state
        return command(event: event)
    }

    private func command(event: String) -> String {
        BridgeLocator.command(provider: "codex", event: event, port: port, url: bridgeURL)
    }

    // MARK: Feature flag (config.toml)

    /// Best-effort TOML scan — full parsing isn't worth a dependency.
    func featureEnabled() -> Bool {
        guard let toml = try? String(contentsOf: configTomlURL, encoding: .utf8) else { return false }
        for line in toml.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("codex_hooks") {
                return trimmed.replacingOccurrences(of: " ", with: "").hasSuffix("=true")
            }
        }
        return false
    }

    func enableFeature() throws {
        var toml = (try? String(contentsOf: configTomlURL, encoding: .utf8)) ?? ""
        backup(configTomlURL)

        var lines = toml.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("codex_hooks") }) {
            lines[index] = "codex_hooks = true"
            toml = lines.joined(separator: "\n")
        } else if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) {
            lines.insert("codex_hooks = true", at: index + 1)
            toml = lines.joined(separator: "\n")
        } else {
            if !toml.isEmpty, !toml.hasSuffix("\n") { toml += "\n" }
            toml += "\n[features]\ncodex_hooks = true\n"
        }
        if let data = toml.data(using: .utf8) { try PrivateFileStore.write(data, to: configTomlURL) }
    }

    // MARK: Hooks (hooks.json)

    func isInstalled() -> Bool {
        guard let hooks = loadHooks()["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains(where: entryHasMarker)
        }
    }

    func install() throws {
        var root = try loadHooksForMutation()
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        stripMarkedEntries(from: &hooks)
        for spec in specs {
            var entry: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": command(event: spec.event),
                    "timeout": 2,
                ]]
            ]
            if let matcher = spec.matcher { entry["matcher"] = matcher }
            var entries = (hooks[spec.event] as? [[String: Any]]) ?? []
            entries.append(entry)
            hooks[spec.event] = entries
        }
        root["hooks"] = hooks
        try write(root)
    }

    func uninstall() throws {
        var root = try loadHooksForMutation()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        stripMarkedEntries(from: &hooks)
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        try write(root)
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

    private func loadHooks() -> [String: Any] {
        guard let data = try? Data(contentsOf: hooksURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private func loadHooksForMutation() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: hooksURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.malformedHooks
        }
        return dict
    }

    private func backup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = backupDir.appendingPathComponent("\(url.lastPathComponent)-\(stamp)")
        try? PrivateFileStore.backup(url, to: backupURL)
        PrivateFileStore.pruneBackups(in: backupDir, prefix: url.lastPathComponent + "-")
    }

    private func write(_ root: [String: Any]) throws {
        backup(hooksURL)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try PrivateFileStore.write(data, to: hooksURL)
    }
}
