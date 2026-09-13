import Foundation
import SwiftUI
import AppKit
import Observation

/// The whole app, in one observable object: agent detection on one side, the
/// pixel clock on the other.
///
/// Ported from MegaMicro's `AppState` but only the agent half — the keyboard,
/// LED animation, HID transport, layer manager and macro engine are all gone.
/// What survives is the part that decides *what is true about your agents*,
/// which is the part that took the longest to get right.
@MainActor
@Observable
final class AppModel {
    static private(set) var shared: AppModel?

    // MARK: State

    var config: AppConfig
    let sessionStore = SessionStore()
    /// Newest first, capped. The menu bar shows a slice of this.
    private(set) var activityFeed: [ActivityFeedItem] = []
    private(set) var workspaces: [ConductorWorkspace] = []
    /// Git branch per working directory — the "what's being worked on" label
    /// for a folder-bound agent. Observed so views update when it resolves.
    var cwdBranches: [String: String] = [:]

    var webhookError: String?
    private(set) var logLines: [String] = []

    /// Clock connection, driven by the publisher from M2 onwards. Reachability
    /// is never fatal: an unplugged clock must not disturb agent detection.
    var clockIsReachable = false
    var clockLastError: String?
    /// Matrix width in pixels, learned from the device. 32 is the TC001; wider
    /// panels exist and change how much text fits before it has to scroll.
    var panelWidth = 32

    /// Quota per provider. Claude's comes from API headers, Codex's off disk —
    /// different mechanisms, same shape.
    var usageByProvider: [String: ProviderUsage] = [:]
    /// While the demo runs, it drives the gauges itself. Real quota barely
    /// moves in the two minutes a demo loop takes, so a live bar would look
    /// broken — frozen at whatever it happens to be.
    var demoUsage: [String: ProviderUsage]?
    @ObservationIgnored let claudeUsage = ClaudeUsageReader()
    @ObservationIgnored private var usageTimer: Timer?

    let awtrix = AwtrixClient()
    let discovery = AwtrixDiscovery()
    /// The on-screen panel. Fed the same plan as the hardware, so it stays
    /// honest whether or not a clock is connected.
    let simulator = SimulatedClock()
    /// Messages injected by MCP/CLI. These join the same plan consumed by the
    /// simulator; a physical clock is an optional second destination.
    @ObservationIgnored var externalNotifications: [ExternalNotification] = []
    @ObservationIgnored let messageAnimationSender = ArtNetSender()
    let messagePlayback = MessagePlayback()
    @ObservationIgnored let idleSleepPreventer = IdleSleepPreventer()

    /// The secret game. It borrows the panel while it runs; detection keeps
    /// going underneath.
    let game = GameMode()
    let pong = PongMode()
    let cameraLab = CameraLab()

    var isDemoRunning = false
    @ObservationIgnored var demoTask: Task<Void, Never>?
    @ObservationIgnored lazy var publisher = AwtrixPublisher(client: awtrix)
    /// One publish in flight at a time; the tick is faster than a round trip
    /// to a sleepy ESP32 and overlapping passes would fight over the diff.
    @ObservationIgnored var isPublishing = false

    var clockStatusText: String {
        if config.clockHost.isEmpty { return "No clock" }
        return clockIsReachable ? config.clockHost : "Unreachable"
    }

    var workspacesRoot = NSHomeDirectory() + "/conductor/workspaces"

    // MARK: Collaborators

    @ObservationIgnored private var webhookServer: WebhookServer?
    @ObservationIgnored private var conductorWatcher: ConductorWatcher?
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var simulatorTimer: Timer?
    @ObservationIgnored private var rosterSaveTask: Task<Void, Never>?
    @ObservationIgnored private var configSaveTask: Task<Void, Never>?
    @ObservationIgnored private var branchProbedAt: [String: Date] = [:]
    @ObservationIgnored private let branchTTL: TimeInterval = 10

    // MARK: Lifecycle

    init(startServices: Bool = true) {
        config = ConfigStore.load()
        Self.shared = self
        guard startServices else { return }
        restoreRoster()
        startWebhookServer()
        startConductorWatcher()
        startTick()
        startUsagePolling()
        refreshClockEndpoint()
        if !config.clockHost.isEmpty {
            Task { await testClockConnection() }
        }
        // `open AgentClock.app --args -demo YES` starts the scripted fleet
        // immediately — for screen recordings, and for driving a real panel
        // through every state without waiting on real agents.
        if UserDefaults.standard.bool(forKey: "demo") {
            Task { @MainActor in self.startDemo() }
        }
    }

