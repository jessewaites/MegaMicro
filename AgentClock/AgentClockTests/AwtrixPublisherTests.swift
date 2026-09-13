import XCTest
@testable import AgentClock

/// Records every call and can be told to start failing, so the publisher's
/// diffing, edge-triggering and backoff can be checked without a clock.
private actor FakeClock: AwtrixTransport {
    enum Call: Equatable {
        case push(String)
        case delete(String)
        case order([String])
        case notify(String)
        case dismiss(String)
    }

    private(set) var calls: [Call] = []
    private(set) var lastDisabled: [String] = []
    var shouldFail = false

    func setShouldFail(_ value: Bool) { shouldFail = value }
    func drain() -> [Call] { defer { calls = [] }; return calls }
    func disabledApps() -> [String] { lastDisabled }

    struct Failure: Error {}

    private func guardFailure() throws {
        if shouldFail { throw Failure() }
    }

    func pushApp(name: String, payload: Data) async throws {
        try guardFailure(); calls.append(.push(name))
    }
    func deleteApp(name: String) async throws {
        try guardFailure(); calls.append(.delete(name))
    }
    func setOrder(_ order: [String], disabled: [String]) async throws {
        try guardFailure(); lastDisabled = disabled; calls.append(.order(order))
    }
    func notify(payload: Data) async throws {
        try guardFailure()
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        calls.append(.notify(object?["name"] as? String ?? "?"))
    }
    func dismissNotification(named name: String) async throws {
        try guardFailure(); calls.append(.dismiss(name))
    }
}

