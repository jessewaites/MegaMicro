import Foundation

struct Pong: Equatable, Sendable {
    static let width = 32
    static let height = 8
    static let paddleHeight = 3

    var playerY = 2
    var computerY = 2
    var ballX = 15.5
    var ballY = 3.5
    var velocityX = -9.0
    var velocityY = 3.8
    var playerScore = 0
    var computerScore = 0
    /// Sub-pixel AI travel carried between frames. Without this accumulator a
    /// 0.1px step rounded to zero 30 times a second and the paddle never moved.
    var computerMoveRemainder = 0.0

    var level: Int { 1 + (playerScore + computerScore) / 3 }
    var computerSpeed: Double { min(9.5, 2.8 + Double(level) * 0.75) }

    mutating func movePlayer(_ amount: Int) {
        playerY = min(Self.height - Self.paddleHeight, max(0, playerY + amount))
    }

    mutating func tick(delta: TimeInterval) {
        // The computer follows imperfectly and at a finite speed, so it can be
        // beaten by changing the ball's angle near the edge of a paddle.
        let target = ballY - Double(Self.paddleHeight - 1) / 2
        let aiStep = computerSpeed * delta
        let difference = target - Double(computerY)
        if abs(difference) > 0.18 {
            computerMoveRemainder += min(aiStep, abs(difference))
                * (difference < 0 ? -1 : 1)
            if abs(computerMoveRemainder) >= 1 {
                let pixels = Int(computerMoveRemainder.rounded(.towardZero))
                computerY = min(Self.height - Self.paddleHeight,
                                max(0, computerY + pixels))
                computerMoveRemainder -= Double(pixels)
            }
        }

        ballX += velocityX * delta
        ballY += velocityY * delta

        if ballY < 0 {
            ballY = -ballY
            velocityY = abs(velocityY)
        } else if ballY > Double(Self.height - 1) {
            ballY = Double(Self.height - 1) * 2 - ballY
            velocityY = -abs(velocityY)
        }

        if velocityX < 0, ballX <= 1,
           ballY >= Double(playerY) - 0.45,
           ballY <= Double(playerY + Self.paddleHeight - 1) + 0.45 {
            ballX = 1
            velocityX = abs(velocityX) * 1.035
            velocityY += (ballY - Double(playerY + 1)) * 2.1
        } else if velocityX > 0, ballX >= Double(Self.width - 2),
                  ballY >= Double(computerY) - 0.45,
                  ballY <= Double(computerY + Self.paddleHeight - 1) + 0.45 {
            ballX = Double(Self.width - 2)
            velocityX = -abs(velocityX) * 1.035
            velocityY += (ballY - Double(computerY + 1)) * 2.1
        }

        velocityY = min(8, max(-8, velocityY))
        if ballX < -1 {
            computerScore += 1
            serve(towardPlayer: false)
        } else if ballX > Double(Self.width) {
            playerScore += 1
            serve(towardPlayer: true)
        }
    }

    mutating func serve(towardPlayer: Bool) {
        ballX = 15.5
        ballY = 3.5
        let speed = min(13, 8.5 + Double(level) * 0.65)
        velocityX = towardPlayer ? -speed : speed
        velocityY = Bool.random() ? speed * 0.4 : -speed * 0.4
        computerMoveRemainder = 0
    }
}

enum PongRenderer {
    static func render(_ game: Pong) -> PixelCanvas {
        var canvas = PixelCanvas(width: Pong.width, height: Pong.height)
        let player = PixelCanvas.RGB(hex: "#00E5FF")
        let computer = PixelCanvas.RGB(hex: "#FF5C8A")
        let ball = PixelCanvas.RGB(hex: "#FFFFFF")
        for y in game.playerY..<(game.playerY + Pong.paddleHeight) { canvas[0, y] = player }
        for y in game.computerY..<(game.computerY + Pong.paddleHeight) {
            canvas[Pong.width - 1, y] = computer
        }
        canvas[Int(game.ballX.rounded()), Int(game.ballY.rounded())] = ball
        return canvas
    }
}
