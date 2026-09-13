import Foundation

/// A session, reduced to exactly what the matrix needs. Building this on the
/// model side (where Conductor workspaces and git branches live) keeps the
/// planner pure: no filesystem, no network, no clock beyond the `now` passed
/// in — so every page and interrupt below is unit-testable without hardware.
struct AgentSnapshot: Equatable, Sendable {
    /// `source#session`, the stable identity used to name held interrupts.
    let key: String
    /// Provider id, e.g. "claude-code" — chooses the mark.
    let source: String
    let state: AgentState
    /// What a human calls this work: Conductor feature, git branch, or folder.
    let label: String
    /// Project the work belongs to.
    let project: String
    let startedAt: Date
    /// Set when this session is a subagent working under another one.
    var parentKey: String? = nil

    var isSubagent: Bool { parentKey != nil }
}

/// What the clock should be showing right now.
struct ClockPlan: Equatable, Sendable {
    var apps: [PlannedApp] = []
    var notifications: [PlannedNotification] = []

    /// Names of every app in the plan — the publisher deletes anything on the
    /// device that isn't here.
    var appNames: Set<String> { Set(apps.map(\.name)) }
    var notificationNames: Set<String> { Set(notifications.map(\.name)) }
}

struct PlannedApp: Equatable, Sendable {
    let name: String
    let page: ClockPage
}

struct PlannedNotification: Equatable, Sendable {
    let name: String
    let page: ClockPage
}

/// Turns the fleet into pages. Pure.
///
/// One page per provider, rotating — the shape the panel wanted all along.
/// 32×8 cannot hold two providers at once without shrinking everything past
/// legibility, but it holds one comfortably: its mark, a small creature per
/// subagent, and a quota bar.
///
/// Pages are *drawn* by AgentClock rather than typed for the firmware. Each is
/// rendered to a `PixelCanvas` — the same one the on-screen simulator shows —
/// and encoded as `draw` commands. That is what lets one page carry a mark, a
/// crew and a gauge at once, and it means the simulator cannot drift from the
/// hardware, because there is only one picture.
enum PagePlanner {
    /// Prefix on everything AgentClock puts on the device, so its pages are
    /// identifiable in the clock's own app list and a stray delete can never
    /// touch someone's weather app.
    static let appPrefix = "ac-"

    /// Providers worth a page, in rotation order.
    static let providerOrder = ["claude-code", "codex"]

    static func plan(agents: [AgentSnapshot],
                     usage: [String: ProviderUsage] = [:],
                     config: DisplayConfig,
                     panelWidth: Int = 32,
                     now: Date = Date()) -> ClockPlan {
        var plan = ClockPlan()
        let live = agents.filter { $0.state != .idle }

        // A provider earns a page if it has something running, or if we know
        // its quota — the bar is worth showing even when nothing is active.
        var sources = Set(live.map(\.source))
        for (source, reading) in usage where !reading.isEmpty { sources.insert(source) }
        guard !sources.isEmpty else { return plan }

        let ordered = sources.sorted { left, right in
            let leftRank = providerOrder.firstIndex(of: left) ?? providerOrder.count
            let rightRank = providerOrder.firstIndex(of: right) ?? providerOrder.count
            return leftRank == rightRank ? left < right : leftRank < rightRank
        }

        for source in ordered {
            let mine = live.filter { $0.source == source }
            let model = model(for: source, agents: mine, usage: usage[source])
            let canvas = ProviderPage.render(model, style: config.providerStyle,
                                             colors: config.stateColors,
                                             gauge: config.gaugeColors, width: panelWidth)
            var page = ClockPage(text: "", icon: nil, textColor: "#000000",
                                 durationMs: config.pageDurationMs, scroll: nil)
            page.draw = canvas.drawCommands()
            plan.apps.append(PlannedApp(name: appPrefix + shortName(for: source), page: page))
        }

        plan.notifications = notifications(live, config: config, panelWidth: panelWidth)
        return plan
    }

