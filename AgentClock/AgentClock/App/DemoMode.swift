import Foundation

/// A scripted fleet, for iterating on the display without waiting for real
/// agents to do something interesting.
///
/// Written around the provider pages, which is what the panel actually shows:
/// it opens with the titles, then builds one Claude page up from a single agent
/// to a full crew, blocks it, clears it, and finally brings Codex in so the
/// rotation has two pages to alternate between.
///
/// Demo events go through exactly the same path as real ones — `injectState`
/// into the session store — so what you see here is what a real fleet in the
/// same shape would produce, on the simulator and on the hardware at once.
enum DemoMode {
    struct Beat {
        /// Seconds after the previous beat.
        let after: TimeInterval
        let source: String
        let session: String
        /// Set for a subagent, naming the session it works under.
        let parent: String?
        let project: String
        let state: AgentState
        /// Quota to show for this provider at this beat, 0...1.
        let quota: Double?
        /// Shown in the log so the script is followable while it runs.
        let note: String

        init(after: TimeInterval, source: String, session: String, parent: String? = nil,
             project: String, state: AgentState, quota: Double? = nil, note: String) {
            self.after = after
            self.source = source
            self.session = session
            self.parent = parent
            self.project = project
            self.state = state
            self.quota = quota
            self.note = note
        }
    }

    /// Demo agents live under a directory that does not exist, which is the
    /// point: `projectName` falls back to the last path component, so the
    /// labels are stable and no real repository is touched or read.
    static let root = "/tmp/AgentClock Demo"

    static func cwd(for project: String) -> String { "\(root)/\(project)" }

    /// Paced for watching. The arc: one agent, then a crew growing under it,
    /// then a block that holds the panel, then release, then Codex arrives and
    /// the rotation has somewhere to go.
    static let script: [Beat] = [
        // Open with a tour of the states, so the eyes visibly cycle through
        // every colour before anything else happens. Without this the eyes
        // change so rarely that nobody notices they mean anything.
        .init(after: 1.0, source: "claude-code", session: "boss", project: "megamicro",
              state: .thinking, quota: 0.12, note: "thinking — eyes blue"),
        .init(after: 2.2, source: "claude-code", session: "boss", project: "megamicro",
              state: .coding, quota: 0.15, note: "coding — eyes cyan"),
        .init(after: 2.2, source: "claude-code", session: "boss", project: "megamicro",
              state: .waiting, quota: 0.18, note: "waiting — eyes amber"),
        .init(after: 2.2, source: "claude-code", session: "boss", project: "megamicro",
              state: .error, quota: 0.20, note: "error — eyes red"),
        .init(after: 2.2, source: "claude-code", session: "boss", project: "megamicro",
              state: .success, quota: 0.22, note: "done — eyes green"),
        .init(after: 2.2, source: "claude-code", session: "boss", project: "megamicro",
              state: .coding, quota: 0.25, note: "…and back to work"),

        .init(after: 3, source: "claude-code", session: "sub1", parent: "boss",
              project: "megamicro", state: .thinking, quota: 0.33, note: "first subagent spawns"),
        .init(after: 2.5, source: "claude-code", session: "sub2", parent: "boss",
              project: "megamicro", state: .coding, quota: 0.38, note: "second subagent"),
        .init(after: 2.5, source: "claude-code", session: "sub3", parent: "boss",
              project: "megamicro", state: .coding, quota: 0.43, note: "third — the crew fills out"),

        .init(after: 4, source: "claude-code", session: "sub2", parent: "boss",
              project: "megamicro", state: .success, quota: 0.48, note: "one finishes"),
        .init(after: 3, source: "claude-code", session: "boss", project: "megamicro",
              state: .waiting, quota: 0.53, note: "Claude needs permission → the panel holds on it"),
        .init(after: 7, source: "claude-code", session: "boss", project: "megamicro",
              state: .coding, quota: 0.58, note: "you answered → the hold clears"),

        .init(after: 3, source: "codex", session: "cx", project: "agentclock",
              state: .thinking, quota: 0.11, note: "Codex joins → two pages now rotate"),
        .init(after: 3, source: "codex", session: "cx", project: "agentclock",
              state: .coding, quota: 0.17, note: "Codex starts editing"),
        .init(after: 4, source: "codex", session: "cx", project: "agentclock",
              state: .error, quota: 0.23, note: "Codex hits an error"),
        .init(after: 4, source: "codex", session: "cx", project: "agentclock",
              state: .coding, quota: 0.29, note: "Codex recovers"),

        .init(after: 4, source: "claude-code", session: "sub1", parent: "boss",
              project: "megamicro", state: .success, quota: 0.63, note: "crew winds down"),
        .init(after: 2, source: "claude-code", session: "sub3", parent: "boss",
              project: "megamicro", state: .success, quota: 0.68, note: "…"),
        .init(after: 3, source: "claude-code", session: "boss", project: "megamicro",
              state: .success, quota: 0.73, note: "Claude finishes"),
        .init(after: 3, source: "codex", session: "cx", project: "agentclock",
              state: .success, quota: 0.35, note: "Codex finishes"),

        .init(after: 3, source: "claude-code", session: "boss", project: "megamicro",
              state: .idle, quota: 0.78, note: "quiet…"),
        .init(after: 0.2, source: "claude-code", session: "sub1", parent: "boss",
              project: "megamicro", state: .idle, quota: 0.83, note: ""),
        .init(after: 0.2, source: "claude-code", session: "sub2", parent: "boss",
              project: "megamicro", state: .idle, quota: 0.88, note: ""),
        .init(after: 0.2, source: "claude-code", session: "sub3", parent: "boss",
              project: "megamicro", state: .idle, quota: 0.93, note: ""),
        .init(after: 0.5, source: "codex", session: "cx", project: "agentclock",
              state: .idle, quota: 0.41, note: "…panel hands the rotation back"),
        .init(after: 4, source: "claude-code", session: "boss", project: "megamicro",
              state: .idle, quota: 0.95, note: "looping"),
    ]

