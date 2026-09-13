import XCTest
@testable import AgentClock

final class ArtNetTests: XCTestCase {

    // MARK: Packet format
    //
    // Nothing here can be checked against real hardware yet, so these pin the
    // packet to the Art-Net spec instead. If the panel shows garbage, this is
    // the first place to look.

    func testThePacketHeaderMatchesTheSpec() {
        let packet = ArtNetSender.packet(universe: 0, channels: [1, 2, 3], sequence: 7)
        XCTAssertEqual(Array(packet.prefix(8)), Array("Art-Net\0".utf8))
        // OpDmx, little-endian.
        XCTAssertEqual(Array(packet[8..<10]), [0x00, 0x50])
        // Protocol version 14, big-endian.
        XCTAssertEqual(Array(packet[10..<12]), [0x00, 0x0E])
        XCTAssertEqual(packet[12], 7, "sequence")
        XCTAssertEqual(packet[13], 0, "physical port")
    }

    func testTheUniverseIsLittleEndianButTheLengthIsBig() {
        // The one genuinely error-prone part of the format: these two adjacent
        // fields use opposite byte orders.
        let packet = ArtNetSender.packet(universe: 0x0102, channels: [UInt8](repeating: 9, count: 6),
                                         sequence: 1)
        XCTAssertEqual(packet[14], 0x02, "universe low byte first")
        XCTAssertEqual(packet[15], 0x01)
        XCTAssertEqual(packet[16], 0x00, "length high byte first")
        XCTAssertEqual(packet[17], 6)
    }

    func testAnOddChannelCountIsPaddedEven() {
        // The spec requires an even length.
        let packet = ArtNetSender.packet(universe: 0, channels: [1, 2, 3], sequence: 1)
        XCTAssertEqual(packet[17], 4, "length rounded up")
        XCTAssertEqual(packet.count, 18 + 4)
        XCTAssertEqual(packet.last, 0, "padded with a zero")
    }

    // MARK: Pixel packing

    func testACanvasBecomesThreeChannelsPerPixel() {
        var canvas = PixelCanvas(width: 32, height: 8)
        canvas[0, 0] = .init(r: 10, g: 20, b: 30)
        canvas[1, 0] = .init(r: 40, g: 50, b: 60)
        let channels = ArtNetSender.channelData(from: canvas)
        XCTAssertEqual(channels.count, 32 * 8 * 3)
        XCTAssertEqual(Array(channels.prefix(6)), [10, 20, 30, 40, 50, 60])
    }

    func testPixelsAreRowMajor() {
        // Row-major, left to right and top to bottom. If the panel comes out
        // with alternate rows mirrored, it is wired serpentine and this is the
        // thing to change.
        var canvas = PixelCanvas(width: 32, height: 8)
        canvas[0, 1] = .init(r: 99, g: 0, b: 0)
        let channels = ArtNetSender.channelData(from: canvas)
        XCTAssertEqual(channels[32 * 3], 99, "second row should start after 32 pixels")
    }

    func testAPanelNeedsExactlyTwoUniverses() {
        // 512 channels / 3 = 170 pixels per universe; 256 pixels does not fit
        // in one. Getting this wrong silently drops the right-hand third of
        // the display.
        let pixels = 32 * 8
        XCTAssertGreaterThan(pixels, ArtNetSender.pixelsPerUniverse)
        XCTAssertLessThanOrEqual(pixels, ArtNetSender.pixelsPerUniverse * 2)
    }

    // MARK: Host parsing

    func testTheHostFieldIsSharedWithHTTPSoItMustBeStripped() {
        // Someone may well have typed a full URL into the Clock pane; Art-Net
        // wants a bare host and its own port.
        XCTAssertEqual(ArtNetSender.bareHost("http://clock.local:80/"), "clock.local")
        XCTAssertEqual(ArtNetSender.bareHost("clock.local:8080"), "clock.local")
        XCTAssertEqual(ArtNetSender.bareHost(" 10.0.0.5 "), "10.0.0.5")
        XCTAssertEqual(ArtNetSender.bareHost(""), "")
    }
}

@MainActor
final class GameModeTests: XCTestCase {

    func testStartingAGameProducesAPanelSizedFrame() {
        let mode = GameMode()
        mode.start(host: nil)
        XCTAssertTrue(mode.isPlaying)
        XCTAssertEqual(mode.canvas.width, Tetris.depth)
        XCTAssertEqual(mode.canvas.height, Tetris.across)
        XCTAssertTrue(mode.canvas.pixels.contains { $0.isLit }, "nothing was drawn")
        mode.stop()
        XCTAssertFalse(mode.isPlaying)
    }

    func testTheLandingShadowSitsUnderThePiece() {
        // Thirty-two deep means the piece is usually a long way from the stack;
        // without a shadow you are guessing where it will end up.
        var game = Tetris()
        let shadow = TetrisRenderer.landingCells(of: game)
        XCTAssertEqual(shadow.count, 4)
        let piece = Tetris.cells(of: game.active!)
        XCTAssertLessThan(shadow.map(\.column).min()!, piece.map(\.column).min()!,
                          "the shadow should be nearer the floor than the piece")
        // And it lands where a hard drop lands.
        game.drop()
        let landed = (0..<Tetris.depth).flatMap { column in
            (0..<Tetris.across).compactMap { game.cell(column: column, row: $0) != nil ? Tetris.Cell(column, $0) : nil }
        }
        XCTAssertEqual(Set(landed), Set(shadow))
    }

    func testInputIsIgnoredOnceTheGameIsOver() {
        let mode = GameMode()
        mode.start(host: nil)
        let before = mode.canvas
        mode.stop()
        mode.apply(.rotate)
        XCTAssertEqual(mode.canvas.width, before.width)
    }
}
