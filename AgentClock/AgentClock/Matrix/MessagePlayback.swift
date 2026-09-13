import Foundation
import Observation

/// Owns the matrix while Text Lab is playing, just as `GameMode` does for
/// Tetris. Frames are rendered once and streamed continuously over Art-Net;
/// Stop releases the panel back to the normal agent rotation.
@MainActor
@Observable
final class MessagePlayback {
    private(set) var isPlaying = false
    private(set) var canvas = PixelCanvas()

    private let sender = ArtNetSender()
    private var loop: Timer?
    private var page: ClockPage?
    private var elapsed: TimeInterval = 0
    private var width = 32

    static let frameRate = 30.0
    static let entranceDuration = 1.35
    static let settledDuration = 1.65
    static var cycleDuration: TimeInterval { entranceDuration + settledDuration }
    static var showcaseDuration: TimeInterval { cycleDuration * 2 }

    func start(text: String, animation: MessageAnimation, color: String,
               width: Int, host: String?) {
        stop()
        self.width = width
        elapsed = 0
        page = ClockPage(text: text, icon: nil, textColor: color,
                         durationMs: nil, scroll: .static, scrollSpeed: nil,
                         animation: animation)
        isPlaying = true
        if let host, !host.isEmpty { sender.connect(host: host) }
        render()
        loop = Timer.scheduledTimer(withTimeInterval: 1 / Self.frameRate, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.frame() }
        }
    }

    func stop() {
        isPlaying = false
        loop?.invalidate()
        loop = nil
        page = nil
        sender.send(PixelCanvas(width: width, height: 8))
        sender.disconnect()
    }

    private func frame() {
        elapsed += 1 / Self.frameRate
        render()
    }

    private func render() {
        guard let page else { return }
        var renderedPage = page
        let cycleTime: TimeInterval
        if page.animation == .showcase {
            let showcaseTime = elapsed.truncatingRemainder(dividingBy: Self.showcaseDuration)
            let secondPhase = showcaseTime >= Self.cycleDuration
            cycleTime = showcaseTime.truncatingRemainder(dividingBy: Self.cycleDuration)
            renderedPage.animation = secondPhase ? .stream : .fall
        } else {
            cycleTime = elapsed.truncatingRemainder(dividingBy: Self.cycleDuration)
        }
        let renderTime = min(cycleTime, Self.entranceDuration)
        canvas = MatrixRenderer.render(renderedPage, width: width, height: 8, time: renderTime)
        sender.send(canvas)
    }
}