final class AwtrixPublisherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let heartbeat: TimeInterval = 300

    private func agent(_ key: String, _ state: AgentState,
                       source: String = "claude-code") -> AgentSnapshot {
        AgentSnapshot(key: key, source: source, state: state, label: key,
                      project: "alpha", startedAt: now.addingTimeInterval(-60))
    }

    private func plan(_ agents: [AgentSnapshot]) -> ClockPlan {
        PagePlanner.plan(agents: agents, config: DisplayConfig(), now: now)
    }

    func testFirstApplyPushesEverything() async {
        let clock = FakeClock()
        let publisher = AwtrixPublisher(client: clock)
        let outcome = await publisher.apply(plan([agent("a", .coding)]), heartbeat: heartbeat, now: now)

        XCTAssertTrue(outcome.reachable)
        XCTAssertTrue(outcome.changed)
        let calls = await clock.drain()
        XCTAssertTrue(calls.contains(.push("ac-claude")))
        let disabled = await clock.disabledApps()
        XCTAssertEqual(disabled, AwtrixPublisher.nativeApps)
    }

    func testClearRestoresNativeClockPages() async {
        let clock = FakeClock()
        let publisher = AwtrixPublisher(client: clock)
        _ = await publisher.apply(plan([agent("a", .coding)]), heartbeat: heartbeat, now: now)

        await publisher.clearAll()

        let disabled = await clock.disabledApps()
        let calls = await clock.drain()
        XCTAssertTrue(disabled.isEmpty)
        XCTAssertTrue(calls.contains(.order(AwtrixPublisher.nativeApps)))
    }

    func testUnchangedPlanSendsNothingOnTheSecondPass() async {
        let clock = FakeClock()
        let publisher = AwtrixPublisher(client: clock)
        let fleet = plan([agent("a", .coding)])

        _ = await publisher.apply(fleet, heartbeat: heartbeat, now: now)
        _ = await clock.drain()
        let outcome = await publisher.apply(fleet, heartbeat: heartbeat, now: now.addingTimeInterval(1))

        XCTAssertFalse(outcome.changed)
        let calls = await clock.drain()
        XCTAssertTrue(calls.isEmpty, "re-sent an identical page: \(calls)")
    }

    func testChangedStateRepushesTheAgentPage() async {
        let clock = FakeClock()
        let publisher = AwtrixPublisher(client: clock)
        _ = await publisher.apply(plan([agent("a", .coding)]), heartbeat: heartbeat, now: now)
        _ = await clock.drain()

        _ = await publisher.apply(plan([agent("a", .error)]), heartbeat: heartbeat,
                                  now: now.addingTimeInterval(1))
        let calls = await clock.drain()
        XCTAssertTrue(calls.contains(.push("ac-claude")))
    }

    func testPagesLeavingThePlanAreDeleted() async {
        let clock = FakeClock()
        let publisher = AwtrixPublisher(client: clock)
        // Two projects → project pages exist.
        _ = await publisher.apply(plan([agent("a", .coding),
                                        agent("b", .coding, source: "codex")]),
                                  heartbeat: heartbeat, now: now)
        _ = await clock.drain()

        // Codex goes quiet: its page must be removed, not left glowing with
        // stale data.
        _ = await publisher.apply(plan([agent("a", .coding)]),
                                  heartbeat: heartbeat, now: now.addingTimeInterval(1))
        let calls = await clock.drain()
        XCTAssertTrue(calls.contains(.delete("ac-codex")), "\(calls)")
    }

    func testAllPagesRemovedWhenTheFleetGoesQuiet() async {
        let clock = FakeClock()
        let publisher = AwtrixPublisher(client: clock)
        _ = await publisher.apply(plan([agent("a", .coding)]), heartbeat: heartbeat, now: now)
        _ = await clock.drain()

        _ = await publisher.apply(ClockPlan(), heartbeat: heartbeat, now: now.addingTimeInterval(1))
        let calls = await clock.drain()
        XCTAssertTrue(calls.contains(.delete("ac-claude")))
    }

    // MARK: Interrupts are edge-triggered

    func testWaitingNotificationIsPostedOnceNotEveryTick() async {
        let clock = FakeClock()
        let publisher = AwtrixPublisher(client: clock)
        let waiting = plan([agent("a", .waiting)])

        _ = await publisher.apply(waiting, heartbeat: heartbeat, now: now)
        let first = await clock.drain()
        XCTAssertEqual(first.filter { if case .notify = $0 { return true } else { return false } }.count, 1)

        // Agent state is a level, not an edge — it stays `waiting` for as long
        // as the prompt is unanswered. That must not re-post.
        for offset in 1...5 {
            _ = await publisher.apply(waiting, heartbeat: heartbeat,
                                      now: now.addingTimeInterval(Double(offset)))
        }
        let rest = await clock.drain()
        XCTAssertTrue(rest.isEmpty, "re-posted a held notification: \(rest)")
    }

    func testWaitingNotificationIsRetractedWhenTheAgentUnblocks() async {
        let clock = FakeClock()
        let publisher = AwtrixPublisher(client: clock)
        _ = await publisher.apply(plan([agent("a", .waiting)]), heartbeat: heartbeat, now: now)
        _ = await clock.drain()

        _ = await publisher.apply(plan([agent("a", .coding)]), heartbeat: heartbeat,
                                  now: now.addingTimeInterval(1))
        let calls = await clock.drain()
        XCTAssertTrue(calls.contains(.dismiss("ac-wait-a")), "\(calls)")
    }

    func testSecondBlockedAgentGetsItsOwnNotification() async {
        let clock = FakeClock()
        let publisher = AwtrixPublisher(client: clock)
        _ = await publisher.apply(plan([agent("a", .waiting)]), heartbeat: heartbeat, now: now)
        _ = await clock.drain()

        _ = await publisher.apply(plan([agent("a", .waiting),
                                        agent("b", .waiting, source: "codex")]),
                                  heartbeat: heartbeat, now: now.addingTimeInterval(1))
        let calls = await clock.drain()
        XCTAssertTrue(calls.contains(.notify("ac-wait-b")), "\(calls)")
        XCTAssertFalse(calls.contains(.notify("ac-wait-a")), "re-posted the first agent: \(calls)")
    }

    // MARK: Offline behaviour

    func testFailureBacksOffAndThenRecovers() async {
        let clock = FakeClock()
        await clock.setShouldFail(true)
        let publisher = AwtrixPublisher(client: clock)
        let fleet = plan([agent("a", .coding)])

        let failed = await publisher.apply(fleet, heartbeat: heartbeat, now: now)
        XCTAssertFalse(failed.reachable)
        XCTAssertNotNil(failed.error)

        // Inside the backoff window nothing is attempted at all.
        _ = await clock.drain()
        _ = await publisher.apply(fleet, heartbeat: heartbeat, now: now.addingTimeInterval(0.5))
        let quiet = await clock.drain()
        XCTAssertTrue(quiet.isEmpty, "attempted a send inside the backoff window: \(quiet)")

        // Past the window, with the clock back, everything is re-sent — the
        // failed pass must not have been recorded as delivered.
        await clock.setShouldFail(false)
        let recovered = await publisher.apply(fleet, heartbeat: heartbeat, now: now.addingTimeInterval(60))
        XCTAssertTrue(recovered.reachable)
        let resent = await clock.drain()
        XCTAssertTrue(resent.contains(.push("ac-claude")), "\(resent)")
    }

    func testHeartbeatRepushesEverythingSoARebootedClockHeals() async {
        let clock = FakeClock()
        let publisher = AwtrixPublisher(client: clock)
        let fleet = plan([agent("a", .coding)])
        _ = await publisher.apply(fleet, heartbeat: heartbeat, now: now)
        _ = await clock.drain()

        // Pushed apps live in the device's RAM, so a reboot silently drops them
        // and the publisher's cache would otherwise claim they're still there.
        _ = await publisher.apply(fleet, heartbeat: heartbeat, now: now.addingTimeInterval(heartbeat + 1))
        let resent = await clock.drain()
        XCTAssertTrue(resent.contains(.push("ac-claude")), "\(resent)")
    }

    func testClearAllRemovesPagesAndNotifications() async {
        let clock = FakeClock()
        let publisher = AwtrixPublisher(client: clock)
        _ = await publisher.apply(plan([agent("a", .waiting)]), heartbeat: heartbeat, now: now)
        _ = await clock.drain()

        await publisher.clearAll()
        let calls = await clock.drain()
        XCTAssertTrue(calls.contains(.delete("ac-claude")), "\(calls)")
        XCTAssertTrue(calls.contains(.dismiss("ac-wait-a")), "\(calls)")
    }
}
