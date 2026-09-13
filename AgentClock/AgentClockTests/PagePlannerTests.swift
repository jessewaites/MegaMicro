import XCTest
@testable import AgentClock

final class PagePlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var config: DisplayConfig { DisplayConfig() }

    private func agent(_ key: String, _ state: AgentState,
                       source: String = "claude-code",
                       parent: String? = nil,
                       ageSeconds: TimeInterval = 720) -> AgentSnapshot {
        AgentSnapshot(key: key, source: source, state: state, label: key,
                      project: "megamicro", startedAt: now.addingTimeInterval(-ageSeconds),
                      parentKey: parent)
    }

    private func reading(session: Double? = nil, week: Double? = nil,
                         context: Double? = nil) -> ProviderUsage {
        ProviderUsage(session: session, week: week, context: context)
    }

    // MARK: Nothing to say

    func testIdleFleetWithNoUsageProducesNothing() {
        let plan = PagePlanner.plan(agents: [agent("a", .idle)], config: config, now: now)
        XCTAssertTrue(plan.apps.isEmpty)
        XCTAssertTrue(plan.notifications.isEmpty)
    }

    func testQuotaAloneStillEarnsAPage() {
        // Nothing running, but knowing you are at 80% is worth the panel.
        let plan = PagePlanner.plan(agents: [], usage: ["claude-code": reading(session: 0.8)],
                                    config: config, now: now)
        XCTAssertEqual(plan.apps.map(\.name), ["ac-claude"])
    }

    // MARK: One page per provider

    func testOneProviderGetsOnePage() {
        let plan = PagePlanner.plan(agents: [agent("a", .coding)], config: config, now: now)
        XCTAssertEqual(plan.apps.map(\.name), ["ac-claude"])
    }

    func testTwoProvidersGetAPageEachInAStableOrder() {
        // Order must not depend on who is loudest, or the rotation reshuffles
        // under your eye and you can never learn what is coming next.
        let plan = PagePlanner.plan(
            agents: [agent("b", .error, source: "codex"), agent("a", .coding)],
            config: config, now: now)
        XCTAssertEqual(plan.apps.map(\.name), ["ac-claude", "ac-codex"])

        let flipped = PagePlanner.plan(
            agents: [agent("b", .waiting, source: "codex"), agent("c", .coding)],
            config: config, now: now)
        XCTAssertEqual(flipped.apps.map(\.name), ["ac-claude", "ac-codex"])
    }

    func testAnUnknownProviderStillGetsAPage() {
        let plan = PagePlanner.plan(agents: [agent("a", .coding, source: "gemini-cli")],
                                    config: config, now: now)
        XCTAssertEqual(plan.apps.count, 1)
        XCTAssertTrue(plan.apps[0].name.hasPrefix("ac-"))
    }

    // MARK: Folding sessions into a page

    func testSubagentsAreCrewNotMainAgents() {
        let model = PagePlanner.model(
            for: "claude-code",
            agents: [agent("boss", .coding),
                     agent("kid1", .thinking, parent: "boss"),
                     agent("kid2", .waiting, parent: "boss")],
            usage: nil)
        XCTAssertEqual(model.state, .coding, "the page's state is the main agent's")
        XCTAssertEqual(model.subagents, [.thinking, .waiting])
    }

    func testCrewKeepsItsOrderAsAgentsComeAndGo() {
        // Oldest first, so a subagent holds its position rather than jumping
        // when a sibling finishes.
        let model = PagePlanner.model(
            for: "claude-code",
            agents: [agent("boss", .coding),
                     agent("new", .waiting, parent: "boss", ageSeconds: 10),
                     agent("old", .thinking, parent: "boss", ageSeconds: 900)],
            usage: nil)
        XCTAssertEqual(model.subagents, [.thinking, .waiting])
    }

    func testPageStateIsTheWorstAmongMainAgents() {
        let model = PagePlanner.model(
            for: "claude-code",
            agents: [agent("a", .coding), agent("b", .waiting)],
            usage: nil)
        XCTAssertEqual(model.state, .waiting)
    }

    func testSessionQuotaWinsOverWeekly() {
        // The five-hour window is the one about to bite.
        let model = PagePlanner.model(for: "claude-code", agents: [],
                                      usage: reading(session: 0.7, week: 0.2))
        XCTAssertEqual(model.quota, 0.7)
    }

    func testWeeklyIsUsedWhenThereIsNoSessionWindow() {
        // Codex's plan often reports only a weekly window.
        let model = PagePlanner.model(for: "codex", agents: [], usage: reading(week: 0.09))
        XCTAssertEqual(model.quota, 0.09)
    }

    // MARK: Pages are drawn, not typed

    func testPagesCarryDrawCommandsAndNoText() {
        let plan = PagePlanner.plan(agents: [agent("a", .coding)],
                                    usage: ["claude-code": reading(session: 0.5)],
                                    config: config, now: now)
        let page = plan.apps[0].page
        XCTAssertTrue(page.text.isEmpty)
        XCTAssertNil(page.icon, "the mark is drawn, not referenced")
        XCTAssertFalse(page.draw.isEmpty)
    }

    func testEveryPageFitsTheDevicePayloadLimit() throws {
        let crowd = (0..<20).map { agent("kid\($0)", .coding, parent: "boss", ageSeconds: 60) }
        let plan = PagePlanner.plan(
            agents: [agent("boss", .error)] + crowd
                + [agent("cx", .waiting, source: "codex")],
            usage: ["claude-code": reading(session: 0.99, context: 0.99),
                    "codex": reading(week: 0.5, context: 0.4)],
            config: config, now: now)
        for app in plan.apps {
            XCTAssertLessThanOrEqual(try app.page.payload().count,
                                     AwtrixClient.maximumPayloadBytes, app.name)
        }
        for notification in plan.notifications {
            XCTAssertLessThanOrEqual(try notification.page.payload().count,
                                     AwtrixClient.maximumPayloadBytes, notification.name)
        }
    }

    /// The regression a mock clock caught once already: a page must be
    /// byte-identical between ticks when nothing has changed, or the publisher
    /// rewrites it constantly and the panel flickers.
    func testPagesAreStableWhenNothingChanges() throws {
        let agents = [agent("boss", .coding), agent("kid", .thinking, parent: "boss")]
        let usage = ["claude-code": reading(session: 0.27)]
        let first = PagePlanner.plan(agents: agents, usage: usage, config: config, now: now)
        for offset in [1.0, 30.0, 300.0] {
            let later = PagePlanner.plan(agents: agents, usage: usage, config: config,
                                         now: now.addingTimeInterval(offset))
            XCTAssertEqual(try first.apps.map { try $0.page.payload() },
                           try later.apps.map { try $0.page.payload() },
                           "page changed \(Int(offset))s in with no state change")
        }
    }

    func testQuotaChangeRedrawsThePage() throws {
        let agents = [agent("a", .coding)]
        let low = PagePlanner.plan(agents: agents, usage: ["claude-code": reading(session: 0.2)],
                                   config: config, now: now)
        let high = PagePlanner.plan(agents: agents, usage: ["claude-code": reading(session: 0.9)],
                                    config: config, now: now)
        XCTAssertNotEqual(try low.apps[0].page.payload(), try high.apps[0].page.payload())
    }

    // MARK: Interrupts

    func testWaitingProducesAHeldWakingInterrupt() {
        let plan = PagePlanner.plan(agents: [agent("claude-code#s1", .waiting)],
                                    config: config, now: now)
        XCTAssertEqual(plan.notifications.count, 1)
        let notification = plan.notifications[0]
        XCTAssertEqual(notification.name, "ac-wait-claude-code-s1")
        XCTAssertEqual(notification.page.hold, true)
        XCTAssertEqual(notification.page.wakeup, true)
        XCTAssertEqual(notification.page.stack, true)
        XCTAssertNil(notification.page.durationMs, "a held interrupt must not also expire")
        XCTAssertFalse(notification.page.draw.isEmpty)
    }

    func testSuccessInterruptNeverWakesADarkPanel() {
        var settings = config
        settings.notifyOnSuccess = true
        let plan = PagePlanner.plan(agents: [agent("a", .success)], config: settings, now: now)
        XCTAssertEqual(plan.notifications.first?.page.wakeup, false)
        XCTAssertEqual(plan.notifications.first?.page.hold, false)
        XCTAssertEqual(plan.notifications.first?.page.durationMs, 8000)
    }

    func testDisabledInterruptsProduceNothing() {
        var settings = config
        settings.notifyOnWaiting = false
        settings.notifyOnError = false
        let plan = PagePlanner.plan(
            agents: [agent("a", .waiting), agent("b", .error, source: "codex")],
            config: settings, now: now)
        XCTAssertTrue(plan.notifications.isEmpty)
    }

    func testSoundsOnlyWhenEnabled() {
        XCTAssertNil(PagePlanner.plan(agents: [agent("a", .waiting)], config: config, now: now)
            .notifications[0].page.soundRtttl)
        var loud = config
        loud.soundsEnabled = true
        XCTAssertNotNil(PagePlanner.plan(agents: [agent("a", .waiting)], config: loud, now: now)
            .notifications[0].page.soundRtttl)
    }

    // MARK: Names

    func testProviderNamesAreShortAndStable() {
        XCTAssertEqual(PagePlanner.shortName(for: "claude-code"), "claude")
        XCTAssertEqual(PagePlanner.shortName(for: "codex"), "codex")
        XCTAssertFalse(PagePlanner.shortName(for: "Some Weird CLI!").contains(" "))
    }

    func testNamesAvoidTheReservedWord() {
        XCTAssertNotEqual(ClockName.sanitize("active", prefix: ""), "active")
    }
}