    /// Session keys the demo owns, so stopping it can remove exactly those and
    /// leave any real agents alone.
    static var sessionKeys: Set<String> {
        Set(script.map { "\($0.source)#\($0.session)" })
    }
}

extension AppModel {
    func toggleDemo() {
        isDemoRunning ? stopDemo() : startDemo()
    }

    func startDemo() {
        guard !isDemoRunning else { return }
        isDemoRunning = true
        log("demo mode started")
        simulator.startIntro()
        runDemo()
    }

    func stopDemo() {
        guard isDemoRunning else { return }
        isDemoRunning = false
        demoTask?.cancel()
        demoTask = nil
        messageAnimationSender.disconnect()
        simulator.stopIntro()
        demoUsage = nil
        // Remove only the demo's own sessions; a real agent that reported
        // while the demo ran keeps its place.
        for key in DemoMode.sessionKeys { sessionStore.remove(sessionKey: key) }
        log("demo mode stopped")
    }

    private func runDemo() {
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                // Titles first, then the fleet builds up behind them. Gauges
                // reset each loop so the bars climb again rather than starting
                // full.
                await MainActor.run { self?.demoUsage = [:] }
                await self?.simulator.startIntro()
                if let self, !self.config.clockHost.isEmpty {
                    await self.playDemoIntroOnClock()
                } else {
                    try? await Task.sleep(for: .seconds(IntroAnimation.total))
                }
                guard !Task.isCancelled else { return }

                for beat in DemoMode.script {
                    try? await Task.sleep(for: .seconds(beat.after))
                    guard !Task.isCancelled else { return }
                    guard let self, self.isDemoRunning else { return }
                    self.injectState(beat.state,
                                     source: beat.source,
                                     session: beat.session,
                                     cwd: DemoMode.cwd(for: beat.project),
                                     parentSession: beat.parent)
                    if let quota = beat.quota {
                        var usage = self.demoUsage ?? [:]
                        usage[beat.source] = ProviderUsage(session: quota, week: quota * 0.6,
                                                           context: quota * 0.8)
                        self.demoUsage = usage
                    }
                    if !beat.note.isEmpty { self.log("demo: \(beat.note)") }
                }
            }
        }
    }

    /// The simulator has always played the opening titles; stream those exact
    /// frames to hardware too when Art-Net is available.
    private func playDemoIntroOnClock() async {
        let frameRate = 30.0
        let frameCount = Int(IntroAnimation.total * frameRate)
        messageAnimationSender.connect(host: config.clockHost)
        for frame in 0...frameCount {
            guard !Task.isCancelled, isDemoRunning else { break }
            let time = Double(frame) / frameRate
            messageAnimationSender.send(IntroAnimation.frame(at: time, width: panelWidth))
            try? await Task.sleep(for: .seconds(1 / frameRate))
        }
        messageAnimationSender.disconnect()
    }
}
