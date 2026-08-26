import AppKit
import Foundation
import Observation

/// The target of an in-progress mapping edit (drives the editor sheet).
struct EditTarget: Identifiable, Hashable {
    var control: ControlID
    var gesture: ControlGesture
    var id: String { "\(control.rawValue).\(gesture.rawValue)" }
}

/// Single source of truth for the running app.
@Observable
@MainActor
final class AppState {
    let sessionStore = SessionStore()

    /// The live instance, so the app delegate can reach it while quitting.
    /// SwiftUI owns the object; this is a weak back-reference, not ownership.
    private(set) static weak var shared: AppState?

    /// The active keyboard layout: the built-in Codex Micro or an imported
    /// custom board.
    var layout: KeyboardLayout {
        if config.activeLayoutID == CodexMicroLayout.layout.id { return CodexMicroLayout.layout }
        return config.customLayouts.first { $0.id == config.activeLayoutID } ?? CodexMicroLayout.layout
    }

    var allLayouts: [KeyboardLayout] { [CodexMicroLayout.layout] + config.customLayouts }

    /// Key bindings and keycap labels for the ACTIVE layout.
    var activeLayoutSettings: LayoutSettings {
        get { config.layoutSettings[config.activeLayoutID] ?? LayoutSettings() }
        set { config.layoutSettings[config.activeLayoutID] = newValue }
    }

