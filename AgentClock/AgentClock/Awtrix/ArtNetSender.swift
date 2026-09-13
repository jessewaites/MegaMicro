import Foundation
import Network

/// Streams raw pixels to the panel over Art-Net.
///
/// The normal path — pushing an app and letting the firmware render it — is
/// fine at one frame a second but hopeless for a game. Art-Net skips all of
/// that: the panel becomes a plain 32×8 display and we ship it finished frames
/// over UDP at 30–50fps.
///
/// Two things about the protocol matter here. A universe carries 512 DMX
/// channels and a pixel takes three, so 170 pixels fit in one universe and a
/// 256-pixel panel needs two. And the firmware only holds the takeover **while
/// frames keep arriving** — five seconds of silence and it reverts to its own
/// app rotation. That timeout is doing useful work: if this app crashes
/// mid-game the panel goes back to being a clock on its own.
final class ArtNetSender {
    static let port: UInt16 = 6454
    /// 512 channels / 3 per pixel, rounded down.
    static let pixelsPerUniverse = 170
    /// How long the panel holds our pixels after the last frame.
    static let holdWindow: TimeInterval = 5

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "agentclock.artnet")
    private var sequence: UInt8 = 1

    private(set) var host: String?

    func connect(host: String) {
        disconnect()
        // Strip any scheme or port someone pasted into the host field — Art-Net
        // is its own port and does not care about the HTTP one.
        let bare = Self.bareHost(host)
        guard !bare.isEmpty else { return }
        self.host = bare
        let connection = NWConnection(
            host: NWEndpoint.Host(bare),
            port: NWEndpoint.Port(rawValue: Self.port)!,
            using: .udp)
        connection.start(queue: queue)
        self.connection = connection
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        host = nil
    }

    /// Send one frame. Fire-and-forget: UDP has no delivery guarantee and a
    /// dropped frame at 30fps is invisible, so nothing here waits or retries.
    func send(_ canvas: PixelCanvas) {
        guard let connection else { return }
        let pixels = Self.channelData(from: canvas)
        for universe in 0...(max(0, (pixels.count / 3 - 1) / Self.pixelsPerUniverse)) {
            let start = universe * Self.pixelsPerUniverse * 3
            let end = min(pixels.count, start + Self.pixelsPerUniverse * 3)
            guard start < end else { break }
            let packet = Self.packet(universe: UInt16(universe),
                                     channels: Array(pixels[start..<end]),
                                     sequence: sequence)
            connection.send(content: packet, completion: .idempotent)
        }
        sequence = sequence == 255 ? 1 : sequence + 1
    }

    // MARK: Encoding

    /// Flatten a canvas into DMX channels, three bytes per pixel.
    ///
    /// Row-major, left to right and top to bottom. Many LED panels are wired
    /// in a serpentine, where alternate rows run backwards — if the picture
    /// comes out mirrored on every other row, that is the thing to change.
    static func channelData(from canvas: PixelCanvas) -> [UInt8] {
        var channels: [UInt8] = []
        channels.reserveCapacity(canvas.width * canvas.height * 3)
        for y in 0..<canvas.height {
            for x in 0..<canvas.width {
                let pixel = canvas[x, y]
                channels.append(pixel.r)
                channels.append(pixel.g)
                channels.append(pixel.b)
            }
        }
        return channels
    }

    /// An ArtDMX packet: the header is fixed, and the only fiddly part is that
    /// the universe is little-endian while the data length is big-endian.
    static func packet(universe: UInt16, channels: [UInt8], sequence: UInt8) -> Data {
        var packet = Data("Art-Net".utf8)
        packet.append(0)                                  // null-terminated ID
        packet.append(contentsOf: [0x00, 0x50])           // OpDmx, little-endian
        packet.append(contentsOf: [0x00, 0x0E])           // protocol version 14
        packet.append(sequence)
        packet.append(0)                                  // physical port
        packet.append(UInt8(universe & 0xFF))             // universe, low byte
        packet.append(UInt8((universe >> 8) & 0xFF))      // universe, high byte
        // Length is big-endian, and must be even per the spec.
        let length = UInt16(channels.count + (channels.count % 2))
        packet.append(UInt8((length >> 8) & 0xFF))
        packet.append(UInt8(length & 0xFF))
        packet.append(contentsOf: channels)
        if channels.count % 2 == 1 { packet.append(0) }
        return packet
    }

    static func bareHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["http://", "https://"] where value.hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        if let colon = value.firstIndex(of: ":") { value = String(value[..<colon]) }
        return value
    }
}
