import AppKit
import Foundation

protocol ProviderIntegration {
    var id: String { get }
    var displayName: String { get }
    var isDetected: Bool { get }
    func isInstalled() -> Bool
    func install() throws
    func uninstall() throws
}

extension HooksInstaller: ProviderIntegration {
    var id: String { "claude-code" }
    var displayName: String { "Claude Code" }
    var isDetected: Bool { FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path) || executableExists(["claude"]) }
}

extension CodexHooksInstaller: ProviderIntegration {
    var id: String { "codex" }
    var displayName: String { "Codex CLI" }
    var isDetected: Bool { codexInstalled }
}

extension AntigravityHooksInstaller: ProviderIntegration {
    var id: String { "antigravity-cli" }
    var displayName: String { "Antigravity CLI" }
}

private func executableExists(_ names: [String]) -> Bool {
    let roots = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
    return roots.contains { root in names.contains { FileManager.default.isExecutableFile(atPath: root + "/" + $0) } }
}

final class OpenCodeIntegration: ProviderIntegration {
    let id = "opencode"
    let displayName = "OpenCode"
    let pluginURL: URL
    let port: UInt16
    var isDetected: Bool {
        executableExists(["opencode"])
            || FileManager.default.fileExists(atPath: pluginURL.deletingLastPathComponent().deletingLastPathComponent().path)
            || ["ai.opencode.desktop", "ai.opencode.desktop.beta", "ai.opencode.desktop.dev"]
                .contains(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
    }

    init(pluginURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/opencode/plugins/agentclock.ts"), port: UInt16) {
        self.pluginURL = pluginURL; self.port = port
    }
    func isInstalled() -> Bool { FileManager.default.fileExists(atPath: pluginURL.path) }
    func install() throws {
        let source = """
        // AgentClock lifecycle telemetry. This file is owned by AgentClock.
        import type { Plugin } from "@opencode-ai/plugin"

        export const AgentClock: Plugin = async ({ directory }) => ({
          event: async ({ event }) => {
            const e: any = event
            const p: any = e.properties ?? e.payload ?? e
            const type: string = e.type ?? ""
            const states: Record<string, string> = {
              "session.created": "thinking",
              "session.idle": "idle", "session.error": "error",
              "permission.asked": "waiting", "permission.replied": "thinking",
              "tool.execute.before": "coding", "tool.execute.after": "thinking"
            }
            const state = type === "session.status"
              ? (["idle", "completed"].includes(p.status?.type ?? p.status) ? "idle" : "thinking")
              : states[type]
            if (!state) return
            const session = p.sessionID ?? p.session_id ?? p.session?.id ?? p.id ?? `opencode-${process.pid}`
            const cwd = p.directory ?? p.cwd ?? directory
            const terminalKind = process.env.ITERM_SESSION_ID ? "iterm2"
              : process.env.WEZTERM_PANE ? "wezterm"
              : process.env.KITTY_WINDOW_ID ? "kitty"
              : process.env.TERM_PROGRAM === "vscode" ? "vscode"
              : (process.env.TERM_PROGRAM?.toLowerCase().includes("warp") || process.env.WARP_IS_LOCAL_SHELL) ? "warp"
              : undefined
            const terminalSession = process.env.ITERM_SESSION_ID ?? process.env.WEZTERM_PANE ?? process.env.KITTY_WINDOW_ID
            const terminalEndpoint = process.env.WEZTERM_UNIX_SOCKET ?? process.env.KITTY_LISTEN_ON
            try {
              await fetch("http://127.0.0.1:\(port)/state", {
                method: "POST", headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                  source: "opencode", state, session, cwd,
                  terminalSession, terminalKind, terminalEndpoint
                }),
                signal: AbortSignal.timeout(800)
              })
            } catch (_) { /* telemetry always fails open */ }
          }
        })
        """
        try PrivateFileStore.write(Data(source.utf8), to: pluginURL)
    }
    func uninstall() throws { if isInstalled() { try FileManager.default.removeItem(at: pluginURL) } }
}

final class CopilotIntegration: ProviderIntegration {
    let id = "github-copilot"
    let displayName = "GitHub Copilot CLI"
    let hooksURL: URL
    let bridgeURL: URL?
    let port: UInt16
    var isDetected: Bool { executableExists(["copilot"]) || FileManager.default.fileExists(atPath: hooksURL.deletingLastPathComponent().deletingLastPathComponent().path) }

