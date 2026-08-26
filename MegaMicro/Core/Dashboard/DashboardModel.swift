import SwiftUI

/// The dashboard's render + reassign surface, shared by the macOS app and the
/// iOS/watchOS companions. It owns a flat copy of everything the board,
/// tooltips, and activity feed read, plus the pure derivation logic. Both
/// platforms feed it: on macOS `AppState` mirrors its live state in; on iOS the
/// sync client applies each `DashboardSnapshot`. Mutations go out through
/// `onCommand` — applied locally on macOS, sent over the wire on iOS.
@Observable @MainActor
final class DashboardModel {
    // MARK: Mirrored state
    var deviceName: String = ""
    var workspacesRoot: String = NSHomeDirectory() + "/conductor/workspaces"
    var layout: KeyboardLayout = CodexMicroLayout.layout
    var currentFrame: EffectFrame = .uniform(.off, ledCount: CodexMicroLayout.layout.ledCount)

    var sessions: [String: AgentSession] = [:]
    var keyBindings: [Int: KeyAgentBinding] = [:]
    var keyLegends: [ControlID: String] = [:]
    var workspaces: [ConductorWorkspace] = []
    var conductorAgents: [String: ConductorAgentInfo] = [:]
    var cwdBranches: [String: String] = [:]
    var activityFeed: [ActivityFeedItem] = []
    var fleetNotification = FleetNotification(
        state: .idle, headline: "Fleet idle", detail: "No agents are reporting activity.", keySlot: nil)

    var rgbRules: RGBRules = DefaultProfiles.conductor.rgbRules
    var underglow: UnderglowMode = DefaultProfiles.conductor.underglow
    /// Render states as a solid color instead of pulsing/flashing (mirrors the
    /// Mac's `AppConfig.steadyGlow`, synced so companions match).
    var steadyGlow: Bool = false
    /// Which of the (up to three) profile status LEDs are lit on the chassis.
    var activeProfileIndex: Int = 0

    /// Where a reassign/monitor action goes: applied locally on macOS, sent to
    /// the Mac on iOS.
    var onCommand: (SyncCommand) -> Void = { _ in }

    init() {}

    // MARK: Client-side LED animation
    // The Mac doesn't stream the 20 Hz frame; the client re-derives it from the
    // synced state so the key glows and halo animate locally.

    @ObservationIgnored private var renderTimer: Timer?

