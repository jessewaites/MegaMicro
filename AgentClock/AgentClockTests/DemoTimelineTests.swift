import XCTest
@testable import AgentClock

/// Runs the demo script through the planner and the simulated panel at display
/// rate, headless, and prints what is actually on screen second by second.
///
/// This exists because "it feels too fast" is unmeasurable by eye once text is
/// scrolling and pages are rotating — the only way to tell a pacing problem
/// from a rotation bug is to read the timeline.
@MainActor
final class DemoTimelineTests: XCTestCase {

    private func snapshots(at instant: TimeInterval) -> [AgentSnapshot] {
        // Replay the demo script up to `instant` and report the resulting fleet.
        var states: [String: (AgentSnapshot)] = [:]
        var clock: TimeInterval = 0
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        for beat in DemoMode.script {
            clock += beat.after
            if clock > instant { break }
            let key = "\(beat.source)#\(beat.session)"
            let started = states[key]?.startedAt ?? epoch.addingTimeInterval(clock)
            states[key] = AgentSnapshot(key: key, source: beat.source, state: beat.state,
                                        label: beat.project, project: beat.project,
                                        startedAt: started)
        }
        return Array(states.values).sorted { $0.key < $1.key }
    }

    func testPrintDemoTimeline() {
        let clock = SimulatedClock()
        let config = DisplayConfig()
        let fps = 30.0
        let duration = 60.0

        var lastCaption = ""
        var transitions = 0
        var firstShownAt: [String: TimeInterval] = [:]
        var pageDurations: [String: [TimeInterval]] = [:]
        var currentSince: TimeInterval = 0

        print("\n   time  page              text")
        print("   ----  ----------------  ----------------------------")
        for frame in 0...Int(duration * fps) {
            let t = Double(frame) / fps
            clock.apply(PagePlanner.plan(agents: snapshots(at: t), config: config,
                                         panelWidth: 32,
                                         now: Date(timeIntervalSince1970: 1_800_000_000 + t)))
            clock.tick(delta: 1 / fps)

            let caption = clock.currentName
            if caption != lastCaption {
                if !lastCaption.isEmpty {
                    pageDurations[lastCaption, default: []].append(t - currentSince)
                }
                print(String(format: "  %5.1fs  %-16@  %@", t,
                             caption.isEmpty ? "(dark)" as NSString : caption as NSString,
                             "" as NSString))
                transitions += 1
                firstShownAt[caption] = firstShownAt[caption] ?? t
                currentSince = t
                lastCaption = caption
            }
        }

        let held = pageDurations.mapValues { $0.reduce(0, +) / Double($0.count) }
        print("\n  transitions in \(Int(duration))s: \(transitions)")
        for (name, average) in held.sorted(by: { $0.key < $1.key }) {
            print(String(format: "    %-18@ average %.1fs on screen", name as NSString, average))
        }

        // A page you cannot finish reading is a page that was not shown. The
        // scroll has to complete at least one pass in the time the page holds.
        XCTAssertGreaterThan(transitions, 0)
    }

    func testScrollCompletesAtLeastOnePassWithinAPageDuration() {
        // The failure this guards: text long enough that it is still mid-word
        // when the rotation moves on, so a label is never actually readable.
        let text = " AGENTCLOCK NEEDS YOU"
        let width = MatrixFont.width(of: text)
        let travel = Double(width + MatrixRenderer.scrollGap)
        let onePass = travel / MatrixRenderer.scrollPixelsPerSecond
        let pageHold = 7.0 // the device's default appDurationMs

        print("\n  '\(text)' is \(width)px; one scroll pass takes \(String(format: "%.1f", onePass))s "
              + "against a \(pageHold)s page")
        XCTAssertLessThan(onePass, pageHold,
                          "text cannot complete a scroll before the page rotates away")
    }
}