    init(hooksURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".copilot/hooks/agentclock.json"), port: UInt16, bridgeURL: URL? = nil) {
        self.hooksURL = hooksURL; self.port = port; self.bridgeURL = bridgeURL
    }
    func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: hooksURL),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("#agentclock")
    }
    func install() throws {
        func entry(_ event: String) -> [String: Any] {
            ["type": "command", "command": BridgeLocator.command(provider: "copilot", event: event, port: port, url: bridgeURL), "timeoutSec": 2]
        }
        let events = ["sessionStart", "userPromptSubmitted", "preToolUse", "permissionRequest",
                      "postToolUse", "postToolUseFailure", "subagentStart", "subagentStop", "sessionEnd"]
        let root: [String: Any] = ["version": 1, "hooks": Dictionary(uniqueKeysWithValues: events.map { ($0, [entry($0)]) })]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try PrivateFileStore.write(data, to: hooksURL)
    }
    func uninstall() throws { if isInstalled() { try FileManager.default.removeItem(at: hooksURL) } }
}

final class CursorIntegration: ProviderIntegration {
    let id = "cursor"
    let displayName = "Cursor"
    let hooksURL: URL
    let backupDir: URL
    let bridgeURL: URL?
    let port: UInt16
    var isDetected: Bool {
        executableExists(["agent", "cursor-agent", "cursor"])
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentApps.cursorBundleID) != nil
            || FileManager.default.fileExists(atPath: hooksURL.deletingLastPathComponent().path)
    }

    init(hooksURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/hooks.json"),
         backupDir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentClock/backups"),
         port: UInt16, bridgeURL: URL? = nil) {
        self.hooksURL = hooksURL
        self.backupDir = backupDir
        self.port = port
        self.bridgeURL = bridgeURL
    }

    func isInstalled() -> Bool {
        guard let hooks = load()?["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { String(describing: $0).contains("#agentclock") }
    }

    func install() throws {
        var root = try loadForMutation()
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        removeOwned(from: &hooks)
        let events = ["sessionStart", "beforeSubmitPrompt", "preToolUse", "beforeShellExecution",
                      "afterFileEdit", "postToolUse", "stop", "sessionEnd"]
        for event in events {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            entries.append([
                "command": BridgeLocator.command(provider: "cursor", event: event, port: port, url: bridgeURL)
            ])
            hooks[event] = entries
        }
        root["version"] = root["version"] ?? 1
        root["hooks"] = hooks
        try write(root)
    }

    func uninstall() throws {
        var root = try loadForMutation()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        removeOwned(from: &hooks)
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try write(root)
    }

    private func load() -> [String: Any]? {
        guard let data = try? Data(contentsOf: hooksURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func loadForMutation() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return [:] }
        guard let root = load() else { throw CocoaError(.fileReadCorruptFile) }
        return root
    }

    private func removeOwned(from hooks: inout [String: Any]) {
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !String(describing: $0).contains("#agentclock") }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
    }

    private func write(_ root: [String: Any]) throws {
        if FileManager.default.fileExists(atPath: hooksURL.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? PrivateFileStore.backup(hooksURL, to: backupDir.appendingPathComponent("cursor-hooks-\(stamp).json"))
            PrivateFileStore.pruneBackups(in: backupDir, prefix: "cursor-hooks-")
        }
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try PrivateFileStore.write(data, to: hooksURL)
    }
}

final class QwenIntegration: ProviderIntegration {
    let id = "qwen-code"
    let displayName = "Qwen Code"
    let settingsURL: URL
    let backupDir: URL
    let bridgeURL: URL?
    let port: UInt16
    var isDetected: Bool { executableExists(["qwen", "qwen-code"]) || FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path) }

    init(settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".qwen/settings.json"),
         backupDir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentClock/backups"),
         port: UInt16, bridgeURL: URL? = nil) {
        self.settingsURL = settingsURL; self.backupDir = backupDir; self.port = port; self.bridgeURL = bridgeURL
    }
    func isInstalled() -> Bool {
        guard let root = load(), let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { String(describing: $0).contains("#agentclock") }
    }
    func install() throws {
        var root = try loadForMutation()
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        removeOwned(from: &hooks)
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                      "PostToolUseFailure", "SessionEnd"]
        for event in events {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            entries.append(["hooks": [["type": "command",
                "command": BridgeLocator.command(provider: "qwen", event: event, port: port, url: bridgeURL),
                "timeout": 2000]]])
            hooks[event] = entries
        }
        root["hooks"] = hooks
        try write(root)
    }
    func uninstall() throws {
        var root = try loadForMutation()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        removeOwned(from: &hooks)
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try write(root)
    }
    private func load() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    private func loadForMutation() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        guard let root = load() else { throw CocoaError(.fileReadCorruptFile) }
        return root
    }
    private func removeOwned(from hooks: inout [String: Any]) {
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !String(describing: $0).contains("#agentclock") }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
    }
    private func write(_ root: [String: Any]) throws {
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? PrivateFileStore.backup(settingsURL, to: backupDir.appendingPathComponent("qwen-settings-\(stamp).json"))
            PrivateFileStore.pruneBackups(in: backupDir, prefix: "qwen-settings-")
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try PrivateFileStore.write(data, to: settingsURL)
    }
}