    func importLayout(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            var imported = try LayoutImporter.parse(
                data: data,
                fallbackName: url.deletingPathExtension().lastPathComponent)
            while allLayouts.contains(where: { $0.id == imported.id }) {
                imported.id += "-2"
            }
            config.customLayouts.append(imported)
            config.activeLayoutID = imported.id
            log("imported layout \(imported.name): \(imported.controls.count) keys")
        } catch {
            log("layout import failed: \(error.localizedDescription)")
        }
    }

    /// Drag-and-drop agent assignment: a chip payload dropped onto a key.
    /// Payloads: "auto", "off", "workspace:<id>", "path:<dir>", "session:<key>".
    @discardableResult
    func handleAgentDrop(_ payload: String, onto control: ControlID) -> Bool {
        guard control.rawValue.hasPrefix("key."),
              let slot = Int(control.rawValue.dropFirst("key.".count)),
              let spec = layout.control(control),
              spec.ledIndex != nil, spec.hostsAgents else { return false }

        // Key-to-key move: pick up whatever occupies the source key.
        if payload.hasPrefix("move:"), let source = Int(payload.dropFirst("move:".count)) {
            guard source != slot else { return false }
            var settings = activeLayoutSettings
            if let binding = settings.keyBindings[source] {
                settings.keyBindings.removeValue(forKey: source)
                settings.keyBindings[slot] = binding
                activeLayoutSettings = settings
                log("key \(source + 1) → key \(slot + 1)")
                return true
            }
            return false
        }

        var settings = activeLayoutSettings
        switch payload {
        case "auto":
            settings.keyBindings.removeValue(forKey: slot)
        case "off":
            settings.keyBindings[slot] = .off
        default:
            if payload.hasPrefix("workspace:") {
                let id = String(payload.dropFirst("workspace:".count))
                assignWorkspace(id, to: slot, in: &settings)
            } else if payload.hasPrefix("path:") {
                settings.keyBindings[slot] = .path(String(payload.dropFirst("path:".count)))
            } else if payload.hasPrefix("session:") {
                let key = String(payload.dropFirst("session:".count))
                guard let session = sessionStore.sessions[key], let cwd = session.cwd else { return false }
                // An agent inside a Conductor workspace pins that workspace;
                // anything else pins its working folder.
                let root = workspacesRoot + "/"
                if cwd.hasPrefix(root) {
                    let parts = cwd.dropFirst(root.count).split(separator: "/")
                    if parts.count >= 2 {
                        assignWorkspace("\(parts[0])/\(parts[1])", to: slot, in: &settings)
                    } else {
                        settings.keyBindings[slot] = .path(cwd)
                    }
                } else {
                    settings.keyBindings[slot] = .path(cwd)
                }
            } else {
                return false
            }
        }
        activeLayoutSettings = settings
        log("key \(slot + 1) ← \(payload)")
        if let session = assignedSession(forSlot: slot) {
            addFeedItem(for: session, category: .presence,
                        message: "moved to Key \(slot + 1)", simulated: demoModeEnabled)
        }
        return true
    }

    /// True if the agent's folder is excluded from fleet-wide signals.
    func isExcludedFromFleet(_ session: AgentSession) -> Bool {
        guard let cwd = session.cwd else { return false }
        return config.fleetExclusions.contains { cwd == $0 || cwd.hasPrefix($0 + "/") }
    }

    func setFleetMembership(path: String, inFleet: Bool) {
        if inFleet {
            config.fleetExclusions.removeAll { $0 == path }
        } else if !config.fleetExclusions.contains(path) {
            config.fleetExclusions.append(path)
        }
    }

    /// True if this Conductor workspace's folder is excluded from the fleet.
    func isWorkspaceExcluded(_ workspace: ConductorWorkspace) -> Bool {
        let path = workspacesRoot + "/" + workspace.id
        return config.fleetExclusions.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Whether any key binding already covers this working directory.
    private func bindingCovers(cwd: String) -> Bool {
        for binding in activeLayoutSettings.keyBindings.values {
            switch binding {
            case .workspace(let id):
                let path = workspacesRoot + "/" + id
                if cwd == path || cwd.hasPrefix(path + "/") { return true }
            case .path(let p):
                if cwd == p || cwd.hasPrefix(p + "/") { return true }
            case .off:
                continue
            }
        }
        return false
    }

    /// A newly seen agent claims a free key automatically, so live sessions
    /// light up without manual placement. Skips demo casts (they own the
    /// board), agents removed from the fleet, agents already on a key, and does
    /// nothing when every key is taken (the agent waits in the chip strip).
    private func autoAssignSession(_ session: AgentSession) {
        guard !demoModeEnabled, let cwd = session.cwd else { return }
        guard !isExcludedFromFleet(session), !bindingCovers(cwd: cwd) else { return }
        // Conductor workspaces are never claimed automatically, even with a
        // live agent inside — there are always more of them than keys.
        guard !cwd.hasPrefix(workspacesRoot + "/") else { return }
        guard let slot = ledKeySlots.first(where: { activeLayoutSettings.keyBindings[$0] == nil })
        else { return }
        var settings = activeLayoutSettings
        // An agent inside a Conductor workspace pins that workspace; anything
        // else pins its working folder.
        let root = workspacesRoot + "/"
        if cwd.hasPrefix(root) {
            let parts = cwd.dropFirst(root.count).split(separator: "/")
            if parts.count >= 2 {
                assignWorkspace("\(parts[0])/\(parts[1])", to: slot, in: &settings)
            } else {
                settings.keyBindings[slot] = .path(cwd)
            }
        } else {
            settings.keyBindings[slot] = .path(cwd)
        }
        activeLayoutSettings = settings
        log("auto-assigned \(session.agent ?? session.source) → key \(slot + 1)")
    }

    /// Drag a key's agent back to the chip strip: free the slot, agent returns
    /// as a chip.
    func unassignKey(_ slot: Int) {
        guard activeLayoutSettings.keyBindings[slot] != nil else { return }
        var settings = activeLayoutSettings
        settings.keyBindings.removeValue(forKey: slot)
        activeLayoutSettings = settings
        log("key \(slot + 1) unassigned — back in the chip strip")
    }

    /// Remove an agent or workspace from monitoring (the chip's ✕): exclude its
    /// folder from the fleet so it stops signaling and won't auto-claim a key
    /// again, free any key it holds, and drop its live session so the chip
    /// clears. Re-added via the Fleet pane's membership toggle.
    func dismissAgent(payload: String) {
        if payload.hasPrefix("workspace:") {
            let id = String(payload.dropFirst("workspace:".count))
            excludeFromFleet(workspacesRoot + "/" + id)
            releaseKeys(boundTo: id)
            log("workspace \(id) removed from monitoring")
        } else if payload.hasPrefix("session:") {
            let key = String(payload.dropFirst("session:".count))
            if let cwd = sessionStore.sessions[key]?.cwd {
                excludeFromFleet(cwd)
                releaseKeysCovering(cwd: cwd)
            }
            sessionStore.remove(sessionKey: key)
            log("agent \(key) removed from monitoring")
        }
    }

    private func excludeFromFleet(_ path: String) {
        if !config.fleetExclusions.contains(path) { config.fleetExclusions.append(path) }
    }

    private func releaseKeysCovering(cwd: String) {
        var settings = activeLayoutSettings
        var changed = false
        for (slot, binding) in settings.keyBindings {
            if case .path(let p) = binding, cwd == p || cwd.hasPrefix(p + "/") {
                settings.keyBindings.removeValue(forKey: slot)
                changed = true
            }
        }
        if changed { activeLayoutSettings = settings }
    }

    /// Glyph for a key's occupant: a brand asset, an SF Symbol, or — for a
    /// Conductor workspace — the Conductor mark paired with the tool running
    /// under it (Codex/Claude).
    enum OccupantGlyph {
        case brand(String)
        case symbol(String)
        case brandPair(primary: String, secondary: String)
    }

    func occupantGlyph(forSlot slot: Int) -> OccupantGlyph? {
        func sessionGlyph(_ session: AgentSession) -> OccupantGlyph {
            BrandIcon.asset(forSource: session.source).map { .brand($0) } ?? .symbol("terminal")
        }
        switch activeLayoutSettings.keyBindings[slot] {
        case .off:
            return .symbol("moon.zzz")
        case .workspace(let id):
            // A Conductor workspace wears the Conductor mark, paired with the
            // tool running under it (Codex/Claude) when known — so the session's
            // Conductor origin and its actual agent both read at a glance.
            if let tool = conductorToolAsset(forWorkspaceID: id) {
                return .brandPair(primary: "conductor", secondary: tool)
            }
            return .brand("conductor")
        case .path(let path):
            if let session = sessionStore.sessions.values.first(where: {
                $0.cwd == path || ($0.cwd?.hasPrefix(path + "/") ?? false)
            }) {
                // Environment follows the folder: a Conductor workspace path is
                // Conductor, anything else is a standalone Ghostty terminal.
                // Pair that with the tool doing the work (Codex/Claude/…).
                let environment = path.hasPrefix(workspacesRoot + "/") ? "conductor" : "ghostty-mono"
                if let tool = BrandIcon.asset(forSource: session.source) {
                    return .brandPair(primary: environment, secondary: tool)
                }
                return .brand(environment)
            }
            // A reserved path with no live agent should read as an empty
            // agent key, not as a file-browser shortcut.
            return nil
        case nil:
            return nil
        }
    }

    /// Short display name of whatever occupies a key slot, nil if free.
    func occupantLabel(forSlot slot: Int) -> String? {
        switch activeLayoutSettings.keyBindings[slot] {
        case .off:
            return "off"
        case .workspace(let id):
            return workspaceDisplayName(forID: id)
        case .path(let path):
            // For a folder-bound agent (e.g. a Ghostty terminal), a feature
            // branch says what work is happening; default branches and non-repos
            // fall back to the folder name.
            return folderAgentLabel(forPath: path)
        case nil:
            return nil
        }
    }

    /// The branch/feature name a Conductor workspace currently shows, resolved
    /// from its stable id. Falls back to the city dir name when the workspace
    /// is no longer live (e.g. mid-archive) so labels never go blank.
    func workspaceDisplayName(forID id: String) -> String {
        if let workspace = workspaces.first(where: { $0.id == id }) {
            return workspace.displayName
        }
        return id.components(separatedBy: "/").last ?? id
    }

    /// Git branch per agent working directory — the "what's being worked on"
    /// label for a Ghostty/CLI agent bound to a folder. Observed, so views
    /// update when a branch resolves or changes.
    var cwdBranches: [String: String] = [:]
    @ObservationIgnored private var branchProbedAt: [String: Date] = [:]
    @ObservationIgnored private var lastJoystickGesture: ControlGesture?
    @ObservationIgnored private let branchTTL: TimeInterval = 10

    /// Current git branch for an agent cwd / bound folder, or nil when it isn't
    /// a repo. Returns the cached value immediately and refreshes it off the
    /// main thread when stale — never blocks or mutates observable state during
    /// a view update, so it's safe to call from label getters.
    func gitBranch(forPath path: String, now: Date = Date()) -> String? {
        if let last = branchProbedAt[path], now.timeIntervalSince(last) < branchTTL {
            return cwdBranches[path]
        }
        branchProbedAt[path] = now
        Task.detached(priority: .utility) { [weak self] in
            let branch = GitBranchResolver.branch(atPath: path)
            await MainActor.run {
                guard let self else { return }
                if let branch {
                    if self.cwdBranches[path] != branch { self.cwdBranches[path] = branch }
                } else if self.cwdBranches[path] != nil {
                    self.cwdBranches.removeValue(forKey: path)
                }
            }
        }
        return cwdBranches[path]
    }

    /// Default branches aren't distinctive — several agents on `main` would all
    /// read "main". So they're never used as a label.
    nonisolated static let defaultBranchNames: Set<String> = ["main", "master"]

    /// The decision, pure and testable: a feature branch labels the agent;
    /// a default branch or non-repo falls back to the folder name.
    nonisolated static func agentLabel(branch: String?, folder: String) -> String {
        guard let branch, !defaultBranchNames.contains(branch.lowercased()) else { return folder }
        return branch
    }

    /// Label for a folder-bound (Ghostty/CLI) agent: the git branch when it's a
    /// feature branch, otherwise the repo/folder name.
    func folderAgentLabel(forPath path: String) -> String {
        Self.agentLabel(branch: gitBranch(forPath: path),
                        folder: (path as NSString).lastPathComponent)
    }

    func assignedSession(forSlot slot: Int) -> AgentSession? {
        let path: String
        switch activeLayoutSettings.keyBindings[slot] {
        case .workspace(let id): path = workspacesRoot + "/" + id
        case .path(let assignedPath): path = assignedPath
        case nil, .off: return nil
        }
        let normalized = path.hasSuffix("/") ? path : path + "/"
        return sessionStore.sessions.values
            .filter { $0.cwd == path || ($0.cwd?.hasPrefix(normalized) ?? false) }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    /// Human-readable elapsed time since an agent session began.
    func elapsed(since start: Date, now: Date = Date()) -> String {
        let totalSeconds = Int(max(0, now.timeIntervalSince(start)))
        if totalSeconds >= 3600 {
            return "\(totalSeconds / 3600)h \((totalSeconds % 3600) / 60)m"
        } else if totalSeconds >= 60 {
            return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
        }
        return "\(totalSeconds)s"
    }

    func agentDetailText(_ session: AgentSession, now: Date = Date()) -> String {
        let project = projectName(for: session) ?? "Unknown project"
        let lastActivity = session.updatedAt.formatted(date: .omitted, time: .shortened)
        return """
        \(session.agent ?? session.source)
        Task: \(session.task ?? "Current agent session")
        Model: \(session.model ?? "Not reported")
        Project: \(project)
        State: \(session.state.wireName) · elapsed \(elapsed(since: session.startedAt, now: now))
        Last activity: \(lastActivity)
        """
    }

    func projectName(for session: AgentSession) -> String? {
        guard let cwd = session.cwd else { return nil }
        let root = workspacesRoot + "/"
        if cwd.hasPrefix(root), let project = cwd.dropFirst(root.count).split(separator: "/").first {
            return String(project)
        }
        return (cwd as NSString).lastPathComponent
    }

    /// What the agent is actually working on — the Conductor branch/feature or a
    /// Ghostty/CLI folder's git branch. This is what a human tracks, far more
    /// than the ephemeral key position.
    func workContext(for session: AgentSession) -> String? {
        guard let cwd = session.cwd else { return nil }
        let root = workspacesRoot + "/"
        if cwd.hasPrefix(root) {
            let parts = cwd.dropFirst(root.count).split(separator: "/")
            if parts.count >= 2 { return workspaceDisplayName(forID: "\(parts[0])/\(parts[1])") }
        }
        return folderAgentLabel(forPath: cwd)
    }

    private(set) var fleetNotification = FleetNotification(
        state: .idle,
        headline: "Fleet idle",
        detail: "No agents are reporting activity.",
        keySlot: nil)

    /// Snapshot of everything a synced client (iPhone/Watch) renders. The LED
    /// animation is re-derived on the client from `sessions` + `rgbRules`, so it
    /// isn't included here.
    func dashboardSnapshot() -> DashboardSnapshot {
        DashboardSnapshot(
            deviceName: config.deviceName,
            workspacesRoot: workspacesRoot,
            layoutId: layout.id,
            ledCount: layout.ledCount,
            sessions: Array(sessionStore.sessions.values),
            keyBindings: activeLayoutSettings.keyBindings,
            keyLegends: activeLayoutSettings.keyLegends,
            workspaces: workspaces,
            conductorAgents: conductorAgents,
            cwdBranches: cwdBranches,
            activityFeed: Array(activityFeed.prefix(80)),
            fleetNotification: fleetNotification,
            rgbRules: activeProfile.rgbRules,
            underglow: activeProfile.underglow,
            steadyGlow: config.steadyGlow)
    }

    /// Apply a command received from a synced client, routed to the same
    /// handlers the local UI uses.
    func applySyncCommand(_ command: SyncCommand) {
        switch command {
        case .drop(let payload, let control):
            _ = handleAgentDrop(payload, onto: ControlID(rawValue: control))
        case .unassign(let slot):
            unassignKey(slot)
        case .unassignAll:
            unassignAllKeys()
        case .dismiss(let payload):
            dismissAgent(payload: payload)
        case .focus(let slot):
            _ = focusAgent(onSlot: slot)
        }
    }

    /// Human-readable counterpart to the perimeter light. Uses the same
    /// urgency ordering as the renderer, so the sentence and RGB signal can
    /// never disagree about what needs attention most.
    private func makeFleetNotification(included: [AgentSession], state: AgentState) -> FleetNotification {
        guard let session = included.filter({ $0.state == state }).max(by: {
            $0.state == $1.state ? $0.updatedAt < $1.updatedAt : $0.state < $1.state
        }) else {
            return FleetNotification(state: .idle, headline: "Fleet idle",
                                     detail: "No agents are reporting activity.", keySlot: nil)
        }
        if session.state == .idle {
            let count = included.count
            return FleetNotification(state: .idle, headline: "Fleet idle",
                                     detail: "\(count) agent\(count == 1 ? "" : "s") connected; no action is required.",
                                     keySlot: nil)
        }
        let slot = ledKeySlots.first { assignedSession(forSlot: $0)?.key == session.key }
        let tool = session.agent ?? readableSourceName(session.source)
        // Lead with what's being worked on (branch/feature) and its state; the
        // key is the most ephemeral detail, so it goes in the info line.
        let work = workContext(for: session) ?? tool
        let (stateWord, action): (String, String) = switch session.state {
        case .error: ("error", "Needs attention — review the failure.")
        case .waiting: ("waiting", "Permission or a response is required.")
        case .thinking: ("thinking", "Planning its next step.")
        case .coding: ("working", "Actively using tools.")
        case .success: ("finished", "Completed its current task.")
        case .idle: ("idle", "No action is required.")
        }
        let keyPart = slot.map { " · Key \($0 + 1)" } ?? ""
        return FleetNotification(state: session.state,
                                 headline: "\(work) · \(tool) — \(stateWord)",
                                 detail: action + keyPart, keySlot: slot)
    }

    private func readableSourceName(_ source: String) -> String {
        let known: [String: String] = [
            "claude-code": "Claude Code", "codex": "Codex",
            "antigravity-cli": "Antigravity", "github-copilot": "GitHub Copilot",
            "opencode": "OpenCode", "cursor": "Cursor", "cline": "Cline",
            "kiro-cli": "Kiro", "roo-code": "Roo Code", "continue": "Continue",
            "goose": "Goose", "qwen-code": "Qwen Code",
        ]
        return known[source.lowercased()] ?? source
    }

    /// Clear every key binding. Keys go dark (nothing lights without an
    /// explicit assignment) and the freed agents return to the chip strip,
    /// ready to be re-placed.
    func unassignAllKeys() {
        var settings = activeLayoutSettings
        settings.keyBindings = [:]
        activeLayoutSettings = settings
        log("all agents unassigned — back in the chip strip")
    }

    private func assignWorkspace(_ id: String, to slot: Int, in settings: inout LayoutSettings) {
        for (existingSlot, binding) in settings.keyBindings {
            if case .workspace(id) = binding {
                settings.keyBindings.removeValue(forKey: existingSlot)
            }
        }
        settings.keyBindings[slot] = .workspace(id)
    }

    func deleteLayout(id: String) {
        guard id != CodexMicroLayout.layout.id else { return }
        config.customLayouts.removeAll { $0.id == id }
        config.layoutSettings.removeValue(forKey: id)
        if config.activeLayoutID == id {
            config.activeLayoutID = CodexMicroLayout.layout.id
        }
    }

    var config: AppConfig {
        didSet {
            scheduleSave()
            if config.triggerBindings != oldValue.triggerBindings {
                keystrokeListener.updateTriggers(Set(config.triggerBindings.map(\.trigger)))
            }
        }
    }

    /// Latest rendered lighting frame; the simulator UI reads this directly.
    var currentFrame: EffectFrame
    /// Aggregate agent state represented by `currentFrame`.
    private(set) var renderedFleetState: AgentState = .idle
    /// Which pane the config window shows (also driven by ⌘1–⌘9).
    var activeSection: ConfigSection = .dashboard
    /// Debug: when on, every mouse/key event reaching the app is logged to
    /// the Activity feed — proves whether input is delivered at all.
    /// Enable with: open MegaMicro.app --args -inputDebug YES
    var inputDebug = UserDefaults.standard.bool(forKey: "inputDebug")
    /// Edit mode: clicking a control opens the mapping editor.
    /// Simulate mode: clicking a control fires its mapped action.
    var editMode = true
    var editTarget: EditTarget?
    /// Key whose glyph is being picked (right-click on the Agents board).
    var glyphTarget: ControlID?
    var activityLog: [String] = []
    var activityFeed: [ActivityFeedItem] = []
    var deviceConnected = false

    /// Film-friendly synthetic fleet. Demo sessions are kept separate from
    /// real reports and removed (with the user's key map restored) on stop.
    var demoModeEnabled = false
    @ObservationIgnored private var demoTimer: Timer?
    @ObservationIgnored private var demoTick = 0
    @ObservationIgnored private var preDemoLayoutSettings: LayoutSettings?
    /// Deliberately paced for narrated product videos.
    private static let demoStepDuration: TimeInterval = 4.0
    private static let demoCastDuration = 12
    /// How many ticks each scene holds before the peak advances (≈8s).
    private static let demoTicksPerScene = 2
    /// The demo runs as a sequence of "scenes", each with a peak state. The
    /// whole fleet's aggregate — which drives the perimeter underglow and the
    /// whole-board glow — is the highest-priority state present, so a scene's
    /// peak becomes the halo colour only if no agent exceeds it. We therefore
    /// cap every agent at the scene peak and let the rest fan out to calmer
    /// states below it: the halo cleanly cycles idle → thinking → coding →
    /// waiting → success → error while individual keys still show variety.
    /// Order is a narrative arc — rest, ramp up, resolve, a dramatic error
    /// beat — that loops back to a calm idle.
    private static let demoStateParade: [AgentState] = [
        .idle, .thinking, .coding, .waiting, .success, .error,
    ]

    private struct DemoAgent {
        enum Environment { case conductor, ghostty }
        let source: String
        let name: String
        let model: String
        let environment: Environment
        /// Feature branch (Conductor) or project folder (Ghostty) — the label a
        /// human tracks.
        let work: String
        var session: String {
            "megamicro-demo-\(environment == .conductor ? "cnd" : "gst")-\(work)"
        }
        /// Conductor agents live under the workspaces root (so the key badges
        /// the Conductor mark); Ghostty agents live in a plain folder.
        var cwd: String {
            switch environment {
            case .conductor: NSHomeDirectory() + "/conductor/workspaces/DemoProject/\(work)"
            case .ghostty: "/tmp/MegaMicro Demo/\(work)"
            }
        }
        var task: String { "Working on \(work)" }
    }

    /// Eight so the six keys fill up with two agents left over on the chip strip
    /// — enough to show overflow rotating onto the board. The cast is accurate:
    /// Conductor only runs its four harnesses (Claude Code, Codex, Cursor,
    /// OpenCode); Ghostty runs any CLI (Gemini, Qwen, Goose, …). Real fleets
    /// stay uncapped.
    private static let demoAgents: [DemoAgent] = [
        .init(source: "claude-code", name: "Claude Code", model: "Claude Opus 4.8",
              environment: .conductor, work: "add-auth-flow"),
        .init(source: "codex", name: "Codex", model: "GPT-5.5",
              environment: .conductor, work: "fix-payment-bug"),
        .init(source: "cursor", name: "Cursor", model: "Auto",
              environment: .conductor, work: "refactor-api"),
        .init(source: "opencode", name: "OpenCode", model: "Auto",
              environment: .conductor, work: "update-deps"),
        .init(source: "gemini-cli", name: "Gemini", model: "Gemini 3 Pro",
              environment: .ghostty, work: "web-scraper"),
        .init(source: "qwen", name: "Qwen", model: "Qwen3 Coder",
              environment: .ghostty, work: "data-pipeline"),
        .init(source: "goose", name: "Goose", model: "Auto",
              environment: .ghostty, work: "cli-tool"),
        .init(source: "claude-code", name: "Claude Code", model: "Claude Opus 4.8",
              environment: .ghostty, work: "notes-app"),
    ]

    func toggleDemoMode() {
        demoModeEnabled ? stopDemoMode() : startDemoMode()
    }

    func startDemoMode() {
        guard !demoModeEnabled else { return }
        demoModeEnabled = true
        demoTick = 0
        preDemoLayoutSettings = activeLayoutSettings

        // Announce the entire cast immediately. Six occupy the board; the
        // rest appear as draggable chips and rotate onto the board later.
        for agent in Self.demoAgents {
            applySessionEvent(SessionEvent(
                source: agent.source, session: agent.session, cwd: agent.cwd,
                state: .idle, at: Date(), agent: agent.name, model: agent.model,
                task: agent.task), simulated: true, recordActivity: false)
        }
        mapDemoPage(0)
        advanceDemoMode()

        let timer = Timer(timeInterval: Self.demoStepDuration, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceDemoMode() }
        }
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
        activeSection = .agents
        log("🎬 demo mode started — synthetic agents only")
    }

    func stopDemoMode() {
        guard demoModeEnabled else { return }
        demoTimer?.invalidate()
        demoTimer = nil
        for agent in Self.demoAgents {
            sessionStore.remove(sessionKey: "\(agent.source)#\(agent.session)")
        }
        if let saved = preDemoLayoutSettings { activeLayoutSettings = saved }
        preDemoLayoutSettings = nil
        demoModeEnabled = false
        log("🎬 demo mode stopped — real fleet restored")
    }

    /// Immediately rotates the visible six-agent cast; also exposed in the
    /// menu for getting a different shot without waiting for choreography.
    func nextDemoCast() {
        guard demoModeEnabled else { return }
        demoTick += Self.demoCastDuration
        mapDemoPage(demoTick / Self.demoCastDuration)
        advanceDemoMode()
    }

    private func mapDemoPage(_ page: Int) {
        guard !Self.demoAgents.isEmpty else { return }
        var settings = activeLayoutSettings
        // Only replace demo bindings. A manual drag to a non-demo folder is
        // respected while the choreography keeps running.
        let demoPaths = Set(Self.demoAgents.map(\.cwd))
        settings.keyBindings = settings.keyBindings.filter {
            if case .path(let path) = $0.value { return !demoPaths.contains(path) }
            return true
        }
        for (offset, slot) in ledKeySlots.enumerated() {
            let agent = Self.demoAgents[(page * ledKeySlots.count + offset) % Self.demoAgents.count]
            settings.keyBindings[slot] = .path(agent.cwd)
        }
        activeLayoutSettings = settings
    }

    private func advanceDemoMode() {
        guard demoModeEnabled else { return }
        let now = Date()
        let parade = Self.demoStateParade
        // The current scene's peak state advances one step every few ticks.
        let scene = (demoTick / Self.demoTicksPerScene) % parade.count
        let peak = parade[scene]
        // Every state at or below the peak's display priority is fair game for
        // the rest of the fleet, so the halo (aggregate = max) stays at `peak`.
        let palette = parade.filter { $0.rawValue <= peak.rawValue }
        for (index, agent) in Self.demoAgents.enumerated() {
            // Fan each agent across the allowed palette, stepping every tick so
            // keys shimmer with variety. Because `palette` always includes the
            // peak, at least two agents land on it — pinning the aggregate to
            // the scene colour without any single key being stuck.
            let state = palette[(demoTick + index) % palette.count]
            applySessionEvent(SessionEvent(
                source: agent.source, session: agent.session, cwd: agent.cwd,
                state: state, at: now, agent: agent.name, model: agent.model,
                task: agent.task), simulated: true)
        }
        demoTick += 1
        if demoTick.isMultiple(of: Self.demoCastDuration) {
            mapDemoPage(demoTick / Self.demoCastDuration)
        }
    }

    let device: KeyboardDevice
    var workspacesRoot = NSHomeDirectory() + "/conductor/workspaces"

    /// Called in simulate mode / by the event tap (M5) to run an action.
    /// Replaced by ExecutionEngine in M5; logs-only until then.
    var performAction: (Action) -> Void = { _ in }

    private let configStore: ConfigStore
    private var renderTimer: Timer?
    private var saveTask: Task<Void, Never>?
    private var webhookServer: WebhookServer?
    var webhookError: String?

    @ObservationIgnored private let executionEngine = ExecutionEngine()
    @ObservationIgnored private let keystrokeListener = KeystrokeListener()
    @ObservationIgnored private let appTracker = FrontmostAppTracker()
    @ObservationIgnored private let agentFocusService = AgentFocusService()
    @ObservationIgnored private let macNotificationService = MacNotificationService()
    var listenerMode: KeystrokeListener.Mode = .off
    var accessibilityGranted = false
    var inputMonitoringGranted = false

    init(configStore: ConfigStore = ConfigStore(fileURL: ConfigStore.defaultURL)) {
        self.configStore = configStore
        self.config = configStore.load()
        self.device = MockDevice(layout: CodexMicroLayout.layout)
        self.currentFrame = .uniform(.off, ledCount: CodexMicroLayout.layout.ledCount)
        PrivateFileStore.hardenExistingTree(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MegaMicro"))
        // Repairs an installed bridge left non-executable by an earlier build,
        // which would otherwise fail every hook on the machine with
        // "Permission denied" until hooks were reinstalled by hand. Idempotent
        // — it rewrites only when the bundled bridge actually differs.
        try? BridgeLocator.ensureInstalled()
        // Subsystem kill-switches for fault isolation:
        //   open MegaMicro.app --args -disable render,input,webhook,watcher
        let disabled = Set((UserDefaults.standard.string(forKey: "disable") ?? "")
            .split(separator: ",").map(String.init))
        if !disabled.isEmpty { log("⚠️ disabled subsystems: \(disabled.sorted().joined(separator: ", "))") }
        if !disabled.contains("render") { startRenderLoop() }
        dashboard.onCommand = { [weak self] command in self?.applySyncCommand(command) }
        if !disabled.contains("webhook") { startWebhookServer() }
        if !disabled.contains("sync") { startSyncServer() }
        if !disabled.contains("input") { startInputPipeline() }
        if !disabled.contains("watcher") { startConductorWatcher() }
        startInputDebugMonitor()
        restoreRoster()
        applyAppearance()
        if !disabled.contains("hardware") { autoConnectHardware() }
        AppState.shared = self
    }

    /// Grab the keyboard at launch. Requiring a trip to Diagnostics to press
    /// "Go Live" makes a working setup look broken, so connect on our own and
    /// fall back to the normal reconnect loop when the board isn't there yet
    /// (still booting, or a cable plugged in a moment later).
    private func autoConnectHardware() {
        Task { @MainActor [weak self] in
            // A beat of headroom: on a cold launch the HID interface can still
            // be enumerating, and a failed first grab would start the backoff
            // for no reason.
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !self.hardwareConnected, !self.hardwareReleased else { return }
            if self.attemptConnect() {
                self.hardwareConnected = true
                return
            }
            self.log("no keyboard yet — watching for it")
            self.scheduleReconnect()
        }
    }

    func setAppearance(_ value: String) {
        config.appearance = value
        applyAppearance()
    }

    func setMacNotificationsEnabled(_ enabled: Bool) {
        guard enabled else {
            config.macNotificationsEnabled = false
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let granted = await macNotificationService.requestAuthorization()
            config.macNotificationsEnabled = granted
            if !granted {
                log("macOS notifications were not authorized")
            }
        }
    }

    func addPromptSnippet() -> String {
        let id = UUID().uuidString
        config.promptSnippets.append(PromptSnippet(
            id: id, name: "Untitled Snippet", prompt: "", builtIn: false))
        return id
    }

    func duplicatePromptSnippet(id: String) -> String? {
        guard var copy = config.promptSnippets.first(where: { $0.id == id }) else { return nil }
        copy.id = UUID().uuidString
        copy.name += " Copy"
        copy.builtIn = false
        config.promptSnippets.append(copy)
        return copy.id
    }

    func deletePromptSnippet(id: String) {
        guard config.promptSnippets.first(where: { $0.id == id })?.builtIn == false else { return }
        config.promptSnippets.removeAll { $0.id == id }
    }

    func restorePromptSnippet(id: String) {
        guard let original = DefaultPromptSnippets.snippet(id: id),
              let index = config.promptSnippets.firstIndex(where: { $0.id == id }) else { return }
        config.promptSnippets[index] = original
    }

    /// Flushes an explicit user edit immediately instead of waiting for the
    /// normal debounced configuration save.
    @discardableResult
    func saveConfigNow() -> Bool {
        saveTask?.cancel()
        do {
            try configStore.save(config)
            return true
        } catch {
            log("configuration save failed: \(error.localizedDescription)")
            return false
        }
    }

    func applyAppearance() {
        let app = NSApplication.shared   // NSApp may not exist yet at init
        switch config.appearance {
        case "light": app.appearance = NSAppearance(named: .aqua)
        case "dark": app.appearance = NSAppearance(named: .darkAqua)
        default: app.appearance = nil    // follow the system
        }
    }

    /// Local monitor = events actually delivered to THIS app. If clicks in
    /// the window don't produce log lines, macOS never routed them to us.
    private func startInputDebugMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.inputDebug else { return event }
            switch event.type {
            case .leftMouseDown:
                let p = event.locationInWindow
                self.log("🖱 mouseDown (\(Int(p.x)),\(Int(p.y))) window=\(event.window?.title ?? "nil")")
            case .keyDown:
                self.log("⌨︎ keyDown vk=\(event.keyCode)")
            default:
                break
            }
            return event
        }
    }

    // MARK: Input pipeline

    private func startInputPipeline() {
        executionEngine.log = { [weak self] message in self?.log(message) }
        agentFocusService.log = { [weak self] message in self?.log(message) }
        performAction = { [weak self] action in
            guard let self else { return }
            self.dispatch(action)
        }

        keystrokeListener.updateTriggers(Set(config.triggerBindings.map(\.trigger)))
        keystrokeListener.onTrigger = { [weak self] trigger, phase in
            guard let self else { return }
            // Already on the main thread (listener hops before calling us).
            guard let binding = self.config.triggerBindings.first(where: { $0.trigger == trigger }) else { return }
            // Agent keys are navigation controls, not profile actions. Route
            // physical presses through the same exact-session focus path as
            // the on-screen board before looking for a shortcut mapping.
            if phase == .down,
               binding.gesture == .press,
               binding.control.rawValue.hasPrefix("key."),
               let slot = Int(binding.control.rawValue.dropFirst("key.".count)),
               self.focusAgent(onSlot: slot) {
                self.log("⌨︎ \(trigger.display) → focused agent on key \(slot + 1)")
                return
            }
            let action = self.action(for: binding.control, gesture: binding.gesture)
            guard action != .none else { return }
            if phase == .down {
                self.log("⌨︎ \(trigger.display) → \(binding.control.rawValue).\(binding.gesture.rawValue) → \(action.summary)")
            }
            self.dispatch(action, phase: phase)
        }

        appTracker.onChange = { [weak self] bundleID in
            guard let self else { return }
            if let profile = self.config.profiles.first(where: { $0.appBundleIDs.contains(bundleID) }),
               profile.id != self.config.activeProfileID {
                self.config.activeProfileID = profile.id
                self.log("profile → \(profile.name) (\(bundleID) frontmost)")
            }
        }
        appTracker.start()
        refreshPermissions()
        restartListener()
    }

    func dispatch(_ action: Action, phase: PressPhase = .down) {
        switch action {
        case .switchProfile(let id):
            guard phase == .down else { return }
            if config.profile(id: id) != nil {
                config.activeProfileID = id
                log("profile → \(id)")
            }
        case .cycleProfile:
            guard phase == .down else { return }
            let profiles = config.profiles
            guard !profiles.isEmpty else { return }
            let current = profiles.firstIndex { $0.id == config.activeProfileID } ?? 0
            let next = profiles[(current + 1) % profiles.count]
            config.activeProfileID = next.id
            log("profile → \(next.name) (cycle)")
        default:
            executionEngine.perform(action, phase: phase, preferredBundleID: activeProfile.appBundleIDs.first)
        }
    }

    func refreshPermissions() {
        accessibilityGranted = PermissionsService.accessibilityGranted()
        inputMonitoringGranted = PermissionsService.inputMonitoringGranted()
        // The moment Accessibility comes through, bring the tap up — no
        // manual "Retry" needed.
        if accessibilityGranted, listenerMode != .tap {
            restartListener()
        }
    }

    func restartListener() {
        listenerMode = keystrokeListener.start()
        log("keystroke listener: \(listenerMode.rawValue)")
    }

    // MARK: Conductor workspaces

    @ObservationIgnored private var conductorWatcher: ConductorWatcher?
    var workspaces: [ConductorWorkspace] = []

    /// The tool (Codex/Claude) Conductor has recorded per workspace, read from
    /// its database — used to badge a workspace key with its underlying agent
    /// even when nothing is live. Keyed by workspace path and directory name.
    var conductorAgents: [String: ConductorAgentInfo] = [:]
    @ObservationIgnored private let conductorMetadata = ConductorMetadataStore()

    /// The tool logo to pair with the Conductor mark on a workspace key: the
    /// live agent's own source if one is reporting, else Conductor's recorded
    /// agent_type. Nil when unknown (the key then shows just the Conductor mark).
    func conductorToolAsset(forWorkspaceID id: String) -> String? {
        let path = workspacesRoot + "/" + id
        if let session = sessionStore.sessions.values.first(where: {
            $0.cwd == path || ($0.cwd?.hasPrefix(path + "/") ?? false)
        }), let asset = BrandIcon.asset(forSource: session.source) {
            return asset
        }
        let name = id.components(separatedBy: "/").last ?? id
        if let info = conductorAgents[path] ?? conductorAgents[name] {
            return BrandIcon.asset(forSource: info.agentType)
        }
        return nil
    }

    /// Refresh the recorded per-workspace tool from Conductor's database off the
    /// main thread; publishing the result updates workspace-key badges.
    func refreshConductorAgents() {
        Task.detached(priority: .utility) { [weak self, conductorMetadata] in
            let map = conductorMetadata.agentInfoByWorkspace()
            await MainActor.run {
                guard let self else { return }
                if self.conductorAgents != map { self.conductorAgents = map }
            }
        }
    }

    /// Workspaces mid archive-flash: their key still glows "finished" and must
    /// not be freed by autoPin until the flash timer releases it.
    @ObservationIgnored private var archivingWorkspaceIDs: Set<String> = []
    /// How long an archived workspace's key shows the finished color before the
    /// slot frees.
    @ObservationIgnored private let archiveFlashDuration: TimeInterval = 3

    func startConductorWatcher() {
        let watcher = ConductorWatcher(root: URL(fileURLWithPath: workspacesRoot))
        watcher.onChange = { [weak self] found in
            guard let self else { return }
            let previous = self.workspaces
            self.workspaces = found
            // Refresh which tool Conductor is running per workspace so keys can
            // badge Codex/Claude alongside the Conductor mark.
            self.refreshConductorAgents()
            let foundIDs = Set(found.map(\.id))
            let previousIDs = Set(previous.map(\.id))

            // A workspace that left workspaces/ is either archived (its context
            // now lives under archived-contexts/) or simply gone. Archived ones
            // flash "finished" on their key before the slot frees; the rest are
            // released by autoPin.
            for workspace in previous where !foundIDs.contains(workspace.id) {
                if self.isArchived(workspace) { self.beginArchiveFlash(workspace) }
            }
            self.autoPin(found)

            for workspace in found where !previousIDs.contains(workspace.id) {
                self.log("conductor workspace appeared: \(workspace.displayName) (\(workspace.id))")
            }
            for workspace in previous
            where !foundIDs.contains(workspace.id) && !self.archivingWorkspaceIDs.contains(workspace.id) {
                self.log("conductor workspace removed: \(workspace.id)")
            }
        }
        watcher.start()
        conductorWatcher = watcher
    }

    /// Root that holds archived Conductor contexts, a sibling of the live
    /// workspaces root (~/conductor/archived-contexts).
    private var archivedContextsRoot: String {
        URL(fileURLWithPath: workspacesRoot)
            .deletingLastPathComponent()
            .appendingPathComponent("archived-contexts").path
    }

    /// A removed workspace was archived (not just deleted) when Conductor has
    /// left a context folder for it under archived-contexts/, named after the
    /// branch/feature it showed the user.
    private func isArchived(_ workspace: ConductorWorkspace) -> Bool {
        let path = archivedContextsRoot + "/" + workspace.project + "/" + workspace.displayName
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Flash the archived workspace's key "finished", then free the slot. A
    /// synthetic success session at the workspace path drives the glow through
    /// the normal per-key pipeline while the binding is still in place.
    private func beginArchiveFlash(_ workspace: ConductorWorkspace) {
        guard !archivingWorkspaceIDs.contains(workspace.id) else { return }
        archivingWorkspaceIDs.insert(workspace.id)
        log("conductor workspace archived: \(workspace.displayName) (\(workspace.id))")
        injectState(.success, source: "conductor-archive", session: workspace.id,
                    cwd: workspacesRoot + "/" + workspace.id,
                    agent: workspace.displayName, task: "Archived")
        DispatchQueue.main.asyncAfter(deadline: .now() + archiveFlashDuration) { [weak self] in
            guard let self else { return }
            self.archivingWorkspaceIDs.remove(workspace.id)
            self.sessionStore.remove(sessionKey: "conductor-archive#\(workspace.id)")
            self.releaseKeys(boundTo: workspace.id)
        }
    }

    /// Remove any key bindings pointing at a workspace id (its slot returns to
    /// the auto pool).
    private func releaseKeys(boundTo id: String) {
        var settings = activeLayoutSettings
        var changed = false
        for (slot, binding) in settings.keyBindings {
            if case .workspace(id) = binding {
                settings.keyBindings.removeValue(forKey: slot)
                changed = true
            }
        }
        if changed { activeLayoutSettings = settings }
    }

    /// Give newly appeared workspaces a free auto key so they light up with
    /// zero configuration; users can rebind or free keys in the Agents pane.
    private func autoPin(_ found: [ConductorWorkspace]) {
        // Demo mode owns the board; don't let real workspaces reshuffle it.
        guard !demoModeEnabled else { return }
        let liveIDs = Set(found.map(\.id))
        // Release keys bound to workspaces that no longer exist — but leave
        // archiving workspaces alone; their flash timer owns the release.
        var settings = activeLayoutSettings
        for (slot, binding) in settings.keyBindings {
            if case .workspace(let id) = binding,
               !liveIDs.contains(id), !archivingWorkspaceIDs.contains(id) {
                settings.keyBindings.removeValue(forKey: slot)
            }
        }
        let boundWorkspaces = Set(settings.keyBindings.values.compactMap { binding -> String? in
            if case .workspace(let id) = binding { return id }
            return nil
        })
        // Deliberately no auto-assignment here. Every workspace on disk used
        // to claim a free key, so workspaces untouched for months sat on the
        // board crowding out the two or three actually in use. Assign them by
        // hand in Manage Agents; they wait in the chip strip until you do.
        _ = boundWorkspaces
        if settings != activeLayoutSettings { activeLayoutSettings = settings }
    }

    // MARK: Claude Code hooks

    @ObservationIgnored private(set) lazy var hooksInstaller = HooksInstaller(port: config.webhookPort)
    @ObservationIgnored private(set) lazy var codexInstaller = CodexHooksInstaller(port: config.webhookPort)
    @ObservationIgnored private(set) lazy var antigravityInstaller = AntigravityHooksInstaller(port: config.webhookPort)
    @ObservationIgnored private(set) lazy var openCodeInstaller = OpenCodeIntegration(port: config.webhookPort)
    @ObservationIgnored private(set) lazy var copilotInstaller = CopilotIntegration(port: config.webhookPort)
    @ObservationIgnored private(set) lazy var cursorInstaller = CursorIntegration(port: config.webhookPort)
    @ObservationIgnored private(set) lazy var qwenInstaller = QwenIntegration(port: config.webhookPort)
    var hooksInstalled = false
    var hooksStale = false
    var codexHooksInstalled = false
    var codexFeatureEnabled = false
    var codexDetected = false
    var antigravityHooksInstalled = false
    var antigravityDetected = false
    var openCodeHooksInstalled = false
    var openCodeDetected = false
    var copilotHooksInstalled = false
    var copilotDetected = false
    var cursorHooksInstalled = false
    var cursorDetected = false
    var qwenHooksInstalled = false
    var qwenDetected = false

    func refreshHooksStatus() {
        hooksInstalled = hooksInstaller.isInstalled()
        hooksStale = hooksInstalled && hooksInstaller.isStale()
        codexHooksInstalled = codexInstaller.isInstalled()
        codexFeatureEnabled = codexInstaller.featureEnabled()
        codexDetected = codexInstaller.codexInstalled
        antigravityHooksInstalled = antigravityInstaller.isInstalled()
        antigravityDetected = antigravityInstaller.isDetected
        openCodeHooksInstalled = openCodeInstaller.isInstalled()
        openCodeDetected = openCodeInstaller.isDetected
        copilotHooksInstalled = copilotInstaller.isInstalled()
        copilotDetected = copilotInstaller.isDetected
        cursorHooksInstalled = cursorInstaller.isInstalled()
        cursorDetected = cursorInstaller.isDetected
        qwenHooksInstalled = qwenInstaller.isInstalled()
        qwenDetected = qwenInstaller.isDetected
    }

    func installOpenCodeHooks() { installIntegration(openCodeInstaller) }
    func uninstallOpenCodeHooks() { uninstallIntegration(openCodeInstaller) }
    func installCopilotHooks() { installIntegration(copilotInstaller) }
    func uninstallCopilotHooks() { uninstallIntegration(copilotInstaller) }
    func installCursorHooks() { installIntegration(cursorInstaller) }
    func uninstallCursorHooks() { uninstallIntegration(cursorInstaller) }
    func installQwenHooks() { installIntegration(qwenInstaller) }
    func uninstallQwenHooks() { uninstallIntegration(qwenInstaller) }

    private func installIntegration(_ integration: any ProviderIntegration) {
        do {
            try integration.install()
            log("\(integration.displayName) integration installed")
        } catch { log("\(integration.displayName) install failed: \(error.localizedDescription)") }
        refreshHooksStatus()
    }

    private func uninstallIntegration(_ integration: any ProviderIntegration) {
        do {
            try integration.uninstall()
            log("\(integration.displayName) integration removed")
        } catch { log("\(integration.displayName) uninstall failed: \(error.localizedDescription)") }
        refreshHooksStatus()
    }

    func installAntigravityHooks() {
        do {
            try antigravityInstaller.install()
            log("Antigravity CLI hooks installed in ~/.gemini/config/hooks.json (backup saved)")
        } catch {
            log("Antigravity hook install failed: \(error.localizedDescription)")
        }
        refreshHooksStatus()
    }

    func uninstallAntigravityHooks() {
        do {
            try antigravityInstaller.uninstall()
            log("Antigravity CLI hooks removed")
        } catch {
            log("Antigravity hook uninstall failed: \(error.localizedDescription)")
        }
        refreshHooksStatus()
    }

    func installCodexHooks() {
        do {
            codexInstaller.eventStates = config.codexHookEvents
            try codexInstaller.install()
            if !codexInstaller.featureEnabled() {
                try codexInstaller.enableFeature()
                log("Codex hooks feature flag enabled in ~/.codex/config.toml (backup saved)")
            }
            log("Codex CLI hooks installed in ~/.codex/hooks.json (backup saved)")
        } catch {
            log("Codex hook install failed: \(error.localizedDescription)")
        }
        refreshHooksStatus()
    }

    func uninstallCodexHooks() {
        do {
            try codexInstaller.uninstall()
            log("Codex CLI hooks removed")
        } catch {
            log("Codex hook uninstall failed: \(error.localizedDescription)")
        }
        refreshHooksStatus()
    }

    func installHooks() {
        do {
            hooksInstaller.eventStates = config.claudeHookEvents
            try hooksInstaller.install()
            log("Claude Code hooks installed in ~/.claude/settings.json (backup saved)")
        } catch {
            log("hook install failed: \(error.localizedDescription)")
        }
        refreshHooksStatus()
        config.hooksInstalled = hooksInstalled
    }

    func uninstallHooks() {
        do {
            try hooksInstaller.uninstall()
            log("Claude Code hooks removed")
        } catch {
            log("hook uninstall failed: \(error.localizedDescription)")
        }
        refreshHooksStatus()
        config.hooksInstalled = hooksInstalled
    }

    // MARK: Webhook

    private func startWebhookServer() {
        let server = WebhookServer(port: config.webhookPort) { [weak self] report in
            Task { @MainActor in self?.handle(report) }
        }
        server.sessionsProvider = { @MainActor [weak self] in
            guard let self else { return "[]" }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let sessions = Array(self.sessionStore.sessions.values)
            guard let data = try? encoder.encode(sessions) else { return "[]" }
            return String(decoding: data, as: UTF8.self)
        }
        server.lightShowHandler = { @MainActor [weak self] in
            self?.runLightShow() ?? false
        }
        do {
            try server.start()
            webhookServer = server
            log("webhook listening on 127.0.0.1:\(config.webhookPort)")
        } catch {
            webhookError = error.localizedDescription
            log("webhook failed to start: \(error.localizedDescription)")
        }
    }

    // MARK: Shared dashboard model (drives board/feed views; also fed to iOS)

    /// The render/reassign surface the dashboard views bind to. AppState mirrors
    /// its live state into this each render tick and routes its commands back
    /// through the same local handlers.
    let dashboard = DashboardModel()

    /// Copy live state into the shared dashboard model. Board data is mirrored
    /// every tick (the board already re-renders at frame rate); structural data
    /// is change-guarded so the activity feed and menus don't churn.
    private func mirrorDashboard(frame: EffectFrame, rules: RGBRules) {
        dashboard.currentFrame = frame
        dashboard.sessions = sessionStore.sessions
        if dashboard.keyBindings != activeLayoutSettings.keyBindings {
            dashboard.keyBindings = activeLayoutSettings.keyBindings
        }
        if dashboard.keyLegends != activeLayoutSettings.keyLegends {
            dashboard.keyLegends = activeLayoutSettings.keyLegends
        }
        if dashboard.workspaces != workspaces { dashboard.workspaces = workspaces }
        if dashboard.conductorAgents != conductorAgents { dashboard.conductorAgents = conductorAgents }
        if dashboard.cwdBranches != cwdBranches { dashboard.cwdBranches = cwdBranches }
        if dashboard.rgbRules != rules { dashboard.rgbRules = rules }
        if dashboard.underglow != activeProfile.underglow { dashboard.underglow = activeProfile.underglow }
        if dashboard.steadyGlow != config.steadyGlow { dashboard.steadyGlow = config.steadyGlow }
        if dashboard.workspacesRoot != workspacesRoot { dashboard.workspacesRoot = workspacesRoot }
        if dashboard.deviceName != config.deviceName { dashboard.deviceName = config.deviceName }
        let profileIndex = config.profiles.firstIndex { $0.id == config.activeProfileID } ?? 0
        if dashboard.activeProfileIndex != profileIndex { dashboard.activeProfileIndex = profileIndex }
    }

    // MARK: LAN sync (iPhone/Watch companion)

    @ObservationIgnored private(set) lazy var syncServer = SyncServer(
        deviceName: config.deviceName,
        instanceID: PairingStore.instanceID(),
        tokenProvider: { PairingStore.currentToken() })
    @ObservationIgnored private var syncPublishTimer: Timer?

    func startSyncServer() {
        guard !syncServer.isRunning else { return }
        _ = PairingStore.currentToken()  // materialize the token file
        syncServer.onCommand = { [weak self] command in
            Task { @MainActor in
                self?.applySyncCommand(command)
                self?.publishSnapshot()
            }
        }
        do {
            try syncServer.start()
            log("sync server listening on :\(SyncServer.port) as \(config.deviceName)")
        } catch {
            log("sync server failed to start: \(error.localizedDescription)")
            return
        }
        // Push state to connected devices a couple of times a second; the
        // client re-derives the LED animation locally, so this stays cheap.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishSnapshot() }
        }
        RunLoop.main.add(timer, forMode: .common)
        syncPublishTimer = timer
    }

    func stopSyncServer() {
        syncPublishTimer?.invalidate()
        syncPublishTimer = nil
        syncServer.stop()
    }

    /// The 6-digit pairing code currently displayable in Settings (nil = no
    /// open pairing window).
    var currentPairingCode: String?

    /// Open a fresh pairing window and surface its code in Settings.
    func startPairing() {
        currentPairingCode = syncServer.beginPairing()
    }

    /// Revoke every paired device (mints a new token).
    func unpairAllDevices() {
        PairingStore.regenerate()
        currentPairingCode = nil
    }

    @ObservationIgnored private let syncEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys  // stable bytes so identical state dedups
        return encoder
    }()

    private func publishSnapshot() {
        guard syncServer.isRunning else { return }
        guard let data = try? syncEncoder.encode(ServerMessage.snapshot(dashboardSnapshot())) else { return }
        syncServer.broadcast(snapshotEnvelope: data)
    }

    private func handle(_ report: StateReport) {
        guard let state = AgentState(wireName: report.state) else {
            log("webhook: unknown state '\(report.state)'")
            return
        }
        injectState(state,
                    source: report.source ?? "unknown",
                    session: report.session ?? "na",
                    cwd: canonicalWorkspaceCwd(report.cwd),
                    agent: report.agent,
                    parentSession: report.parentSession,
                    model: report.model,
                    task: report.task,
                    terminalSession: report.terminalSession,
                    terminalKind: report.terminalKind,
                    terminalEndpoint: report.terminalEndpoint)
    }

    /// Resolve a reported cwd that lives under Conductor's workspaces root
    /// through any symlink (the branch/feature alias) to the real city dir, so
    /// prefix-matching against `.workspace` bindings — which are keyed on the
    /// stable city path — routes the agent to the right key. Paths outside the
    /// workspaces root are left untouched.
    private func canonicalWorkspaceCwd(_ cwd: String?) -> String? {
        guard let cwd, cwd.hasPrefix(workspacesRoot + "/") else { return cwd }
        return URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
    }

    // MARK: Profiles

    var activeProfile: Profile {
        config.profile(id: config.activeProfileID) ?? DefaultProfiles.conductor
    }

    func action(for control: ControlID, gesture: ControlGesture) -> Action {
        activeProfile.action(for: control, gesture: gesture)
    }

    func setAction(_ action: Action, for control: ControlID, gesture: ControlGesture) {
        guard let index = config.profiles.firstIndex(where: { $0.id == config.activeProfileID }) else { return }
        config.profiles[index].mappings[control, default: [:]][gesture] = action
    }

    // MARK: Input

    /// `fromHardware` marks a real press on the pad. Edit mode is about
    /// clicking the on-screen keyboard to rebind it — it must never stop the
    /// physical keys from doing their job, or the pad goes dead whenever the
    /// Keyboard pane is open (and it opens in Edit mode by default).
    func controlActivated(_ control: ControlID,
                          gesture: ControlGesture,
                          phase: PressPhase = .down,
                          fromHardware: Bool = false) {
        // The six agent keys are navigation controls whenever an agent is
        // assigned. Their purpose is to jump to that live session, independent
        // of whichever shortcut profile happens to be active.
        if gesture == .press, phase == .down,
           control.rawValue.hasPrefix("key."),
           let slot = Int(control.rawValue.dropFirst("key.".count)),
           focusAgent(onSlot: slot) {
            return
        }
        if editMode && !fromHardware {
            if phase == .down {
                editTarget = EditTarget(control: control, gesture: gesture)
            }
        } else {
            let action = action(for: control, gesture: gesture)
            if phase == .down {
                log("\(control.rawValue).\(gesture.rawValue) → \(action.summary)")
            }
            dispatch(action, phase: phase)
        }
    }

    /// Overwrites any key the user has pinned to a fixed colour. Applied after
    /// rendering so a pinned key is immune to agent state, animation, and the
    /// aggregate — it just sits there being the colour you asked for.
    private func applyPinnedColors(to frame: EffectFrame) -> EffectFrame {
        let pinned = activeLayoutSettings.keyColors
        guard !pinned.isEmpty else { return frame }
        var frame = frame
        for (keyIndex, color) in pinned {
            guard let led = layout.controls
                .first(where: { $0.id == .key(keyIndex) })?.ledIndex else { continue }
            frame.perLEDSpecs[led] = LEDSpec(color: color, kind: .solid)
            if led < frame.perLED.count { frame.perLED[led] = color }
        }
        return frame
    }

    /// The ring's colour for the active profile's underglow mode. Sent on every
    /// tick — `setUnderglow` drops repeats, so this costs one message per
    /// actual change, and it means the ring is restored after anything that
    /// paints it directly (the connection test).
    private func ambientParam(for aggregate: AgentState) -> VOAI.ZoneParam {
        switch activeProfile.underglow {
        case .rainbowUnlessAlert:
            let alert = aggregate == .error || aggregate == .waiting
            return alert
                ? VOAI.ZoneParam(e: VOAI.Effect.solid.rawValue, b: 1, s: 0.5, m: 1, c: 0xFF0000)
                : VOAI.ZoneParam(e: VOAI.Effect.rainbow.rawValue, b: 1, s: 0.55, m: 1, c: 0xFFFFFF)
        case .aggregate:
            let spec = activeProfile.rgbRules.spec(for: aggregate)
            return VOAI.ZoneParam(e: VOAI.Effect.solid.rawValue,
                                  b: Double(spec.color.v) / 255.0,
                                  s: 0.5, m: 1, c: VOAI.packedRGB(spec.color))
        case .solid(let hsv):
            return VOAI.ZoneParam(e: VOAI.Effect.solid.rawValue,
                                  b: Double(hsv.v) / 255.0,
                                  s: 0.5, m: 1, c: VOAI.packedRGB(hsv))
        case .off:
            return .off
        }
    }

    // MARK: Connection test

    /// True while the light show owns the board, so the render loop doesn't
    /// fight it for the LEDs.
    var lightShowRunning = false

    /// A few seconds of colour on the physical keyboard: proof the connection
    /// works, and a demo for anyone who has not seen it light up.
    func runConnectionTest() {
        guard let voai = hardwareDevice as? VOAIDevice, hardwareConnected, !lightShowRunning else { return }
        lightShowRunning = true
        log("✨ testing the keyboard — watch the keys")

        let slots = Array(VOAI.ledIndexForAgentSlot.indices)
        func paint(_ colors: [Int: UInt32], effect: VOAI.Effect = .solid, speed: Double = 0.5) {
            voai.sendThreads(slots.map { slot in
                VOAI.ThreadParam(
                    id: slot,
                    c: colors[slot] ?? 0,
                    b: colors[slot] == nil ? 0 : 1,
                    e: (colors[slot] == nil ? VOAI.Effect.off : effect).rawValue,
                    s: speed, sk: 0, sa: 0)
            })
        }
        func ambient(_ effect: VOAI.Effect, _ color: UInt32, speed: Double = 0.6) {
            voai.setUnderglow(VOAI.ZoneParam(e: effect.rawValue, b: 1, s: speed, m: 1, c: color))
        }

        Task { @MainActor [weak self] in
            defer {
                self?.lightShowRunning = false
                self?.currentFrame = .uniform(.off, ledCount: CodexMicroLayout.layout.ledCount)
            }
            let hues: [UInt32] = [0xFF0000, 0xFF7F00, 0xFFFF00, 0x00FF00,
                                  0x00FFFF, 0x0000FF, 0x8B00FF]

            // 1. Chase a single dot across every key.
            ambient(.off, 0)
            for slot in slots {
                paint([slot: hues[slot % hues.count]])
                try? await Task.sleep(for: .milliseconds(70))
            }
            // 2. Everything at once, each key its own colour.
            paint(Dictionary(uniqueKeysWithValues: slots.map { ($0, hues[$0 % hues.count]) }))
            ambient(.rainbow, 0xFFFFFF)
            try? await Task.sleep(for: .milliseconds(900))
            // 3. Breathe, so the on-device animation is visible too.
            paint(Dictionary(uniqueKeysWithValues: slots.map { ($0, UInt32(0x00AAFF)) }),
                  effect: .breath, speed: 0.9)
            try? await Task.sleep(for: .milliseconds(1100))
            // 4. The colours that actually mean something day to day.
            for (color, hold) in [(UInt32(0xFFAA00), 500), (UInt32(0xFF0000), 500), (UInt32(0x00FF00), 700)] {
                paint(Dictionary(uniqueKeysWithValues: slots.map { ($0, color) }))
                ambient(.solid, color)
                try? await Task.sleep(for: .milliseconds(hold))
            }
            self?.log("✨ keyboard test finished")
        }
    }

    /// Ten seconds of per-key colour on demand — what the
    /// `/creator-micro-lightshow` skill fires, and the shortest way to show
    /// that each key holds a colour of its own. Returns false when there is no
    /// board to run it on, or a show is already running.
    @discardableResult
    func runLightShow() -> Bool {
        guard let voai = hardwareDevice as? VOAIDevice, hardwareConnected, !lightShowRunning else { return false }
        lightShowRunning = true
        log("🌈 light show — every key its own colour")
        let script = LightShow.script()
        let ledCount = layout.ledCount

        Task { @MainActor [weak self] in
            defer {
                self?.lightShowRunning = false
                self?.currentFrame = .uniform(.off, ledCount: ledCount)
            }
            for step in script {
                voai.sendThreads(LightShow.threads(for: step))
                voai.setUnderglow(VOAI.ZoneParam(e: step.underglowEffect.rawValue, b: 1,
                                                 s: 0.7, m: 1, c: step.underglow))
                // Mirror it on screen too: the window and the board should show
                // the same colours in a screen recording.
                let frame = LightShow.frame(for: step, ledCount: ledCount)
                self?.currentFrame = frame
                self?.dashboard.currentFrame = frame
                try? await Task.sleep(for: .seconds(step.hold))
            }
            self?.log("🌈 light show finished")
        }
        return true
    }

    /// Pin a key to a colour, or pass nil to hand it back to agent state.
    func setPinnedColor(_ color: HSV?, forKey keyIndex: Int) {
        var settings = activeLayoutSettings
        if let color {
            settings.keyColors[keyIndex] = color
        } else {
            settings.keyColors.removeValue(forKey: keyIndex)
        }
        activeLayoutSettings = settings
    }

    // MARK: Joystick

    /// The stick streams position continuously while held, so a raw dispatch
    /// would fire hundreds of times. One step per push instead: fire when the
    /// direction changes, and re-arm only after the stick returns near centre.
    private func handleJoystick(angle: Double, distance: Double) {
        let engage = 0.55
        let release = 0.30

        if distance < release {
            lastJoystickGesture = nil
            return
        }
        guard distance >= engage else { return }
        guard let gesture = AppState.joystickGesture(forAngle: angle) else { return }
        guard gesture != lastJoystickGesture else { return }
        lastJoystickGesture = gesture
        log("🕹 joystick \(gesture.rawValue)")
        controlActivated(.joystick, gesture: gesture, phase: .down, fromHardware: true)
        controlActivated(.joystick, gesture: gesture, phase: .up, fromHardware: true)
    }

    /// Angle is normalised 0–1 around the circle, with UP at 0.75 on this
    /// hardware (measured: up ≈ 0.76, right ≈ 0.00). Rotating by a quarter
    /// turn puts up at 0. Quadrant boundaries sit on the diagonals so a push
    /// that isn't perfectly straight still resolves.
    static func joystickGesture(forAngle angle: Double) -> ControlGesture? {
        let a = (angle + 0.25).truncatingRemainder(dividingBy: 1.0)
        let normalised = a < 0 ? a + 1 : a
        switch normalised {
        case ..<0.125, 0.875...: return .up
        case ..<0.375: return .right
        case ..<0.625: return .down
        case ..<0.875: return .left
        default: return nil
        }
    }

    @discardableResult
    func focusAgent(onSlot slot: Int) -> Bool {
        let binding = activeLayoutSettings.keyBindings[slot]
        let path: String
        let isConductor: Bool
        switch binding {
        case .workspace(let id):
            // A Conductor workspace exists independently of hook telemetry.
            // Navigate to it directly instead of requiring a live session.
            // Conductor's command palette matches on the branch/feature name it
            // shows the user, so navigate by displayName rather than the city dir.
            let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
            let project = parts.first ?? id
            agentFocusService.focusConductorWorkspace(
                project: project,
                name: workspaceDisplayName(forID: id),
                workspacePath: workspacesRoot + "/" + id)
            return true
        case .path(let assignedPath):
            path = assignedPath
            isConductor = assignedPath.hasPrefix(workspacesRoot + "/")
        case nil, .off:
            return false
        }
        let normalized = path.hasSuffix("/") ? path : path + "/"
        // A key stays pointed at its folder whether or not an agent is
        // currently reporting from it — agents come and go inside a tab, and
        // hook telemetry lags both ways. With no live session, aim at the
        // folder itself so the key still lands on that project's terminal.
        let session = sessionStore.sessions.values
            .filter({ $0.cwd == path || ($0.cwd?.hasPrefix(normalized) ?? false) })
            .max(by: { $0.updatedAt < $1.updatedAt })
            ?? AgentSession(source: "", session: path, cwd: path, state: .idle, updatedAt: .distantPast)
        agentFocusService.focus(
            session: session,
            isConductorWorkspace: isConductor,
            activeProfileID: config.activeProfileID)
        return true
    }

    // MARK: Agent state

    func injectState(_ state: AgentState, source: String = "simulator", session: String = "sim",
                     cwd: String? = nil, agent: String? = nil,
                     parentSession: String? = nil, model: String? = nil,
                     task: String? = nil, terminalSession: String? = nil,
                     terminalKind: String? = nil, terminalEndpoint: String? = nil) {
        applySessionEvent(SessionEvent(source: source, session: session, cwd: cwd,
                                       state: state, at: Date(), agent: agent,
                                       parentSession: parentSession, model: model, task: task,
                                       terminalSession: terminalSession, terminalKind: terminalKind,
                                       terminalEndpoint: terminalEndpoint),
                          simulated: source == "simulator")
        log("state ← \(state.wireName) (\(source))")
        scheduleRosterSave()
    }

    private func applySessionEvent(_ event: SessionEvent, simulated: Bool,
                                   recordActivity: Bool = true) {
        let key = "\(event.source)#\(event.session)"
        let isNewSession = sessionStore.sessions[key] == nil
        let previousState = sessionStore.sessions[key]?.state
        sessionStore.apply(event)
        // A brand-new agent auto-claims a free key so it lights up immediately.
        if isNewSession, let session = sessionStore.sessions[key] {
            autoAssignSession(session)
        }
        guard recordActivity, previousState != event.state,
              let session = sessionStore.sessions[key] else { return }
        let transition: (ActivityFeedItem.Category, String)? = switch event.state {
        case .error: (.attention, "experienced an error")
        case .waiting: (.attention, "needs permission or input")
        case .success: (.completed, "completed its current task")
        case .thinking where previousState == nil || previousState == .idle:
            (.working, "started thinking")
        case .coding where previousState != .thinking && previousState != .coding:
            (.working, "started working")
        case .idle where previousState != nil && previousState != .idle:
            (.presence, "is now idle")
        default: nil
        }
        if let transition {
            addFeedItem(for: session, category: transition.0,
                        message: transition.1, simulated: simulated)
            if config.macNotificationsEnabled {
                macNotificationService.post(
                    for: session,
                    project: workContext(for: session) ?? projectName(for: session))
            }
        }
    }

    private func addFeedItem(for session: AgentSession, category: ActivityFeedItem.Category,
                             message: String, simulated: Bool) {
        let slot = ledKeySlots.first { assignedSession(forSlot: $0)?.key == session.key }
        activityFeed.insert(ActivityFeedItem(
            at: Date(), category: category, state: session.state, source: session.source,
            agentName: session.agent ?? readableSourceName(session.source),
            project: workContext(for: session) ?? projectName(for: session),
            keySlot: slot, message: message,
            simulated: simulated), at: 0)
        if activityFeed.count > 200 { activityFeed.removeLast(activityFeed.count - 200) }
        dashboard.activityFeed = Array(activityFeed.prefix(80))
    }

    // MARK: Agent roster persistence (survives app restarts)

    @ObservationIgnored private var rosterSaveTask: Task<Void, Never>?

    private var rosterURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MegaMicro/agent-roster.json")
    }

    func restoreRoster() {
        guard let data = try? Data(contentsOf: rosterURL),
              let sessions = try? JSONDecoder().decode([AgentSession].self, from: data) else { return }
        sessionStore.restore(sessions)
        if !sessions.isEmpty {
            log("restored \(sessions.count) known agent(s) from last run")
        }
    }

    private func scheduleRosterSave() {
        rosterSaveTask?.cancel()
        rosterSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let sessions = Array(self.sessionStore.sessions.values)
            guard let data = try? JSONEncoder().encode(sessions) else { return }
            try? PrivateFileStore.write(data, to: self.rosterURL)
        }
    }

    @ObservationIgnored private lazy var logFileHandle: FileHandle? = {
        let url = activityLogURL
        try? PrivateFileStore.ensureDirectory(url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    private var activityLogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MegaMicro/activity.log")
    }

    private func rotateActivityLogIfNeeded() {
        guard let handle = logFileHandle,
              let size = try? handle.offset(), size >= 5 * 1024 * 1024 else { return }
        try? handle.close()
        logFileHandle = nil
        let archive = activityLogURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: archive)
        try? FileManager.default.moveItem(at: activityLogURL, to: archive)
        _ = FileManager.default.createFile(atPath: activityLogURL.path, contents: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activityLogURL.path)
        logFileHandle = try? FileHandle(forWritingTo: activityLogURL)
        _ = try? logFileHandle?.seekToEnd()
    }

    func log(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        activityLog.append("[\(stamp)] \(message)")
        if activityLog.count > 200 { activityLog.removeFirst(activityLog.count - 200) }
        rotateActivityLogIfNeeded()
        try? logFileHandle?.write(contentsOf: Data("[\(stamp)] \(message)\n".utf8))
    }

    // MARK: Render loop (20 Hz)

    private func startRenderLoop() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    private var permissionPollCounter = 0

    private func renderFrame() {
        // Cheap standing check (~every 3 s) so a fresh Accessibility grant
        // activates the tap even when the Permissions pane isn't open.
        permissionPollCounter += 1
        if permissionPollCounter >= 60 {
            permissionPollCounter = 0
            if listenerMode != .tap { refreshPermissions() }
        }

        let now = Date()
        let t = now.timeIntervalSinceReferenceDate
        let rules = activeProfile.rgbRules
        // Fleet aggregate: highest-priority state across agents IN the fleet
        // (excluded agents still light their own keys, but never the halo).
        sessionStore.expire(now: now)
        let fleetSessions = sessionStore.sessions.values.filter { !isExcludedFromFleet($0) }
        let aggregate = fleetSessions.map(\.state).max() ?? .idle
        let aggregateAge = fleetSessions
            .filter { $0.state == aggregate }
            .map { now.timeIntervalSince($0.updatedAt) }
            .min() ?? 0

        // Keys glow ONLY for explicitly assigned agents (workspace or folder
        // bindings). Unassigned agents wait in the chip strip until placed —
        // nothing sneaks onto the board on its own.
        //
        // An agent key with nothing on it goes fully dark. An assigned key is
        // always painted, idle included, so resting agents keep the dim-white
        // "occupied" glow — that contrast is the only way to read at a glance
        // which keys are free. `ledKeySlots` covers just the agent-hosting
        // keys, so the printed action row keeps its own idle lighting.
        var perKey: [Int: (state: AgentState, age: TimeInterval)] = [:]
        var unlit: Set<Int> = []
        for slot in ledKeySlots {
            guard let led = layout.control(.key(slot))?.ledIndex else { continue }
            switch activeLayoutSettings.keyBindings[slot] {
            case nil, .off:
                unlit.insert(led)
            case .workspace(let id):
                perKey[led] = (sessionStore.resolved(underPath: workspacesRoot + "/" + id, now: now), 0)
            case .path(let path):
                perKey[led] = (sessionStore.resolved(underPath: path, now: now), 0)
            }
        }

        let frame = AnimationRenderer.frame(
            aggregate: aggregate, aggregateAge: aggregateAge,
            perKeyStates: perKey, rules: rules,
            underglowMode: activeProfile.underglow,
            steadyGlow: config.steadyGlow,
            unlitLEDs: unlit,
            ledCount: layout.ledCount, t: t)
        guard !lightShowRunning else { return }
        let pinnedFrame = applyPinnedColors(to: frame)
        let notice = makeFleetNotification(included: Array(fleetSessions), state: aggregate)
        if notice != fleetNotification {
            fleetNotification = notice
            dashboard.fleetNotification = notice
        }
        mirrorDashboard(frame: pinnedFrame, rules: rules)
        if pinnedFrame != currentFrame || renderedFleetState != aggregate {
            renderedFleetState = aggregate
            currentFrame = pinnedFrame
            device.apply(pinnedFrame)
            hardwareDevice?.apply(pinnedFrame)
        }
        (hardwareDevice as? VOAIDevice)?.setUnderglow(ambientParam(for: aggregate))
    }

    // MARK: Physical keyboard

    /// The real keyboard, once connected (the Mock/simulator always runs).
    @ObservationIgnored private(set) var hardwareDevice: KeyboardDevice?
    var hardwareConnected = false
    var hardwareName: String?
    /// True while the auto-reconnect loop is trying to reattach after the board
    /// dropped (e.g. re-enumeration triggered by an external layer edit).
    var isReconnecting = false
    /// True when the user deliberately released the board ("Release for
    /// Editing"); parks auto-reconnect until they hit Reconnect.
    private(set) var hardwareReleased = false

    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// Backoff loop gives up after this many misses (~2 min at the 5 s cap) so a
    /// board left unplugged doesn't poll forever.
    private static let maxReconnectAttempts = 24

    /// Try the Codex Micro / Creator Micro 2 protocol first (confirmed by
    /// Work Louder as the current hardware), then VIA for original Creator
    /// Micro 1 boards. Entry point for both the first connect and the manual
    /// Reconnect button.
    func connectHardware() {
        cancelReconnect()
        hardwareReleased = false
        if !attemptConnect() {
            log("no keyboard found — plug in via USB-C and make sure Work Louder Input is closed")
        }
    }

    /// One connection attempt across the supported protocols. Quiet on failure —
    /// the caller decides whether to log or retry.
    @discardableResult
    private func attemptConnect() -> Bool {
        // Drop any prior handle so a re-enumerated board gets a clean grab.
        hardwareDevice?.disconnect()
        hardwareDevice = nil

        let voai = VOAIDevice(layout: layout)
        voai.onDeviceEvent = { [weak self] event in
            Task { @MainActor in self?.handleDeviceEvent(event) }
        }
        voai.onConnectionChange = { [weak self] connected in
            Task { @MainActor in self?.handleHardwareConnectionChange(connected) }
        }
        if (try? voai.connect()) != nil {
            hardwareDevice = voai
            hardwareConnected = true
            hardwareName = "Codex Micro / Creator Micro 2"
            log("🔌 connected: Codex Micro family (v.oai protocol) — lights are live")
            // Per-key colour only renders on keys bound to KV_OAI_AG00…AG05 on
            // the active layer. Without this the firmware still answers "ok"
            // and lights nothing, so bind them before we start sending frames.
            voai.ensureAgentKeymap { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success(true):
                        self?.log("⌨️ bound the six agent keys for per-key colour (they no longer type)")
                    case .success(false):
                        break   // already bound
                    case .failure(let error):
                        self?.log("⚠️ could not bind agent keys — per-key colour will not show: \(error.localizedDescription)")
                    }
                    // Strictly after the keymap write: both edit the same file
                    // on the device, and the loser of a race would be undone.
                    self?.restoreDeviceLightsIfBlanked(voai)
                }
            }
            return true
        }
        let via = VIAHIDDevice(layout: layout)
        via.onConnectionChange = { [weak self] connected in
            Task { @MainActor in self?.handleHardwareConnectionChange(connected) }
        }
        if (try? via.connect()) != nil {
            hardwareDevice = via
            hardwareConnected = true
            hardwareName = "Creator Micro (VIA)"
            log("🔌 connected: Creator Micro v1 (VIA protocol) — lights are live")
            return true
        }
        hardwareConnected = false
        hardwareName = nil
        return false
    }

    /// Shared connection-change sink for whichever protocol is live. A drop is
    /// usually transient — editing layers in another app (e.g. Work Louder
    /// Input) re-enumerates the board over USB — so we auto-reconnect rather
    /// than treat it as permanent, unless the user deliberately released it.
    private func handleHardwareConnectionChange(_ connected: Bool) {
        if connected {
            hardwareConnected = true
            return
        }
        hardwareConnected = false
        guard !hardwareReleased else { return }
        log("keyboard dropped — reconnecting…")
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        isReconnecting = true
        reconnectTask = Task { @MainActor [weak self] in
            var delayMs: UInt64 = 500
            var attempts = 0
            while !Task.isCancelled {
                guard let self, !self.hardwareReleased else { break }
                if self.attemptConnect() {
                    self.log("🔌 reconnected after re-enumeration")
                    break
                }
                attempts += 1
                if attempts >= Self.maxReconnectAttempts {
                    self.log("gave up reconnecting — hit Reconnect to try again")
                    break
                }
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                delayMs = min(delayMs * 2, 5_000)  // exponential backoff, capped at 5 s
            }
            self?.isReconnecting = false
            self?.reconnectTask = nil
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
    }

    private func teardownHardware() {
        cancelReconnect()
        hardwareDevice?.disconnect()
        hardwareDevice = nil
        hardwareConnected = false
        hardwareName = nil
    }

    /// Deliberately release the board so its raw-HID pipe is free for another
    /// app (e.g. editing layers in Work Louder Input). Parks auto-reconnect
    /// until Reconnect. We only release *our* handle — macOS's own HID binding
    /// clears on the next unplug/replug, not from here.
    func releaseHardwareForEditing() {
        hardwareReleased = true
        teardownHardware()
        log("keyboard released — edit layers freely, then hit Reconnect")
    }

    /// Turn the board off: dark, and staying dark. Also the handoff to another
    /// app (Codex, Work Louder Input), since only one host can drive the
    /// keyboard's JSON-RPC channel at a time — factory keycodes restored,
    /// handle dropped. The lighting the firmware would otherwise resume on its
    /// own is set aside so switching back on returns it.
    func disconnectHardware() {
        hardwareReleased = true
        guard let voai = hardwareDevice as? VOAIDevice else {
            teardownHardware()
            log("keyboard released")
            return
        }
        voai.handBack(restoreKeymap: true) { [weak self] blanked in
            Task { @MainActor in
                guard let self else { return }
                self.rememberBlankedLights(blanked)
                self.teardownHardware()
                self.log("keyboard off — lights out, keys type again")
            }
        }
    }

    /// Called as the app quits. Leaves the board dark rather than letting the
    /// firmware relight it the moment we let go — a keyboard on a desk should
    /// not glow for an app that isn't running. Only restores the keymap when
    /// the user has asked for it, since bound keys are the normal working
    /// state.
    func handBackKeyboardOnQuit() {
        guard let voai = hardwareDevice as? VOAIDevice, hardwareConnected else { return }
        let semaphore = DispatchSemaphore(value: 0)
        // Captured off the main actor: quitting blocks the main thread, so the
        // usual hop back would deadlock against our own wait.
        nonisolated(unsafe) var blanked: [String: String]?
        voai.handBack(restoreKeymap: config.restoreKeyboardOnQuit) {
            blanked = $0
            semaphore.signal()
        }
        // Quitting is synchronous; give the writes a moment to reach the wire.
        _ = semaphore.wait(timeout: .now() + 2.0)
        rememberBlankedLights(blanked)
    }

    /// Records the lighting we switched off, so the next Turn On can put it
    /// back. Written straight through rather than debounced: the two moments
    /// this runs — switching the board off, and quitting — are both moments
    /// where a delayed save might never happen.
    private func rememberBlankedLights(_ blanked: [String: String]?) {
        // A board that was already dark returns nothing; still mark it blanked
        // so switching on relights it rather than leaving a dead keyboard.
        config.savedDeviceLights = blanked ?? config.savedDeviceLights ?? [:]
        saveConfigNow()
    }

    /// Puts the user's own lighting back after a Turn Off, once the board is
    /// answering again. No-op unless we were the ones who blanked it.
    private func restoreDeviceLightsIfBlanked(_ voai: VOAIDevice) {
        guard let saved = config.savedDeviceLights else { return }
        config.savedDeviceLights = nil
        saveConfigNow()
        guard !saved.isEmpty else {
            // Nothing of the user's to restore — light it the way the board
            // ships, so "on" never means a keyboard that stays dark.
            voai.previewLights(VOAIDevice.factoryBacklight, underglow: VOAIDevice.factoryUnderglow)
            return
        }
        voai.restoreLights(saved) { [weak self] in
            Task { @MainActor in self?.log("💡 keyboard lighting restored") }
        }
    }

    /// Semantic input from the pad (v.oai firmware): route key presses into
    /// the same pipeline as event-tap triggers. Logged verbosely until
    /// hardware validates the exact semantics.
    private func handleDeviceEvent(_ event: VOAI.DeviceEvent) {
        switch event {
        case .key(let slot, let action):
            // The device reports agent *slots* ("AG07"), which are not key
            // indices — AG07 is key 11. Translate before dispatching.
            let mapped = VOAI.keyIndex(forAgentSlot: slot)
            // A known slot mapped to nil is the second switch under the wide
            // key — drop it so one press fires one action.
            if mapped == nil, VOAI.agentSlotKeyIndices.indices.contains(slot) { return }
            let index = mapped ?? slot
            log("⌨︎ pad key \(index) (slot \(slot))\(action.map { " act \($0)" } ?? "")")
            switch action {
            case "1":
                controlActivated(.key(index), gesture: .press, phase: .down, fromHardware: true)
            case "0":
                controlActivated(.key(index), gesture: .press, phase: .up, fromHardware: true)
            default:
                // No action field: synthesise a complete press so the binding
                // still fires, accepting that hold-to-talk cannot work.
                controlActivated(.key(index), gesture: .press, phase: .down, fromHardware: true)
                controlActivated(.key(index), gesture: .press, phase: .up, fromHardware: true)
            }
        case .joystick(let angle, let distance):
            handleJoystick(angle: angle, distance: distance)
        case .debug(let text):
            // The firmware emits empty debug frames constantly; only surface
            // the ones that actually say something.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { log("keyboard says: \(trimmed)") }
        case .other(let method):
            // Replies to our own fire-and-forget lighting writes come back as
            // unclaimed messages. They mean "accepted", not "unrecognised".
            let acknowledgements = [VOAI.methodThreadStatus, VOAI.methodRGBConfig,
                                    VOAI.methodLightsPreview]
            if !acknowledgements.contains(method) { log("keyboard message: \(method)") }
        }
    }

    /// Key slots that can host agents (agent keys with LEDs).
    var ledKeySlots: [Int] {
        layout.controls
            .filter { $0.kind == .key && $0.ledIndex != nil && $0.hostsAgents }
            .compactMap { Int($0.id.rawValue.dropFirst("key.".count)) }
            .sorted()
    }

    // MARK: Persistence (debounced)

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            do {
                try self.configStore.save(self.config)
            } catch {
                self.log("config save failed: \(error.localizedDescription)")
            }
        }
    }
}
