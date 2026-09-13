import Foundation
import Observation

/// An on-screen stand-in for the panel.
///
/// It takes the same `ClockPlan` the publisher sends to the hardware and
/// behaves the way the device does: pages take turns in a rotation, a
/// notification interrupts and jumps the queue, a held notification stays until
/// it is retracted. That fidelity is the point — if the simulator is merely "a
/// preview of one page", it can't show you that your rotation is too long or
/// that an interrupt never clears.
@MainActor
@Observable
final class SimulatedClock {
    /// What is on screen right now.
    private(set) var canvas = PixelCanvas()
    /// Name of the page or notification being shown, for the caption.
    private(set) var currentName: String = ""
    private(set) var isShowingNotification = false
    /// Nothing to show — the panel would be running its own clock face here.
    private(set) var isIdle = true

    var width = 32 {
        didSet { if width != oldValue { canvas = PixelCanvas(width: width, height: 8) } }
    }

    /// Device default app duration; AWTRIX ships 7 seconds.
    var defaultDurationMs = 7000

    /// While set, the panel plays the opening titles instead of the plan. The
    /// intro is a canned animation rather than anything the fleet produced, so
    /// it sits in front of the normal rendering rather than inside it.
    private(set) var introStartedAt: TimeInterval?
    var isPlayingIntro: Bool { introStartedAt != nil }

    func startIntro() {
        introStartedAt = now
        currentName = "intro"
    }

    func stopIntro() {
        introStartedAt = nil
    }

    private var apps: [PlannedApp] = []
    /// Interrupts still to show, in arrival order — the device queues them.
    private var queue: [PlannedNotification] = []
    private var showing: PlannedNotification?
    private var heldNames: Set<String> = []

    private var pageIndex = 0
    private var pageStartedAt: TimeInterval = 0
    private var now: TimeInterval = 0

    // MARK: Plan input

    /// Mirror a plan onto the simulated panel. Diffed the same way the real
    /// publisher diffs, so an unchanged plan doesn't restart the rotation —
    /// otherwise the page under your eye would reset every tick.
    func apply(_ plan: ClockPlan) {
        if apps.map(\.name) != plan.apps.map(\.name) {
            // Keep showing the same page across a re-plan when it survives.
            let currentPageName = apps.indices.contains(pageIndex) ? apps[pageIndex].name : nil
            apps = plan.apps
            pageIndex = apps.firstIndex { $0.name == currentPageName } ?? 0
            if pageIndex >= apps.count { pageIndex = 0 }
        } else {
            apps = plan.apps
        }

        let wanted = plan.notificationNames
        // A named notification is replaceable. Text Lab deliberately reuses
        // its ID so it does not fill the queue; changing its text or entrance
        // should update the visible notification and replay from frame zero.
        if let visible = showing,
           let replacement = plan.notifications.first(where: { $0.name == visible.name }),
           replacement.page != visible.page {
            showing = replacement
            pageStartedAt = now
        }
        for index in queue.indices {
            if let replacement = plan.notifications.first(where: { $0.name == queue[index].name }) {
                queue[index] = replacement
            }
        }
        for notification in plan.notifications where !heldNames.contains(notification.name) {
            heldNames.insert(notification.name)
            queue.append(notification)
        }
        // Retracted: drop from the queue, and clear it off screen if showing.
        for name in heldNames.subtracting(wanted) {
            heldNames.remove(name)
            queue.removeAll { $0.name == name }
            if showing?.name == name { showing = nil }
        }

        isIdle = apps.isEmpty && showing == nil && queue.isEmpty
    }

    func reset() {
        apps = []
        queue = []
        showing = nil
        heldNames = []
        pageIndex = 0
        canvas.clear()
        currentName = ""
        isIdle = true
    }

    // MARK: Frame

    /// Advance and redraw. Driven at display rate so scrolling looks like
    /// scrolling rather than stepping.
    func tick(delta: TimeInterval) {
        now += delta

        if let started = introStartedAt {
            let elapsed = now - started
            if elapsed >= IntroAnimation.total {
                introStartedAt = nil
            } else {
                canvas = IntroAnimation.frame(at: elapsed, width: width)
                currentName = "intro"
                isShowingNotification = false
                isIdle = false
                return
            }
        }

        advanceIfNeeded()

        if let showing {
            isShowingNotification = true
            currentName = showing.name
            canvas = MatrixRenderer.render(showing.page, width: width, height: 8,
                                           time: now - pageStartedAt)
        } else if apps.indices.contains(pageIndex) {
            isShowingNotification = false
            let app = apps[pageIndex]
            currentName = app.name
            canvas = MatrixRenderer.render(app.page, width: width, height: 8,
                                           time: now - pageStartedAt)
        } else {
            isShowingNotification = false
            currentName = ""
            canvas.clear()
        }
        isIdle = apps.isEmpty && showing == nil && queue.isEmpty
    }

    private func advanceIfNeeded() {
        let elapsed = now - pageStartedAt

        if let current = showing {
            // A held notification never times out; only a retraction — handled
            // in `apply` — takes it down. That is the behaviour worth being
            // able to see without hardware.
            if current.page.hold == true { return }
            if elapsed >= current.page.holdSeconds(default: defaultDurationMs) {
                heldNames.remove(current.name)
                showing = nil
                pageStartedAt = now
            }
            return
        }

        // Interrupts jump the queue: take one the moment the current page ends,
        // rather than waiting for the whole rotation.
        if !queue.isEmpty {
            showing = queue.removeFirst()
            pageStartedAt = now
            return
        }

        guard !apps.isEmpty else {
            pageStartedAt = now
            return
        }
        let page = apps[min(pageIndex, apps.count - 1)].page
        if elapsed >= page.holdSeconds(default: defaultDurationMs) || pageIndex >= apps.count {
            pageIndex = (pageIndex + 1) % apps.count
            pageStartedAt = now
        }
    }
}