    /// Begin re-deriving `currentFrame` ~30×/s from the current state. Call on
    /// the iOS/watch client; the macOS app drives its own frame instead.
    func startClientRendering() {
        guard renderTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentFrame = self.renderedFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    /// Agent-hosting keys only, matching the Mac renderer — the printed action
    /// row never holds an agent and keeps its own idle lighting.
    private var ledKeySlots: [Int] {
        layout.controls.compactMap { spec in
            guard spec.kind == .key, spec.ledIndex != nil, spec.hostsAgents,
                  spec.id.rawValue.hasPrefix("key."),
                  let n = Int(spec.id.rawValue.dropFirst("key.".count)) else { return nil }
            return n
        }
    }

    private func resolvedState(under path: String) -> AgentState {
        let normalized = path.hasSuffix("/") ? path : path + "/"
        return sessions.values.filter { session in
            guard let cwd = session.cwd else { return false }
            return cwd == path || cwd.hasPrefix(normalized)
        }.map(\.state).max() ?? .idle
    }

    /// The LED frame for the current state at time `now` — mirrors the Mac's
    /// render loop, minus the physical-device output.
    func renderedFrame(now: Date = Date()) -> EffectFrame {
        let t = now.timeIntervalSinceReferenceDate
        let aggregate = sessions.values.map(\.state).max() ?? .idle
        let aggregateAge = sessions.values
            .filter { $0.state == aggregate }
            .map { now.timeIntervalSince($0.updatedAt) }
            .min() ?? 0
        var perKey: [Int: (state: AgentState, age: TimeInterval)] = [:]
        var unlit: Set<Int> = []
        for slot in ledKeySlots {
            guard let led = layout.control(.key(slot))?.ledIndex else { continue }
            let path: String
            switch keyBindings[slot] {
            case .workspace(let id): path = workspacesRoot + "/" + id
            case .path(let p): path = p
            case nil, .off:
                unlit.insert(led)
                continue
            }
            perKey[led] = (resolvedState(under: path), 0)
        }
        return AnimationRenderer.frame(
            aggregate: aggregate, aggregateAge: aggregateAge,
            perKeyStates: perKey, rules: rgbRules, underglowMode: underglow,
            steadyGlow: steadyGlow,
            unlitLEDs: unlit,
            ledCount: layout.ledCount, t: t)
    }

    // MARK: Apply a synced snapshot (iOS/watch)

    func apply(_ snapshot: DashboardSnapshot) {
        deviceName = snapshot.deviceName
        workspacesRoot = snapshot.workspacesRoot
        sessions = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.key, $0) })
        keyBindings = snapshot.keyBindings
        keyLegends = snapshot.keyLegends
        workspaces = snapshot.workspaces
        conductorAgents = snapshot.conductorAgents
        cwdBranches = snapshot.cwdBranches
        activityFeed = snapshot.activityFeed
        fleetNotification = snapshot.fleetNotification
        rgbRules = snapshot.rgbRules
        underglow = snapshot.underglow
        steadyGlow = snapshot.steadyGlow
    }

    // MARK: Commands

    @discardableResult
    func handleDrop(_ payload: String, onto control: ControlID) -> Bool {
        onCommand(.drop(payload: payload, control: control.rawValue))
        return true
    }

    @discardableResult
    func focus(onSlot slot: Int) -> Bool {
        onCommand(.focus(slot: slot))
        return true
    }

    // MARK: Glyphs & labels (pure — read this model's own state)

    enum OccupantGlyph: Equatable {
        case brand(String)
        case symbol(String)
        case brandPair(primary: String, secondary: String)
    }

    func occupantGlyph(forSlot slot: Int) -> OccupantGlyph? {
        func sessionGlyph(_ session: AgentSession) -> OccupantGlyph {
            BrandIcon.asset(forSource: session.source).map { .brand($0) } ?? .symbol("terminal")
        }
        switch keyBindings[slot] {
        case .off:
            return .symbol("moon.zzz")
        case .workspace(let id):
            if let tool = conductorToolAsset(forWorkspaceID: id) {
                return .brandPair(primary: "conductor", secondary: tool)
            }
            return .brand("conductor")
        case .path(let path):
            if let session = sessions.values.first(where: {
                $0.cwd == path || ($0.cwd?.hasPrefix(path + "/") ?? false)
            }) {
                let environment = path.hasPrefix(workspacesRoot + "/") ? "conductor" : "ghostty-mono"
                if let tool = BrandIcon.asset(forSource: session.source) {
                    return .brandPair(primary: environment, secondary: tool)
                }
                return .brand(environment)
            }
            return nil
        case nil:
            return nil
        }
    }

    func occupantLabel(forSlot slot: Int) -> String? {
        switch keyBindings[slot] {
        case .off: return "off"
        case .workspace(let id): return workspaceDisplayName(forID: id)
        case .path(let path): return folderAgentLabel(forPath: path)
        case nil: return nil
        }
    }

    func conductorToolAsset(forWorkspaceID id: String) -> String? {
        let path = workspacesRoot + "/" + id
        if let session = sessions.values.first(where: {
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

    func workspaceDisplayName(forID id: String) -> String {
        if let workspace = workspaces.first(where: { $0.id == id }) { return workspace.displayName }
        return id.components(separatedBy: "/").last ?? id
    }

    nonisolated static let defaultBranchNames: Set<String> = ["main", "master"]

    nonisolated static func agentLabel(branch: String?, folder: String) -> String {
        guard let branch, !defaultBranchNames.contains(branch.lowercased()) else { return folder }
        return branch
    }

    /// Feature branch when distinctive, else the folder name. The branch is read
    /// from the synced `cwdBranches` (resolved on the Mac), so no git access here.
    func folderAgentLabel(forPath path: String) -> String {
        Self.agentLabel(branch: cwdBranches[path], folder: (path as NSString).lastPathComponent)
    }

    func assignedSession(forSlot slot: Int) -> AgentSession? {
        let path: String
        switch keyBindings[slot] {
        case .workspace(let id): path = workspacesRoot + "/" + id
        case .path(let assignedPath): path = assignedPath
        case nil, .off: return nil
        }
        let normalized = path.hasSuffix("/") ? path : path + "/"
        return sessions.values
            .filter { $0.cwd == path || ($0.cwd?.hasPrefix(normalized) ?? false) }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    func elapsed(since start: Date, now: Date = Date()) -> String {
        let totalSeconds = Int(max(0, now.timeIntervalSince(start)))
        if totalSeconds >= 3600 { return "\(totalSeconds / 3600)h \((totalSeconds % 3600) / 60)m" }
        if totalSeconds >= 60 { return "\(totalSeconds / 60)m \(totalSeconds % 60)s" }
        return "\(totalSeconds)s"
    }

    func projectName(for session: AgentSession) -> String? {
        guard let cwd = session.cwd else { return nil }
        let root = workspacesRoot + "/"
        if cwd.hasPrefix(root), let project = cwd.dropFirst(root.count).split(separator: "/").first {
            return String(project)
        }
        return (cwd as NSString).lastPathComponent
    }

    /// What the agent is working on — the Conductor branch/feature or the
    /// folder's git branch — used for chip/feed labels.
    func workContext(for session: AgentSession) -> String? {
        guard let cwd = session.cwd else { return nil }
        let root = workspacesRoot + "/"
        if cwd.hasPrefix(root) {
            let parts = cwd.dropFirst(root.count).split(separator: "/")
            if parts.count >= 2 { return workspaceDisplayName(forID: "\(parts[0])/\(parts[1])") }
        }
        return folderAgentLabel(forPath: cwd)
    }

    // MARK: Unassigned chips (drag onto a key to assign)

    private var boundWorkspaceIDs: Set<String> {
        Set(keyBindings.values.compactMap { if case .workspace(let id) = $0 { return id }; return nil })
    }

    private func isCovered(_ cwd: String) -> Bool {
        for binding in keyBindings.values {
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

    /// Conductor workspaces not yet placed on a key.
    var unassignedWorkspaces: [ConductorWorkspace] {
        workspaces.filter { !boundWorkspaceIDs.contains($0.id) }
    }

    /// Live agent sessions not covered by any key binding.
    var unassignedSessions: [AgentSession] {
        sessions.values
            .filter { $0.cwd.map { !isCovered($0) } ?? false }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
