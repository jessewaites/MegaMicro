import Foundation

extension PixelCanvas {
    /// Encode this canvas as AWTRIX `draw` commands.
    ///
    /// This is the bridge that lets AgentClock draw whatever it likes on the
    /// panel instead of being limited to the firmware's fonts and icons — and,
    /// more usefully, it means the simulator and the device render from the
    /// *same* canvas. They cannot drift, because there is only one picture.
    ///
    /// Runs of identical colour on a row collapse into a single `line`, which
    /// takes a page from ~120 commands to ~30 and keeps the payload well inside
    /// the device's 8192-byte limit.
    func drawCommands() -> [ClockPage.DrawCommand] {
        var commands: [ClockPage.DrawCommand] = []
        for y in 0..<height {
            var runStart = 0
            var runColor = self[0, y]
            func flush(end: Int) {
                guard runColor.isLit else { return }
                let hex = runColor.hexString
                commands.append(end == runStart
                    ? .pixel(x: runStart, y: y, color: hex)
                    : .line(x0: runStart, y0: y, x1: end, y1: y, color: hex))
            }
            for x in 1..<width {
                let pixel = self[x, y]
                if pixel != runColor {
                    flush(end: x - 1)
                    runStart = x
                    runColor = pixel
                }
            }
            flush(end: width - 1)
        }
        return commands
    }
}

extension PixelCanvas.RGB {
    var hexString: String { String(format: "#%02X%02X%02X", r, g, b) }
}
