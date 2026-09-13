import Foundation
import Observation
import AppKit

/// The secret game.
///
/// While it runs, the panel belongs to Tetris: Art-Net takes the display over
/// wholesale, so agent monitoring stops for the duration. That is a real
/// trade rather than an oversight — Art-Net *is* full takeover — and it is why
/// this is a mode you enter and leave rather than something ambient.
///
/// Detection keeps running underneath. Hooks still land, the session store
/// still updates; only the panel is borrowed. Quitting the game republishes
/// immediately, so you come back to a current display rather than a stale one.
@MainActor
@Observable
final class GameMode {
    private(set) var game = Tetris()
    private(set) var isPlaying = false
    /// The panel as the game sees it — also what the on-screen simulator shows,
    /// so the game is playable and developable with no hardware at all.
    private(set) var canvas = PixelCanvas(width: Tetris.depth, height: Tetris.across)

    private(set) var highScore = 0

    /// The landing shadow — the "ghost piece". Standard in guideline Tetris
    /// since 2001, and it earns its keep here more than usual: the well is
    /// thirty-two deep, so a piece spends most of its life a long way from the
    /// stack. Some people find it makes the game too easy, hence the switch.
    var showsGhost = true {
        didSet { render() }
    }

    /// Fades after columns clear, purely so a tetris registers as an event.
    private var flash: Double = 0
    private var elapsed: TimeInterval = 0
    private var lastLines = 0

    private let sender = ArtNetSender()
    private var loop: Timer?
    private var keyMonitor: Any?

    /// 30fps: the firmware's own recommendation is 30–50, and past that the
    /// panel is redrawing faster than it can usefully show.
    static let frameRate = 30.0

    // MARK: Lifecycle

    func start(host: String?) {
        game = Tetris(seed: UInt64.random(in: 1...UInt64.max))
        elapsed = 0
        flash = 0
        lastLines = 0
        isPlaying = true
        if let host, !host.isEmpty { sender.connect(host: host) }
        loop?.invalidate()
        loop = Timer.scheduledTimer(withTimeInterval: 1 / Self.frameRate, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.frame() }
        }
        startKeyMonitor()
        render()
    }

    func stop() {
        isPlaying = false
        loop?.invalidate()
        loop = nil
        stopKeyMonitor()
        // One black frame so the panel goes dark immediately rather than
        // holding the last position for the five-second Art-Net window.
        sender.send(PixelCanvas(width: Tetris.depth, height: Tetris.across))
        sender.disconnect()
    }

    func restart(host: String?) {
        highScore = max(highScore, game.score)
        start(host: host)
    }

    // MARK: Frame

    private func frame() {
        let step = 1 / Self.frameRate
        elapsed += step
        game.tick(now: elapsed)

        if game.lines > lastLines {
            lastLines = game.lines
            flash = 1
        }
        flash = max(0, flash - step * 4)

        if game.isOver { highScore = max(highScore, game.score) }
        render()
    }

    private func render() {
        canvas = TetrisRenderer.render(game, flash: flash, showsGhost: showsGhost)
        sender.send(canvas)
    }

    // MARK: Keys

    /// Grab the keys at the window level while a game is running.
    ///
    /// SwiftUI's `onKeyPress` needs the view to hold focus, and in a
    /// NavigationSplitView the sidebar list happily takes it — at which point
    /// the arrow keys change settings pane instead of steering, mid-game. A
    /// local monitor sidesteps focus entirely. It needs no permissions: only
    /// *global* monitors require Input Monitoring, and this one sees this app's
    /// events alone.
    private func startKeyMonitor() {
        stopKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPlaying else { return event }
            // Never swallow a shortcut — ⌘Q and friends must still work.
            guard !event.modifierFlags.contains(.command) else { return event }
            guard let move = Self.move(for: event) else { return event }
            MainActor.assumeIsolated {
                if move == .restart {
                    self.restartFromKey()
                } else if let play = move.play {
                    self.apply(play)
                }
            }
            return nil   // consumed, so the sidebar never sees it
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private enum KeyAction: Equatable {
        case move(Move)
        case restart
        var play: Move? { if case .move(let move) = self { return move }; return nil }
    }

    private static func move(for event: NSEvent) -> KeyAction? {
        // Arrow keys steer along the panel's short axis, so up and down move
        // the piece and left is the hurry-up.
        switch event.keyCode {
        case 126: return .move(.up)
        case 125: return .move(.down)
        case 123: return .move(.softDrop)
        case 124: return .move(.rotate)
        case 49:  return .move(.hardDrop)      // space
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z", "x": return .move(.rotate)
        case "r": return .restart
        default: return nil
        }
    }

    private func restartFromKey() {
        highScore = max(highScore, game.score)
        let host = sender.host
        stop()
        start(host: host)
    }

    // MARK: Input

    enum Move { case up, down, rotate, softDrop, hardDrop }

    /// Steering is along the panel's short axis, so "up" and "down" on the
    /// keyboard move the piece across the well, and "left" hurries it along.
    /// That mapping follows the panel's orientation rather than Tetris
    /// tradition, which assumes a tall well.
    func apply(_ move: Move) {
        guard isPlaying, !game.isOver else { return }
        switch move {
        case .up: game.steer(-1)
        case .down: game.steer(1)
        case .rotate: game.rotate()
        case .softDrop: game.softDrop(now: elapsed)
        case .hardDrop: game.drop()
        }
        render()
    }
}
