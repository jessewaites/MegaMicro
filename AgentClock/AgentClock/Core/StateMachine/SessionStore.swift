import Foundation

struct AgentSession: Sendable, Codable {
    var source: String
    var session: String
    var cwd: String?
    var state: AgentState
    var updatedAt: Date
    var agent: String?
    var parentSession: String?
    var model: String?
    var task: String?
    var terminalSession: String?
    var terminalKind: String?
    var terminalEndpoint: String?
    var startedAt: Date

    var key: String { "\(source)#\(session)" }

    // Encode `state` by wire name so GET /sessions is human-readable.
    enum CodingKeys: String, CodingKey {
        case source, session, cwd, state, updatedAt, agent, parentSession, model, task
        case terminalSession, terminalKind, terminalEndpoint, startedAt
    }

    init(source: String, session: String, cwd: String?, state: AgentState, updatedAt: Date,
         agent: String? = nil, parentSession: String? = nil, model: String? = nil,
         terminalSession: String? = nil, terminalKind: String? = nil,
         terminalEndpoint: String? = nil) {
        self.source = source
        self.session = session
        self.cwd = cwd
        self.state = state
        self.updatedAt = updatedAt
        self.agent = agent
        self.parentSession = parentSession
        self.model = model
        self.task = nil
        self.terminalSession = terminalSession
        self.terminalKind = terminalKind
        self.terminalEndpoint = terminalEndpoint
        self.startedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        session = try container.decode(String.self, forKey: .session)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        parentSession = try container.decodeIfPresent(String.self, forKey: .parentSession)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        task = try container.decodeIfPresent(String.self, forKey: .task)
        terminalSession = try container.decodeIfPresent(String.self, forKey: .terminalSession)
        terminalKind = try container.decodeIfPresent(String.self, forKey: .terminalKind)
        terminalEndpoint = try container.decodeIfPresent(String.self, forKey: .terminalEndpoint)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? updatedAt
        let name = try container.decode(String.self, forKey: .state)
        state = AgentState(wireName: name) ?? .idle
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(session, forKey: .session)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encode(state.wireName, forKey: .state)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(agent, forKey: .agent)
        try container.encodeIfPresent(parentSession, forKey: .parentSession)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(task, forKey: .task)
        try container.encodeIfPresent(terminalSession, forKey: .terminalSession)
        try container.encodeIfPresent(terminalKind, forKey: .terminalKind)
        try container.encodeIfPresent(terminalEndpoint, forKey: .terminalEndpoint)
        try container.encode(startedAt, forKey: .startedAt)
    }
}

/// Tracks every agent session that has reported state and resolves what the
/// board should display. Pure Swift, fully unit-tested; callers own threading.
final class SessionStore {
    static let maximumSessions = 256
    /// success reverts to idle after this long (the green "done" fade window).
    var successTTL: TimeInterval = 45
    /// Non-idle sessions silent for this long are dropped.
    var staleTTL: TimeInterval = 60 * 60
    /// Idle sessions (including restored roster entries) linger this long
    /// since their last real activity, then drop. One hour: an agent you
    /// haven't touched since lunch shouldn't haunt the evening's fleet.
    var idleTTL: TimeInterval = 60 * 60

    private(set) var sessions: [String: AgentSession] = [:]

    /// Manual dismissal (user clicked ✕ on a stuck/finished agent).
    func remove(sessionKey: String) {
        sessions.removeValue(forKey: sessionKey)
    }

    /// Clean slate (Unassign All): forget every session. Live agents
    /// re-announce themselves on their next hook event.
    func removeAll() {
        sessions.removeAll()
    }

    /// Restore a persisted roster (app relaunch). Live states are demoted to
    /// idle — we can't know what an agent did while we were gone — but the
    /// agents stay visible instead of vanishing until their next report.
    func restore(_ persisted: [AgentSession]) {
        for var session in persisted where sessions[session.key] == nil {
            session.state = .idle
            sessions[session.key] = session
        }
    }

    func apply(_ event: SessionEvent) {
        var session = AgentSession(
            source: event.source,
            session: event.session,
            cwd: event.cwd,
            state: event.state,
            updatedAt: event.at,
            agent: event.agent,
            parentSession: event.parentSession,
            model: event.model,
            terminalSession: event.terminalSession,
            terminalKind: event.terminalKind,
            terminalEndpoint: event.terminalEndpoint)
        if let previous = sessions[session.key] {
            session.startedAt = previous.startedAt
            session.agent = event.agent ?? previous.agent
            session.parentSession = event.parentSession ?? previous.parentSession
            session.model = event.model ?? previous.model
            session.task = event.task ?? previous.task
            session.terminalSession = event.terminalSession ?? previous.terminalSession
            session.terminalKind = event.terminalKind ?? previous.terminalKind
            session.terminalEndpoint = event.terminalEndpoint ?? previous.terminalEndpoint
        } else {
            session.task = event.task
        }
        sessions[session.key] = session
        if sessions.count > Self.maximumSessions {
            // Prefer discarding the oldest quiet session. If every agent is
            // active, still enforce the hard memory/roster bound.
            let victim = sessions.values.min {
                let lhsIdle = $0.state == .idle || $0.state == .success
                let rhsIdle = $1.state == .idle || $1.state == .success
                return lhsIdle == rhsIdle ? $0.updatedAt < $1.updatedAt : lhsIdle
            }
            if let victim, victim.key != session.key { sessions.removeValue(forKey: victim.key) }
            else if let oldest = sessions.values.min(by: { $0.updatedAt < $1.updatedAt }) {
                sessions.removeValue(forKey: oldest.key)
            }
        }
    }

    /// Age out finished/silent sessions. Call before resolving.
    func expire(now: Date) {
        for (key, s) in sessions {
            if s.state == .success, now.timeIntervalSince(s.updatedAt) > successTTL {
                sessions[key]?.state = .idle
            }
            let silence = now.timeIntervalSince(s.updatedAt)
            let limit = (sessions[key]?.state == .idle) ? idleTTL : staleTTL
            if silence > limit {
                sessions.removeValue(forKey: key)
            }
        }
    }

    /// Highest-priority state across all sessions (whole-board resolution).
    func resolvedGlobal(now: Date) -> AgentState {
        expire(now: now)
        return sessions.values.map(\.state).max() ?? .idle
    }

    /// Highest-priority state among sessions whose cwd lives under `pathPrefix`
    /// (per-key resolution for pinned Conductor workspaces).
    func resolved(underPath pathPrefix: String, now: Date) -> AgentState {
        expire(now: now)
        let normalized = pathPrefix.hasSuffix("/") ? pathPrefix : pathPrefix + "/"
        return sessions.values
            .filter { s in
                guard let cwd = s.cwd else { return false }
                return cwd == pathPrefix || cwd.hasPrefix(normalized)
            }
            .map(\.state)
            .max() ?? .idle
    }

    /// Most recent update time for the session(s) currently at the resolved
    /// state — used to compute animation age (e.g. success fade progress).
    func resolvedStateAge(now: Date) -> TimeInterval {
        let state = resolvedGlobal(now: now)
        let newest = sessions.values
            .filter { $0.state == state }
            .map(\.updatedAt)
            .max()
        guard let newest else { return 0 }
        return now.timeIntervalSince(newest)
    }
}
