import AppKit
import GameController
import Observation

@MainActor
@Observable
final class PongMode {
    private(set) var game = Pong()
    private(set) var isPlaying = false
    private(set) var canvas = PongRenderer.render(Pong())
    private(set) var controllerStatus = "No game controller detected"

    private let sender = ArtNetSender()
    private var loop: Timer?
    private var keyMonitor: Any?
    private var joystickObserver: NSObjectProtocol?
    private var controllerObservers: [NSObjectProtocol] = []
    private var controlDirection = 0
    private var controlFramesRemaining = 0
    private var controlFrame = 0
    private var hardwareDirection = 0
    private static let frameRate = 30.0

    func start(host: String?) {
        game = Pong()
        isPlaying = true
        if let host, !host.isEmpty { sender.connect(host: host) }
        loop?.invalidate()
        loop = Timer.scheduledTimer(withTimeInterval: 1 / Self.frameRate, repeats: true) {
            [weak self] _ in Task { @MainActor in self?.frame() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPlaying, !event.modifierFlags.contains(.command) else { return event }
            let character = event.charactersIgnoringModifiers
            let movement: Int? = switch (event.keyCode, character) {
            case (126, _), (_, "4"), (_, "8"): -1
            case (125, _), (_, "6"), (_, "2"): 1
            default: nil
            }
            guard let movement else { return event }
            MainActor.assumeIsolated { self.pulsePlayer(movement) }
            return nil
        }
        joystickObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.jessewaites.megamicro.pongJoystick"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let direction = notification.userInfo?["direction"] as? String else { return }
            Task { @MainActor [weak self] in
                self?.receiveJoystick(direction)
            }
        }
        observeGameControllers()
        render()
    }

    func stop() {
        isPlaying = false
        loop?.invalidate(); loop = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let joystickObserver {
            DistributedNotificationCenter.default().removeObserver(joystickObserver)
        }
        joystickObserver = nil
        for observer in controllerObservers { NotificationCenter.default.removeObserver(observer) }
        controllerObservers.removeAll()
        for controller in GCController.controllers() {
            controller.extendedGamepad?.leftThumbstick.yAxis.valueChangedHandler = nil
            controller.microGamepad?.dpad.yAxis.valueChangedHandler = nil
        }
        hardwareDirection = 0
        sender.send(PixelCanvas(width: Pong.width, height: Pong.height))
        sender.disconnect()
    }

    private func frame() {
        if hardwareDirection != 0 {
            controlFrame += 1
            if controlFrame % 3 == 0 { game.movePlayer(hardwareDirection) }
        }
        game.tick(delta: 1 / Self.frameRate)
        render()
    }

    private func receiveJoystick(_ direction: String) {
        switch direction {
        case "up": hardwareDirection = -1
        case "down": hardwareDirection = 1
        default: hardwareDirection = 0
        }
        controlFrame = 0
        if hardwareDirection != 0 {
            game.movePlayer(hardwareDirection)
            render()
        }
    }

    private func pulsePlayer(_ direction: Int) {
        controlDirection = direction
        controlFramesRemaining = 0
        game.movePlayer(direction)
        render()
    }

    private func observeGameControllers() {
        let center = NotificationCenter.default
        controllerObservers.append(center.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor [weak self] in self?.attach(controller) }
        })
        controllerObservers.append(center.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hardwareDirection = 0 }
        })
        let controllers = GCController.controllers()
        controllerStatus = controllers.isEmpty
            ? "No game controller detected"
            : "Controller detected: \(controllers.first?.vendorName ?? "unknown")"
        for controller in controllers { attach(controller) }
    }

    private func attach(_ controller: GCController) {
        controllerStatus = "Controller detected: \(controller.vendorName ?? "unknown")"
        let handler: GCControllerAxisValueChangedHandler = { [weak self] _, value in
            Task { @MainActor [weak self] in self?.receiveAxis(value) }
        }
        if let gamepad = controller.extendedGamepad {
            gamepad.leftThumbstick.yAxis.valueChangedHandler = handler
            gamepad.rightThumbstick.yAxis.valueChangedHandler = handler
            gamepad.dpad.yAxis.valueChangedHandler = handler
        }
        controller.microGamepad?.dpad.yAxis.valueChangedHandler = handler
    }

    private func receiveAxis(_ value: Float) {
        if value > 0.35 {
            hardwareDirection = -1
            controllerStatus = "Joystick: up (\(String(format: "%.2f", value)))"
        } else if value < -0.35 {
            hardwareDirection = 1
            controllerStatus = "Joystick: down (\(String(format: "%.2f", value)))"
        } else {
            hardwareDirection = 0
            controllerStatus = "Joystick: centered"
        }
        controlFrame = 0
    }

    private func render() {
        canvas = PongRenderer.render(game)
        sender.send(canvas)
    }
}