    /// Fold one provider's sessions into a page's worth of facts.
    static func model(for source: String, agents: [AgentSnapshot],
                      usage: ProviderUsage?) -> ProviderPage.Model {
        let mains = agents.filter { !$0.isSubagent }
        let crew = agents.filter(\.isSubagent)
        return ProviderPage.Model(
            source: source,
            // Worst state among the provider's own sessions: AgentState's raw
            // value is the priority, so `max()` is the whole rule.
            state: mains.map(\.state).max() ?? agents.map(\.state).max() ?? .idle,
            // Oldest first, so a subagent keeps its position as others come and
            // go rather than shuffling under your eye.
            subagents: crew.sorted { $0.startedAt < $1.startedAt }.map(\.state),
            quota: usage?.session ?? usage?.week ?? 0,
            context: usage?.context ?? 0)
    }

    /// Short, stable app names — these travel in a URL path and are matched
    /// exactly on delete.
    static func shortName(for source: String) -> String {
        switch source {
        case "claude-code", "claude": "claude"
        case "codex": "codex"
        default: ClockName.sanitize(source, prefix: "")
        }
    }

    // MARK: Interrupts

    /// The feature that justifies the hardware: when an agent stops and waits
    /// for you, the panel holds on it until you deal with it, and clears the
    /// instant you do.
    static func notifications(_ agents: [AgentSnapshot], config: DisplayConfig,
                              panelWidth: Int) -> [PlannedNotification] {
        agents.compactMap { agent in
            switch agent.state {
            case .waiting where config.notifyOnWaiting:
                return interrupt(agent, prefix: "wait-", hold: config.holdWaiting,
                                 wakeup: config.wakeOnWaiting,
                                 sound: config.soundsEnabled ? Sounds.waiting : nil,
                                 config: config, panelWidth: panelWidth)
            case .error where config.notifyOnError:
                return interrupt(agent, prefix: "err-", hold: config.holdError, wakeup: false,
                                 sound: config.soundsEnabled ? Sounds.error : nil,
                                 config: config, panelWidth: panelWidth)
            case .success where config.notifyOnSuccess:
                // Never wakes a dark panel: nobody wants the room lit at 2am
                // because a task finished.
                return interrupt(agent, prefix: "ok-", hold: false, wakeup: false,
                                 sound: config.soundsEnabled ? Sounds.success : nil,
                                 config: config, panelWidth: panelWidth)
            default:
                return nil
            }
        }
    }

    private static func interrupt(_ agent: AgentSnapshot, prefix: String,
                                  hold: Bool, wakeup: Bool, sound: String?,
                                  config: DisplayConfig, panelWidth: Int) -> PlannedNotification {
        let name = ClockName.sanitize(agent.key, prefix: appPrefix + prefix)
        // The interrupt is the same picture as the page, in the alert state:
        // the mark you already recognise, with its eyes gone amber. Nothing to
        // read, nothing to wait for while it scrolls.
        let model = ProviderPage.Model(source: agent.source, state: agent.state,
                                       subagents: [], quota: 0, context: 0)
        let canvas = ProviderPage.render(model, style: .markOnly,
                                         colors: config.stateColors,
                                         gauge: config.gaugeColors, width: panelWidth)
        var page = ClockPage(text: "", icon: nil, textColor: "#000000",
                             durationMs: hold ? nil : 8000, scroll: nil)
        page.draw = canvas.drawCommands()
        page.name = name
        page.hold = hold
        // Queue rather than replace: two agents blocking at once should both
        // get said, not have the second silently eat the first.
        page.stack = true
        page.wakeup = wakeup
        page.soundRtttl = sound
        return PlannedNotification(name: name, page: page)
    }

    /// Short RTTTL melodies — the panel's buzzer is loud, so these are terse
    /// and off unless the user asks for them.
    enum Sounds {
        static let waiting = "wait:d=4,o=5,b=180:8e6,8p,8e6"
        static let error = "err:d=4,o=5,b=140:8c6,8g5,8e5"
        static let success = "ok:d=4,o=5,b=200:16c6,16e6,16g6"
    }
}
