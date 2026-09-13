import Foundation

/// Hook event → the agent state it reports, per agent CLI.
///
/// These live in user config (`AppConfig.claudeHookEvents` / `.codexHookEvents`)
/// so a future Claude Code or Codex release renaming or adding an event is a
/// config tweak rather than an app update. The bridge's own classifier is
/// deliberately fuzzy for the same reason: an event we've never heard of still
/// lands on a sensible state.
enum HookEvents {
    static let claude: [String: String] = [
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

    static let codex: [String: String] = [
        "SessionStart": "idle",
        "UserPromptSubmit": "thinking",
        "PreToolUse": "coding",
        "PostToolUse": "thinking",
        "PostToolUseFailure": "error",
        "PermissionRequest": "waiting",
        "Stop": "success",
    ]
}

/// Bundle identifiers AgentClock probes to decide whether an integration is
/// worth offering. Inlined here rather than pulled from a profile system —
/// AgentClock has no keyboard profiles.
enum AgentApps {
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"
}
