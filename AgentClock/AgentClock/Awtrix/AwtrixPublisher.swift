import Foundation

/// Gets a `ClockPlan` onto the device, sending as little as possible.
///
/// Three rules do all the work here:
///
/// 1. **Only send changes.** Pages are compared by their serialized bytes, so a
///    plan that re-renders identically costs nothing. The clock imposes no rate
///    limit, but a page rewritten every second is a page that flickers.
/// 2. **Interrupts are edge-triggered.** Agent state is a level — an errored
///    session stays errored for an hour — but a notification is an event. So a
///    notification fires when its name *enters* the plan and is retracted when
///    it *leaves*, which is what makes a held "needs you" clear the moment you
///    answer the prompt.
/// 3. **Failure is silent and temporary.** Pushed apps live in the device's RAM,
///    so a reboot wipes them; the heartbeat re-sends everything periodically and
///    an offline clock just backs off. None of this is allowed to matter to
///    agent detection.
actor AwtrixPublisher {
    /// Firmware pages AgentClock suppresses while it owns the rotation. Their
    /// names come from `/api/v1/apps` and are stable AWTRIX NG identifiers.
    static let nativeApps = ["Time", "Date", "Temperature", "Humidity", "Battery"]
    private let client: any AwtrixTransport

    /// Last bytes successfully written for each app name.
    private var sentApps: [String: Data] = [:]
    /// Notification names currently believed to be live on the device.
    private var liveNotifications: Set<String> = []
    /// App order last written, so we don't rewrite it every tick.
    private var sentOrder: [String] = []

    private var lastFullPush = Date.distantPast
    private var failureStreak = 0
    private var nextAttempt = Date.distantPast

    /// Backoff ceiling. Long enough not to hammer a clock that's simply off,
    /// short enough that plugging it back in feels immediate.
    private static let maximumBackoff: TimeInterval = 30

    init(client: any AwtrixTransport) {
        self.client = client
    }

    struct Outcome: Sendable {
        var reachable: Bool
        var error: String?
        var changed: Bool
    }

    /// Reconcile the device with `plan`. Safe to call every second.
    func apply(_ plan: ClockPlan, heartbeat: TimeInterval, now: Date = Date()) async -> Outcome {
        guard now >= nextAttempt else {
            return Outcome(reachable: failureStreak == 0, error: nil, changed: false)
        }

        // A heartbeat forgets what we think the device knows, so the next pass
        // rewrites everything — that is how a rebooted clock heals itself.
        let isHeartbeat = now.timeIntervalSince(lastFullPush) >= heartbeat
        if isHeartbeat {
            sentApps.removeAll()
            sentOrder.removeAll()
        }

        var changed = false
        do {
            changed = try await reconcileApps(plan, isHeartbeat: isHeartbeat)
            changed = try await reconcileNotifications(plan) || changed
            lastFullPush = isHeartbeat ? now : lastFullPush
            failureStreak = 0
            nextAttempt = .distantPast
            return Outcome(reachable: true, error: nil, changed: changed)
        } catch {
            // Roll back the optimistic bookkeeping: whatever failed must be
            // retried, not assumed delivered.
            sentApps.removeAll()
            sentOrder.removeAll()
            failureStreak += 1
            let delay = min(Self.maximumBackoff, pow(2, Double(min(failureStreak, 5))))
            nextAttempt = now.addingTimeInterval(delay)
            return Outcome(reachable: false, error: error.localizedDescription, changed: changed)
        }
    }

    private func reconcileApps(_ plan: ClockPlan, isHeartbeat: Bool) async throws -> Bool {
        var changed = false

        for app in plan.apps {
            let payload = try app.page.payload()
            guard sentApps[app.name] != payload else { continue }
            try await client.pushApp(name: app.name, payload: payload)
            sentApps[app.name] = payload
            changed = true
        }

        // Anything we put there that the plan no longer wants. Only AgentClock's
        // own prefixed names are ever deleted — someone's weather app is not
        // ours to remove.
        let wanted = plan.appNames
        for name in sentApps.keys where !wanted.contains(name) {
            try await client.deleteApp(name: name)
            sentApps.removeValue(forKey: name)
            changed = true
        }

        let order = plan.apps.map(\.name)
        if changed || isHeartbeat, order != sentOrder, !order.isEmpty {
            // Order is best-effort: a firmware build that rejects a name we
            // don't own shouldn't fail the whole reconcile.
            try? await client.setOrder(order, disabled: Self.nativeApps)
            sentOrder = order
        }
        return changed
    }

    private func reconcileNotifications(_ plan: ClockPlan) async throws -> Bool {
        var changed = false
        let wanted = plan.notificationNames

        // Retract first: clearing a stale "needs you" matters more than posting
        // the next one, and doing it first means an agent that unblocks and
        // immediately blocks again doesn't briefly show two.
        for name in liveNotifications where !wanted.contains(name) {
            try await client.dismissNotification(named: name)
            liveNotifications.remove(name)
            changed = true
        }

        for notification in plan.notifications where !liveNotifications.contains(notification.name) {
            try await client.notify(payload: try notification.page.payload())
            liveNotifications.insert(notification.name)
            changed = true
        }
        return changed
    }

    /// Remove every AgentClock page and interrupt. Called on quit so a closed
    /// app doesn't leave stale agent status glowing on a desk overnight.
    func clearAll() async {
        for name in sentApps.keys { try? await client.deleteApp(name: name) }
        for name in liveNotifications { try? await client.dismissNotification(named: name) }
        // Hand the display back exactly as a standalone clock. Pushed
        // AgentClock pages are gone and the firmware pages are re-enabled.
        try? await client.setOrder(Self.nativeApps, disabled: [])
        sentApps.removeAll()
        liveNotifications.removeAll()
        sentOrder.removeAll()
    }

    /// Forget all device state, e.g. after the user points at a different clock.
    func reset() {
        sentApps.removeAll()
        liveNotifications.removeAll()
        sentOrder.removeAll()
        lastFullPush = .distantPast
        failureStreak = 0
        nextAttempt = .distantPast
    }
}
