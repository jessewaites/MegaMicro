import XCTest
@testable import MegaMicro

final class StateResolverTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func event(_ state: AgentState, source: String = "claude-code",
                       session: String = "s1", cwd: String? = nil,
                       at: Date? = nil, parentSession: String? = nil) -> SessionEvent {
        SessionEvent(source: source, session: session, cwd: cwd, state: state,
                     at: at ?? t0, parentSession: parentSession)
    }

    func testEmptyStoreIsIdle() {
        XCTAssertEqual(SessionStore().resolvedGlobal(now: t0), .idle)
    }

    func testPriorityErrorBeatsWaitingBeatsWorking() {
        let store = SessionStore()
        store.apply(event(.coding, session: "a"))
        XCTAssertEqual(store.resolvedGlobal(now: t0), .coding)
        store.apply(event(.waiting, session: "b"))
        XCTAssertEqual(store.resolvedGlobal(now: t0), .waiting)
        store.apply(event(.error, session: "c"))
        XCTAssertEqual(store.resolvedGlobal(now: t0), .error)
    }

    func testLaterEventReplacesSameSession() {
        let store = SessionStore()
        store.apply(event(.waiting))
        store.apply(event(.success, at: t0.addingTimeInterval(1)))
        XCTAssertEqual(store.resolvedGlobal(now: t0.addingTimeInterval(2)), .success)
    }

    func testSessionDetailsAndStartTimeSurviveSparseUpdates() {
        let store = SessionStore()
        store.apply(SessionEvent(source: "codex", session: "s", cwd: "/project",
                                 state: .thinking, at: t0, agent: "reviewer",
                                 model: "gpt", task: "Review the patch"))
        store.apply(SessionEvent(source: "codex", session: "s", cwd: "/project",
                                 state: .coding, at: t0.addingTimeInterval(30)))
        let session = store.sessions["codex#s"]
        XCTAssertEqual(session?.startedAt, t0)
        XCTAssertEqual(session?.agent, "reviewer")
        XCTAssertEqual(session?.model, "gpt")
        XCTAssertEqual(session?.task, "Review the patch")
    }

    func testSuccessExpiresToIdleAfterTTL() {
        let store = SessionStore()
        store.apply(event(.success))
        XCTAssertEqual(store.resolvedGlobal(now: t0.addingTimeInterval(44)), .success)
        XCTAssertEqual(store.resolvedGlobal(now: t0.addingTimeInterval(46)), .idle)
    }

    func testStaleSessionsAreDropped() {
        let store = SessionStore()
        store.apply(event(.error))
        XCTAssertEqual(store.resolvedGlobal(now: t0.addingTimeInterval(3599)), .error)
        XCTAssertEqual(store.resolvedGlobal(now: t0.addingTimeInterval(3601)), .idle)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testIdleSessionsLingerOneHourThenDrop() {
        let store = SessionStore()
        store.apply(event(.idle))
        // Visible through a quick restart…
        store.expire(now: t0.addingTimeInterval(45 * 60))
        XCTAssertEqual(store.sessions.count, 1)
        // …gone an hour after last activity: no stale-agent museum.
        store.expire(now: t0.addingTimeInterval(61 * 60))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testResolvedUnderPathMatchesPrefixOnly() {
        let store = SessionStore()
        store.apply(event(.waiting, session: "a", cwd: "/Users/j/conductor/workspaces/alpha/src"))
        store.apply(event(.coding, session: "b", cwd: "/Users/j/conductor/workspaces/beta"))
        XCTAssertEqual(store.resolved(underPath: "/Users/j/conductor/workspaces/alpha", now: t0), .waiting)
        XCTAssertEqual(store.resolved(underPath: "/Users/j/conductor/workspaces/beta", now: t0), .coding)
        // "alph" must not prefix-match "alpha"
        XCTAssertEqual(store.resolved(underPath: "/Users/j/conductor/workspaces/alph", now: t0), .idle)
    }

    func testChildAgentsDoNotAffectLighting() {
        let store = SessionStore()
        let path = "/Users/j/conductor/workspaces/alpha"
        store.apply(event(.coding, session: "parent", cwd: path))
        store.apply(event(.waiting, session: "child", cwd: path,
                          parentSession: "parent"))

        XCTAssertEqual(store.lightingSessions.map(\.session), ["parent"])
        XCTAssertEqual(store.resolved(underPath: path, now: t0), .waiting)
        XCTAssertEqual(store.resolved(
            underPath: path, now: t0, includeChildAgents: false), .coding)
    }

    func testRestoreDemotesToIdleAndKeepsIdentity() {
        let store = SessionStore()
        let persisted = [
            AgentSession(source: "codex", session: "/x", cwd: "/x", state: .error, updatedAt: t0),
            AgentSession(source: "claude-code", session: "/y", cwd: "/y", state: .coding, updatedAt: t0),
        ]
        store.restore(persisted)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertTrue(store.sessions.values.allSatisfy { $0.state == .idle },
                      "restored agents must not resurrect stale states")
        // A live session is never clobbered by restore.
        store.apply(event(.waiting, source: "codex", session: "/x", cwd: "/x"))
        store.restore(persisted)
        XCTAssertEqual(store.sessions["codex#/x"]?.state, .waiting)
    }

    func testWireNamesRoundTrip() {
        for state in AgentState.allCases {
            XCTAssertEqual(AgentState(wireName: state.wireName), state)
        }
        XCTAssertNil(AgentState(wireName: "bogus"))
    }

    func testSessionStoreIsBounded() {
        let store = SessionStore()
        for index in 0..<(SessionStore.maximumSessions + 50) {
            store.apply(event(.coding, session: "session-\(index)",
                              at: t0.addingTimeInterval(TimeInterval(index))))
        }
        XCTAssertEqual(store.sessions.count, SessionStore.maximumSessions)
        XCTAssertNil(store.sessions["claude-code#session-0"])
        XCTAssertNotNil(store.sessions["claude-code#session-\(SessionStore.maximumSessions + 49)"])
    }
}
