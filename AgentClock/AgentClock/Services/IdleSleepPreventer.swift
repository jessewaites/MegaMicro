import Foundation

/// Prevents idle system sleep while allowing the display to dim and turn off.
/// `caffeinate -i` is Apple's built-in equivalent of the old Caffeine app.
final class IdleSleepPreventer {
    private var process: Process?

    var isActive: Bool { process?.isRunning == true }

    @discardableResult
    func start() -> Bool {
        if isActive { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-i"]
        do {
            try process.run()
            self.process = process
            return true
        } catch {
            self.process = nil
            return false
        }
    }

    func stop() {
        guard let process else { return }
        if process.isRunning { process.terminate() }
        self.process = nil
    }

    deinit { stop() }
}
