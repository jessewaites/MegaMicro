import XCTest
@testable import AgentClock

final class PongTests: XCTestCase {
    func testPaddleStaysOnPanel() {
        var game = Pong()
        for _ in 0..<20 { game.movePlayer(-1) }
        XCTAssertEqual(game.playerY, 0)
        for _ in 0..<20 { game.movePlayer(1) }
        XCTAssertEqual(game.playerY, Pong.height - Pong.paddleHeight)
    }

    func testBallBouncesOffTopAndBottom() {
        var top = Pong(ballY: 0.05, velocityY: -4)
        top.tick(delta: 0.1)
        XCTAssertGreaterThan(top.velocityY, 0)
        var bottom = Pong(ballY: 6.95, velocityY: 4)
        bottom.tick(delta: 0.1)
        XCTAssertLessThan(bottom.velocityY, 0)
    }

    func testPlayerPaddleReturnsBall() {
        var game = Pong(playerY: 2, ballX: 1.1, ballY: 3, velocityX: -9, velocityY: 0)
        game.tick(delta: 0.02)
        XCTAssertGreaterThan(game.velocityX, 0)
    }

    func testMissingPaddleScoresForComputer() {
        var game = Pong(playerY: 0, ballX: -0.9, ballY: 7, velocityX: -9)
        game.tick(delta: 0.02)
        XCTAssertEqual(game.computerScore, 1)
    }

    func testComputerPaddleTracksBallAcrossFractionalFrames() {
        var game = Pong(computerY: 0, ballY: 7)
        for _ in 0..<30 { game.tick(delta: 1.0 / 30) }
        XCTAssertGreaterThan(game.computerY, 0)
    }

    func testDifficultyIncreasesEveryThreePoints() {
        var game = Pong()
        let initialSpeed = game.computerSpeed
        game.playerScore = 2
        game.computerScore = 1
        XCTAssertEqual(game.level, 2)
        XCTAssertGreaterThan(game.computerSpeed, initialSpeed)
    }

    func testRendererUsesWholePanelAndThreePixelPaddles() {
        let canvas = PongRenderer.render(Pong())
        XCTAssertEqual(canvas.width, 32)
        XCTAssertEqual(canvas.height, 8)
        XCTAssertEqual((0..<8).filter { canvas[0, $0].isLit }.count, 3)
        XCTAssertEqual((0..<8).filter { canvas[31, $0].isLit }.count, 3)
    }
}
