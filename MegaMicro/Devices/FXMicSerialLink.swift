import Foundation
import IOKit
import IOKit.serial

/// The EP-2350's USB-C side: a CDC serial port onto the mic's MicroPython
/// REPL. This finds the port, installs `FXMicProtocol.agentSource`, and turns
/// the lines it prints into `State` updates on the main queue.
///
/// Discovery is by USB vendor/product on the port's parent chain, so any
/// other `usbmodem` on the machine is left alone. Hot-plug is a 2 s poll
/// while disconnected — the cost is nil and it dodges IOKit notification
/// plumbing for a device that's plugged in once and left there.
final class FXMicSerialLink {
    static let vendorID = 9063      // TEENAGE ENGINEERING
    static let productID = 1568     // EP_2350

    var onState: ((FXMicProtocol.State) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var isConnected = false
    private(set) var firmware: String?
    private(set) var portPath: String?

    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var pollTimer: DispatchSourceTimer?
    private var buffer = Data()
    private var ready = false
    private let queue = DispatchQueue(label: "megamicro.fxmic.serial")
    /// Consecutive install failures; each one doubles the wait before the
    /// next try, capped at a minute, so a mic that won't talk USB doesn't
    /// fill the log four times a minute.
    private var failures = 0
    private var nextAttempt = Date.distantPast
    /// Set by the owner while another path (the audio script) is authoritative;
    /// no attempts are made until it clears.
    var suspended = false {
        didSet { if !suspended && oldValue { failures = 0; nextAttempt = .distantPast } }
    }

    // MARK: Lifecycle

    func start() {
        queue.async { self.attempt() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isConnected, !self.suspended, Date() >= self.nextAttempt else { return }
            self.attempt()
        }
        timer.resume()
        pollTimer = timer
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        queue.sync { self.closePort(reason: nil) }
    }

    // MARK: Discovery

    /// `/dev/cu.*` paths whose USB ancestry is the mic.
    static func candidatePorts() -> [String] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var paths: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(
                service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { continue }
            if isMicPort(service) { paths.append(path) }
        }
        return paths.sorted()
    }

    private static func isMicPort(_ service: io_object_t) -> Bool {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<12 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
            IOObjectRelease(current)
            current = parent
            let vendor = IORegistryEntryCreateCFProperty(current, "idVendor" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            let product = IORegistryEntryCreateCFProperty(current, "idProduct" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            if vendor == vendorID && product == productID { return true }
            if vendor != nil { return false }   // a different USB device
        }
        return false
    }

    // MARK: Connect

    private func attempt() {
        guard !isConnected, let path = Self.candidatePorts().first else { return }
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            onLog?("🔌 mic serial: could not open \(path) (\(String(cString: strerror(errno))))")
            return
        }
        var tio = termios()
        tcgetattr(fd, &tio)
        cfmakeraw(&tio)
        cfsetspeed(&tio, speed_t(B115200))
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &tio)
        // Exclusive: a second opener (a stray screen session) would steal lines.
        _ = ioctl(fd, TIOCEXCL)

        self.fd = fd
        portPath = path
        buffer.removeAll()
        ready = false

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { close(fd) }
        source.resume()
        reader = source

        isConnected = true
        installAgent()
    }

    /// Ctrl-C clears any half-typed line, Ctrl-A enters the raw REPL (no
    /// echo, no auto-indent), the code goes in, Ctrl-D runs it, Ctrl-B drops
    /// back to the friendly REPL so the hook's prints flow as plain lines.
    private func installAgent() {
        write("\u{03}")
        usleep(150_000)
        write("\u{01}")
        usleep(150_000)
        write(FXMicProtocol.agentSource + "\n")
        write("\u{04}")
        usleep(300_000)
        write("\u{02}\r\n")
        // The firmware answers MM-READY from inside the pasted code; the
        // first MM line follows on the next tick.
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.isConnected, !self.ready else { return }
            self.failures += 1
            let delay = min(60, 4 * pow(2, Double(self.failures - 1)))
            self.nextAttempt = Date().addingTimeInterval(delay)
            if self.failures <= 2 {
                self.onLog?("🔌 mic serial: no answer from the hook — retrying in \(Int(delay)) s")
            }
            self.closePort(reason: nil)
        }
    }

    private func write(_ text: String) {
        guard fd >= 0 else { return }
        var data = Array(text.utf8)
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeMutableBufferPointer { buf in
                Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
            }
            if n <= 0 { usleep(5_000); continue }
            offset += n
        }
    }

    // MARK: Read

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 {
            if n == 0 || (errno != EAGAIN && errno != EINTR) {
                closePort(reason: "port went away")
            }
            return
        }
        buffer.append(contentsOf: chunk[0..<n])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            handle(line: line)
        }
        if buffer.count > 65_536 { buffer.removeAll() }
    }

    private func handle(line: String) {
        if line.hasSuffix("MM-READY") {
            ready = true
            failures = 0
            firmware = nil
            DispatchQueue.main.async { self.onConnectionChange?(true, self.portPath) }
            return
        }
        if let range = line.range(of: FXMicProtocol.linePrefix),
           let state = FXMicProtocol.parse(String(line[range.lowerBound...])) {
            if !ready {
                ready = true
                DispatchQueue.main.async { self.onConnectionChange?(true, self.portPath) }
            }
            DispatchQueue.main.async { self.onState?(state) }
        }
    }

    private func closePort(reason: String?) {
        let wasConnected = isConnected
        reader?.cancel()      // closes fd in the cancel handler
        reader = nil
        fd = -1
        isConnected = false
        ready = false
        portPath = nil
        if wasConnected {
            if let reason { onLog?("🔌 mic serial: disconnected (\(reason))") }
            DispatchQueue.main.async { self.onConnectionChange?(false, nil) }
        }
    }

    deinit {
        pollTimer?.cancel()
        reader?.cancel()
    }
}
