import Foundation

struct ExternalNotification {
    let notification: PlannedNotification
    let expiresAt: Date?
}

extension AppModel {
    func startMessagePlayback(text: String, animation: MessageAnimation) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isDemoRunning { stopDemo() }
        if game.isPlaying { stopGame() }
        messagePlayback.start(text: trimmed, animation: animation, color: "#FFFFFF",
                              width: panelWidth, host: config.clockHost)
        let stayingAwake = idleSleepPreventer.start()
        log("Text Lab play started: \(trimmed.count) chars, \(animation.rawValue), 30 fps"
            + (config.clockHost.isEmpty ? ", simulator only" : ", Art-Net → \(config.clockHost)"))
        log(stayingAwake
            ? "idle sleep prevented while Text Lab plays; display sleep remains allowed"
            : "warning: could not prevent idle sleep")
    }

    func stopMessagePlayback() {
        guard messagePlayback.isPlaying else { return }
        messagePlayback.stop()
        idleSleepPreventer.stop()
        log("Text Lab play stopped; restoring clock rotation")
        publishToClock()
    }

    /// Display an MCP/CLI message as an AWTRIX notification. AgentClock owns
    /// the operation, so the helper cannot race the fleet publisher or expose
    /// the user's clock credentials to every MCP client.
    func enqueueExternalMessage(_ command: ExternalMessageRequest) async -> String {
        let rawID = command.id ?? UUID().uuidString
        let name = ClockName.sanitize(rawID, prefix: "ac-mcp-")
        let text = command.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var page = ClockPage(
            text: text,
            icon: nil,
            textColor: normalizedHex(command.color ?? "#FFFFFF"),
            durationMs: command.hold == true ? nil : (command.durationMs ?? 10_000),
            scroll: .loop,
            scrollSpeed: config.display.scrollSpeed)
        page.name = name
        page.hold = command.hold ?? false
        page.stack = false
        page.wakeup = command.wakeup ?? true
        page.animation = command.animation

        // AWTRIX's tiny text font does not understand emoji. When a short
        // message containing one fits, bake the whole composition into draw
        // commands so hardware receives the same colour pixels as the preview.
        if text.contains(where: { EmojiGlyph.sprite(for: $0) != nil }),
           MatrixFont.width(of: text) <= panelWidth {
            let canvas = MatrixRenderer.render(page, width: panelWidth)
            page.text = ""
            page.scroll = nil
            page.draw = canvas.drawCommands()
        }

        let expiresAt = page.hold == true
            ? nil
            : Date().addingTimeInterval(page.holdSeconds(default: simulator.defaultDurationMs))
        externalNotifications.removeAll { $0.notification.name == name }
        externalNotifications.append(ExternalNotification(
            notification: PlannedNotification(name: name, page: page),
            expiresAt: expiresAt))
        log("message queued: \(name), \(text.count) chars, entrance \((page.animation ?? .none).rawValue)")

        // No hardware is a valid simulator-only setup. The simulator consumes
        // currentPlan on its display tick and will show this immediately.
        guard !config.clockHost.isEmpty else {
            log("message playing on simulator only: no clock configured (\(name))")
            return jsonResponse(ok: true, id: name, target: "simulator")
        }
        do {
            log("message HTTP send started → \(config.clockHost) (\(name))")
            try await awtrix.notify(payload: page.payload())
            log("message HTTP accepted by clock (\(name))")
            if let animation = page.animation, animation != .none {
                // AWTRIX NG 1.1.0 accepts the notification over HTTP, but raw
                // Art-Net takeover leaves the TC001 holding its initial black
                // frame. Keep the entrance in the pixel-exact simulator and
                // let the clock show the settled HTTP notification.
                log("entrance \(animation.rawValue) → simulator; clock uses settled frame (firmware 1.1.0 Art-Net disabled)")
            }
            clockIsReachable = true
            clockLastError = nil
            log("message playback complete (\(name))")
            return jsonResponse(ok: true, id: name)
        } catch {
            clockIsReachable = false
            clockLastError = error.localizedDescription
            log("message failed (\(name)): \(error.localizedDescription)")
            return jsonResponse(ok: false, id: name, error: error.localizedDescription)
        }
    }

    func clearExternalMessage(_ command: ExternalClearRequest) async -> String {
        let name = command.id.map { value in
            value.hasPrefix("ac-mcp-") ? value : ClockName.sanitize(value, prefix: "ac-mcp-")
        }

        if let name {
            externalNotifications.removeAll { $0.notification.name == name }
        } else if let activeName = simulator.isShowingNotification ? simulator.currentName : nil,
                  activeName.hasPrefix("ac-mcp-") {
            externalNotifications.removeAll { $0.notification.name == activeName }
        }

        guard !config.clockHost.isEmpty else {
            log("cleared simulator MCP message" + (name.map { " \($0)" } ?? ""))
            return jsonResponse(ok: true, id: name, target: "simulator")
        }
        do {
            if let name { try await awtrix.dismissNotification(named: name) }
            else { try await awtrix.dismissActiveNotification() }
            log("cleared MCP message" + (name.map { " \($0)" } ?? ""))
            return jsonResponse(ok: true, id: name)
        } catch {
            clockLastError = error.localizedDescription
            log("clear MCP message failed: \(error.localizedDescription)")
            return jsonResponse(ok: false, id: name, error: error.localizedDescription)
        }
    }

    func externalClockStatus() -> String {
        var object: [String: Any] = [
            "ok": true,
            "configured": !config.clockHost.isEmpty,
            "reachable": clockIsReachable,
            "host": config.clockHost,
            "width": panelWidth,
            "simulator": true,
        ]
        if let clockLastError { object["error"] = clockLastError }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func normalizedHex(_ value: String) -> String {
        let raw = value.hasPrefix("#") ? String(value.dropFirst()) : value
        return "#" + raw.uppercased()
    }

    private func jsonResponse(ok: Bool, id: String? = nil, error: String? = nil,
                              target: String? = nil) -> String {
        var object: [String: Any] = ["ok": ok]
        if let id { object["id"] = id }
        if let error { object["error"] = error }
        if let target { object["target"] = target }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Push the configured host/credentials into the client. Called whenever
    /// the user edits the Clock pane, and once at launch.
    func refreshClockEndpoint() {
        let endpoint = AwtrixClient.Endpoint(
            host: config.clockHost,
            username: config.clockUsername,
            password: config.clockPassword)
        Task { await awtrix.update(endpoint: endpoint) }
    }

    /// Explicit "does this address work?" for the Settings button. Reports the
    /// device's real matrix width, which the planner needs to decide whether
    /// text fits or has to scroll — a 32×8 TC001 and a 64×8 panel budget very
    /// differently.
    func testClockConnection() async {
        guard !config.clockHost.isEmpty else {
            clockIsReachable = false
            clockLastError = "No host set"
            return
        }
        refreshClockEndpoint()
        do {
            let info = try await awtrix.device()
            clockIsReachable = true
            clockLastError = nil
            panelWidth = info.pixelWidth
            log("clock reachable at \(config.clockHost) — \(info.pixelWidth)×\(info.pixelHeight)"
                + (info.version.map { ", firmware \($0)" } ?? ""))
            syncIcons()
        } catch {
            clockIsReachable = false
            clockLastError = error.localizedDescription
            log("clock unreachable: \(error.localizedDescription)")
        }
    }

    /// Adopt a discovered panel. Saves immediately — the user picked it, so
    /// losing it to a crash before the debounce fires would be rude.
    func adoptDiscovered(host: String) {
        config.clockHost = host
        config.lastDiscoveredHost = host
        saveConfigNow()
        Task {
            await publisher.reset()
            await testClockConnection()
        }
    }

    // MARK: Publishing

    /// The fleet as the planner wants it: labels resolved here, where Conductor
    /// workspaces and git branches live, so the planner itself stays pure.
    var agentSnapshots: [AgentSnapshot] {
        liveSessions.map { session in
            let project = projectName(for: session) ?? Self.readableSourceName(session.source)
            return AgentSnapshot(
                key: session.key,
                source: session.source,
                state: session.state,
                label: workContext(for: session) ?? project,
                project: project,
                startedAt: session.startedAt,
                // The bridge already derives this from SubagentStart/Stop, so
                // the crew on the panel is the real crew.
                parentKey: session.parentSession.map { "\(session.source)#\($0)" })
        }
    }

    /// The plan as it stands right now. Shared by the hardware publisher and
    /// the on-screen simulator so the two can never disagree about what the
    /// clock should be showing.
    func currentPlan() -> ClockPlan {
        var plan = PagePlanner.plan(agents: agentSnapshots,
                                    usage: demoUsage ?? usageByProvider,
                                    config: config.display,
                                    panelWidth: panelWidth)
        let now = Date()
        externalNotifications.removeAll { entry in
            entry.expiresAt.map { $0 <= now } ?? false
        }
        plan.notifications.append(contentsOf: externalNotifications.map(\.notification))
        return plan
    }

    /// Called from the 1 Hz tick. The publisher does its own change detection
    /// and backoff, so calling this every second when nothing has happened is
    /// close to free.
    func publishToClock() {
        guard !config.clockHost.isEmpty else { return }
        // The game owns the panel while it runs; publishing over it would
        // fight Art-Net for the display.
        guard !game.isPlaying, !pong.isPlaying, !messagePlayback.isPlaying else { return }
        guard !isPublishing else { return }
        isPublishing = true
        let plan = currentPlan()
        let heartbeat = config.display.heartbeatSeconds
        Task {
            let outcome = await publisher.apply(plan, heartbeat: heartbeat)
            isPublishing = false
            if outcome.reachable != clockIsReachable {
                clockIsReachable = outcome.reachable
                log(outcome.reachable ? "clock reconnected" : "clock unreachable")
                // A clock that just came back may have rebooted and lost both
                // its pushed apps and (after a reset) its icons.
                if outcome.reachable { syncIcons() }
            }
            clockLastError = outcome.error
        }
    }

    func syncIcons() {
        Task {
            let uploaded = await IconLibrary.syncMissing(using: awtrix)
            if !uploaded.isEmpty { log("uploaded \(uploaded.count) icon(s) to the clock") }
        }
    }

    /// Put a page on the panel right now, so the user can check colours,
    /// legibility and icon quality without waiting for an agent to do
    /// something. Sent as a notification rather than a pushed app: it shows
    /// immediately instead of waiting its turn in the rotation.
    func sendTestPage() async {
        // The test page is the real thing in miniature: the mark with green
        // eyes, a full crew and a half-filled bar. If this looks right on the
        // panel, everything else will.
        let model = ProviderPage.Model(source: "claude-code", state: .success,
                                       subagents: [.coding, .thinking, .waiting],
                                       quota: 0.5, context: 0.5)
        let canvas = ProviderPage.render(model, style: config.display.providerStyle,
                                         colors: config.display.stateColors, width: panelWidth)
        var page = ClockPage(text: "", icon: nil, textColor: "#000000",
                             durationMs: 6000, scroll: nil)
        page.draw = canvas.drawCommands()
        page.name = "ac-test"
        page.stack = false
        page.wakeup = true
        do {
            try await awtrix.notify(payload: page.payload())
            clockIsReachable = true
            clockLastError = nil
            log("sent test page")
        } catch {
            clockIsReachable = false
            clockLastError = error.localizedDescription
            log("test page failed: \(error.localizedDescription)")
        }
    }
}
