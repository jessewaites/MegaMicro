import Foundation

/// Lifecycle state of one AI-agent session. Raw value doubles as display
/// priority: when several sessions compete for the board, the highest wins.
enum AgentState: Int, Codable, Comparable, CaseIterable, Sendable {
    case idle = 0
    case success = 1
    case coding = 2
    case thinking = 3
    case waiting = 4
    case error = 5

    static func < (lhs: AgentState, rhs: AgentState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Wire name used by the webhook API and Claude Code hooks.
    var wireName: String {
        switch self {
        case .idle: "idle"
        case .success: "success"
        case .coding: "coding"
        case .thinking: "thinking"
        case .waiting: "waiting"
        case .error: "error"
        }
    }

    init?(wireName: String) {
        guard let match = AgentState.allCases.first(where: { $0.wireName == wireName }) else { return nil }
        self = match
    }
}

/// One state report from an agent, e.g. a Claude Code hook firing.
struct SessionEvent: Sendable {
    var source: String        // "claude-code", "codex", "shell", …
    var session: String       // agent session id, or "na"
    var cwd: String?          // working directory, used to match Conductor workspaces
    var state: AgentState
    var at: Date
    var agent: String? = nil        // custom agent/role name
    var parentSession: String? = nil
    var model: String? = nil
    var task: String? = nil
    var terminalSession: String? = nil // e.g. iTerm2's ITERM_SESSION_ID
    var terminalKind: String? = nil
    var terminalEndpoint: String? = nil
}