    // MARK: Webhook ingestion

    private func startWebhookServer() {
        let server = WebhookServer(port: config.webhookPort) { [weak self] report in
            Task { @MainActor in self?.handle(report) }
        }
        server.sessionsProvider = { [weak self] in
            await MainActor.run {
                guard let self else { return "[]" }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let sessions = Array(self.sessionStore.sessions.values)
                guard let data = try? encoder.encode(sessions) else { return "[]" }
                return String(decoding: data, as: UTF8.self)
            }
        }
        server.showMessageProvider = { [weak self] command in
            guard let self else { return #"{"ok":false,"error":"AgentClock is unavailable"}"# }
            return await self.enqueueExternalMessage(command)
        }
        server.clearMessageProvider = { [weak self] command in
            guard let self else { return #"{"ok":false,"error":"AgentClock is unavailable"}"# }
            return await self.clearExternalMessage(command)
        }
        server.clockStatusProvider = { [weak self] in
            await MainActor.run {
                guard let self else { return #"{"ok":false,"error":"AgentClock is unavailable"}"# }
                return self.externalClockStatus()
            }
        }
        do {
            try server.start()
            webhookServer = server
            webhookError = nil
            log("webhook listening on 127.0.0.1:\(config.webhookPort)")
        } catch {
            // Almost always "port in use" — a second AgentClock, or the port
            // was changed to one MegaMicro already holds.
            webhookError = "Could not listen on port \(config.webhookPort): \(error.localizedDescription)"
            log("webhook failed: \(error.localizedDescription)")
        }
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

    /// Resolve a reported cwd under Conductor's workspaces root through the
    /// branch-name symlink to the real directory, so two reports for the same
    /// workspace agree on one path. Paths elsewhere are left untouched.
    private func canonicalWorkspaceCwd(_ cwd: String?) -> String? {
        guard let cwd, cwd.hasPrefix(workspacesRoot + "/") else { return cwd }
        return URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
    }

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

    private func applySessionEvent(_ event: SessionEvent, simulated: Bool) {
        let key = "\(event.source)#\(event.session)"
        let previousState = sessionStore.sessions[key]?.state
        sessionStore.apply(event)
        guard previousState != event.state, let session = sessionStore.sessions[key] else { return }
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
        guard let transition else { return }
        addFeedItem(for: session, category: transition.0,
                    message: transition.1, simulated: simulated)
    }

    private func addFeedItem(for session: AgentSession, category: ActivityFeedItem.Category,
                             message: String, simulated: Bool) {
        activityFeed.insert(ActivityFeedItem(
            at: Date(), category: category, state: session.state, source: session.source,
            agentName: session.agent ?? Self.readableSourceName(session.source),
            project: workContext(for: session) ?? projectName(for: session),
            keySlot: nil, message: message, simulated: simulated), at: 0)
        if activityFeed.count > 200 { activityFeed.removeLast(activityFeed.count - 200) }
    }

    // MARK: Tick

    /// 1 Hz for the fleet itself. MegaMicro ran at 20 Hz because it drew every
    /// LED frame; the real matrix animates on its own, so this only has to
    /// expire stale sessions, refresh elapsed times, and let the publisher diff.
    private func startTick() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let before = sessionStore.sessions.count
        sessionStore.expire(now: Date())
        if sessionStore.sessions.count != before { scheduleRosterSave() }
        publishToClock()
    }

    /// Quota moves slowly and Claude's costs an API request, so this runs on
    /// its own slow timer rather than the 1 Hz fleet tick.
    private func startUsagePolling() {
        refreshUsage()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUsage() }
        }
    }

    func refreshUsage() {
        // Codex is free — a file read — so it happens every pass.
        let codex = CodexUsageReader.read()
        if !codex.isEmpty || usageByProvider["codex"] == nil {
            usageByProvider["codex"] = codex
        }
        guard config.claudeUsageEnabled else {
            usageByProvider["claude-code"] = nil
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let reading = await self.claudeUsage.read()
            self.usageByProvider["claude-code"] = reading
            if let error = reading.error { self.log("claude usage: \(error)") }
        }
    }

    /// The simulator needs its own, much faster tick — it *is* drawing every
    /// frame, and scrolling at 1 Hz would step rather than scroll. Only runs
    /// while something is watching it.
    private var simulatorTickCount = 0

    func startSimulatorTick() {
        simulatorTickCount += 1
        guard simulatorTickCount == 1 else { return }
        simulatorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.simulator.width = self.panelWidth
                self.simulator.apply(self.currentPlan())
                self.simulator.tick(delta: 1.0 / 30)
            }
        }
    }

    func stopSimulatorTick() {
        simulatorTickCount = max(0, simulatorTickCount - 1)
        guard simulatorTickCount == 0 else { return }
        simulatorTimer?.invalidate()
        simulatorTimer = nil
    }

    // MARK: Conductor

    /// Conductor is optional: with no `~/conductor/workspaces` the watcher just
    /// reports nothing and every agent falls back to folder-name labelling.
    private func startConductorWatcher() {
        let watcher = ConductorWatcher(root: URL(fileURLWithPath: workspacesRoot))
        watcher.onChange = { [weak self] found in
            Task { @MainActor in self?.workspaces = found }
        }
        watcher.start()
        conductorWatcher = watcher
    }

    func workspaceDisplayName(forID id: String) -> String {
        if let workspace = workspaces.first(where: { $0.id == id }) {
            return workspace.displayName
        }
        return id.components(separatedBy: "/").last ?? id
    }

    // MARK: Labels

    /// Default branches aren't distinctive — several agents on `main` would all
    /// read "main". So they're never used as a label.
    nonisolated static let defaultBranchNames: Set<String> = ["main", "master"]

    /// Pure and testable: a feature branch labels the agent; a default branch
    /// or a non-repo falls back to the folder name.
    nonisolated static func agentLabel(branch: String?, folder: String) -> String {
        guard let branch, !defaultBranchNames.contains(branch.lowercased()) else { return folder }
        return branch
    }

    /// Cached, TTL'd git branch lookup. The probe is off the main actor; the
    /// synchronous return is whatever was last resolved.
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

    func folderAgentLabel(forPath path: String) -> String {
        Self.agentLabel(branch: gitBranch(forPath: path),
                        folder: (path as NSString).lastPathComponent)
    }

    func projectName(for session: AgentSession) -> String? {
        guard let cwd = session.cwd else { return nil }
        let root = workspacesRoot + "/"
        if cwd.hasPrefix(root), let project = cwd.dropFirst(root.count).split(separator: "/").first {
            return String(project)
        }
        return (cwd as NSString).lastPathComponent
    }

    /// What the agent is actually working on — the Conductor branch/feature, or
    /// a folder's git branch. This is what a human tracks.
    func workContext(for session: AgentSession) -> String? {
        guard let cwd = session.cwd else { return nil }
        let root = workspacesRoot + "/"
        if cwd.hasPrefix(root) {
            let parts = cwd.dropFirst(root.count).split(separator: "/")
            if parts.count >= 2 { return workspaceDisplayName(forID: "\(parts[0])/\(parts[1])") }
        }
        return folderAgentLabel(forPath: cwd)
    }

    /// Human-readable elapsed time since a session began.
    nonisolated static func elapsed(since start: Date, now: Date = Date()) -> String {
        let totalSeconds = Int(max(0, now.timeIntervalSince(start)))
        if totalSeconds >= 3600 {
            return "\(totalSeconds / 3600)h \((totalSeconds % 3600) / 60)m"
        } else if totalSeconds >= 60 {
            return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
        }
        return "\(totalSeconds)s"
    }

    nonisolated static func readableSourceName(_ source: String) -> String {
        let known: [String: String] = [
            "claude-code": "Claude Code", "codex": "Codex",
            "antigravity-cli": "Antigravity", "github-copilot": "GitHub Copilot",
            "opencode": "OpenCode", "cursor": "Cursor", "cline": "Cline",
            "kiro-cli": "Kiro", "roo-code": "Roo Code", "continue": "Continue",
            "goose": "Goose", "qwen-code": "Qwen Code",
        ]
        return known[source.lowercased()] ?? source
    }

    // MARK: Fleet read model

    /// Sessions worth showing: not idle, not excluded by the user, newest first.
    var liveSessions: [AgentSession] {
        sessionStore.sessions.values
            .filter { $0.state != .idle }
            .filter { session in
                guard let cwd = session.cwd else { return true }
                return !config.fleetExclusions.contains { cwd.hasPrefix($0) }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Highest-priority state across the visible fleet — `AgentState`'s raw
    /// value *is* the priority, so `max()` is the whole resolution rule.
    var fleetState: AgentState {
        liveSessions.map(\.state).max() ?? .idle
    }

    var menuBarSymbol: String {
        switch fleetState {
        case .idle: "square.grid.3x3"
        case .success: "checkmark.square"
        case .coding, .thinking: "square.grid.3x3.fill"
        case .waiting: "exclamationmark.square.fill"
        case .error: "xmark.square.fill"
        }
    }

    // MARK: Roster persistence (survives restarts)

    private var rosterURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentClock/agent-roster.json")
    }

    func restoreRoster() {
        guard let data = try? Data(contentsOf: rosterURL),
              let sessions = try? JSONDecoder().decode([AgentSession].self, from: data) else { return }
        // `restore` demotes everything to idle: we cannot know what an agent did
        // while we were quit, and inventing a state would light the clock wrong.
        sessionStore.restore(sessions)
        if !sessions.isEmpty { log("restored \(sessions.count) known agent(s) from last run") }
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

    // MARK: Config

    func scheduleConfigSave() {
        configSaveTask?.cancel()
        configSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            try? ConfigStore.save(self.config)
        }
    }

    func saveConfigNow() {
        configSaveTask?.cancel()
        try? ConfigStore.save(config)
    }

    func applyAppearance() {
        // NSApp may not exist yet at init, so this is called from onAppear.
        switch config.appearance {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: NSApplication.shared.appearance = nil
        }
    }

    // MARK: Game mode

    func startGame() {
        // The demo would fight the game for the panel.
        if isDemoRunning { stopDemo() }
        if pong.isPlaying { stopPong() }
        if messagePlayback.isPlaying { stopMessagePlayback() }
        if cameraLab.isRunning { stopCameraLab() }
        game.start(host: config.clockHost)
        log("game mode started — the panel is on loan")
    }

    func stopGame() {
        game.stop()
        // Force a full redraw next publish: the panel has been showing Tetris,
        // so everything the publisher believes is up there is wrong.
        Task {
            await publisher.reset()
            publishToClock()
        }
        log("game mode stopped")
    }

    func startPong() {
        if isDemoRunning { stopDemo() }
        if game.isPlaying { stopGame() }
        if messagePlayback.isPlaying { stopMessagePlayback() }
        if cameraLab.isRunning { stopCameraLab() }
        pong.start(host: config.clockHost)
        log("Pong started — player left, computer right")
    }

    func stopPong() {
        guard pong.isPlaying else { return }
        pong.stop()
        Task { await publisher.reset(); publishToClock() }
        log("Pong stopped")
    }

    func restartGame() {
        game.restart(host: config.clockHost)
    }

    // MARK: Camera lab

    func startCameraLab() {
        if isDemoRunning { stopDemo() }
        if game.isPlaying { stopGame() }
        if pong.isPlaying { stopPong() }
        if messagePlayback.isPlaying { stopMessagePlayback() }
        cameraLab.start(host: config.clockHost)
        log("camera lab started — local 32×8 capture")
    }

    func stopCameraLab() {
        guard cameraLab.isRunning else { return }
        cameraLab.stop()
        Task { await publisher.reset(); publishToClock() }
        log("camera lab stopped")
    }

    // MARK: Windows

    func showSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("settings") == true }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Take AgentClock's pages back off the clock on the way out. Synchronous
    /// on purpose: `applicationWillTerminate` does not wait for detached tasks,
    /// and half-cleared pages are worse than none.
    func clearClockOnQuit() {
        game.stop()
        pong.stop()
        messagePlayback.stop()
        idleSleepPreventer.stop()
        guard !config.clockHost.isEmpty else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [publisher] in
            await publisher.clearAll()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1.5)
    }

    // MARK: Log

    func log(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        logLines.append("\(stamp)  \(message)")
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }
}
