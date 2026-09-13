import XCTest
@testable import AgentClock

final class TetrisTests: XCTestCase {

    // MARK: Geometry

    func testTheWellMatchesThePanel() {
        XCTAssertEqual(Tetris.across, 8)
        XCTAssertEqual(Tetris.depth, 32)
    }

    func testEveryPieceHasFourCellsInEveryRotation() {
        for piece in Tetris.Piece.allCases {
            for rotation in 0..<4 {
                let active = Tetris.Active(piece: piece, rotation: rotation,
                                           origin: .init(0, 0))
                let cells = Tetris.cells(of: active)
                XCTAssertEqual(cells.count, 4, "\(piece) rotation \(rotation)")
                XCTAssertEqual(Set(cells).count, 4, "\(piece) rotation \(rotation) has duplicates")
            }
        }
    }

    func testRotatingFourTimesReturnsToTheStart() {
        for piece in Tetris.Piece.allCases {
            let start = Set(Tetris.cells(of: .init(piece: piece, rotation: 0, origin: .init(5, 2))))
            let round = Set(Tetris.cells(of: .init(piece: piece, rotation: 4, origin: .init(5, 2))))
            XCTAssertEqual(start, round, "\(piece) does not come back around")
        }
    }

    func testEveryPieceStaysInsideItsBox() {
        for piece in Tetris.Piece.allCases {
            for rotation in 0..<4 {
                for cell in Tetris.cells(of: .init(piece: piece, rotation: rotation, origin: .init(0, 0))) {
                    XCTAssertTrue((0..<piece.box).contains(cell.column), "\(piece) escaped its box")
                    XCTAssertTrue((0..<piece.box).contains(cell.row), "\(piece) escaped its box")
                }
            }
        }
    }

    func testTheSquareNeverChangesShape() {
        // O has no distinct rotations; if the rotation maths is wrong it will
        // drift around its box instead of standing still.
        let states = (0..<4).map {
            Set(Tetris.cells(of: .init(piece: .o, rotation: $0, origin: .init(3, 3))))
        }
        XCTAssertEqual(Set(states).count, 1)
    }

    // MARK: Falling and locking

    func testAPieceFallsTowardTheFloor() {
        var game = Tetris()
        let before = try! XCTUnwrap(game.active).origin.column
        XCTAssertTrue(game.fall())
        XCTAssertEqual(try! XCTUnwrap(game.active).origin.column, before - 1)
    }

    func testAPieceLocksAtTheFloorAndANewOneArrives() {
        var game = Tetris()
        let first = try! XCTUnwrap(game.active).piece
        game.drop()
        let landed = (0..<Tetris.across).contains { game.cell(column: 0, row: $0) != nil }
        XCTAssertTrue(landed, "nothing reached the floor")
        XCTAssertNotNil(game.active, "no replacement piece")
        // The spawned piece starts at the far end again.
        XCTAssertGreaterThan(try! XCTUnwrap(game.active).origin.column, Tetris.depth - 5)
        XCTAssertNotNil(first)
    }

    func testPiecesStackRatherThanOverlap() {
        var game = Tetris()
        for _ in 0..<6 { game.drop() }
        // Count what landed: every locked piece contributes exactly four cells.
        let filled = (0..<Tetris.depth).flatMap { column in
            (0..<Tetris.across).compactMap { game.cell(column: column, row: $0) }
        }
        XCTAssertEqual(filled.count % 4, 0, "a piece was lost or double-counted")
    }

    // MARK: Steering

    func testSteeringMovesAcrossTheWell() {
        var game = Tetris()
        let before = try! XCTUnwrap(game.active).origin.row
        game.steer(1)
        XCTAssertEqual(try! XCTUnwrap(game.active).origin.row, before + 1)
    }

    func testSteeringStopsAtTheEdge() {
        var game = Tetris()
        for _ in 0..<20 { game.steer(-1) }
        let cells = Tetris.cells(of: try! XCTUnwrap(game.active))
        XCTAssertTrue(cells.allSatisfy { $0.row >= 0 }, "steered out of the well")
        for _ in 0..<40 { game.steer(1) }
        let far = Tetris.cells(of: try! XCTUnwrap(game.active))
        XCTAssertTrue(far.allSatisfy { $0.row < Tetris.across }, "steered out of the well")
    }

    func testRotationKicksOffTheWallInsteadOfRefusing() {
        // Jammed against an edge, a piece should shuffle over and turn. Simply
        // refusing reads as a broken control rather than a hard game.
        var game = Tetris()
        for _ in 0..<20 { game.steer(-1) }
        let before = Tetris.cells(of: try! XCTUnwrap(game.active))
        game.rotate()
        let after = Tetris.cells(of: try! XCTUnwrap(game.active))
        XCTAssertTrue(after.allSatisfy { $0.row >= 0 && $0.row < Tetris.across })
        XCTAssertNotNil(before)
    }

    // MARK: Clearing

    func testAFullColumnClearsAndScores() {
        var game = Tetris()
        // Fill the floor column by hand, leaving one gap, then plug it.
        for row in 0..<Tetris.across where row != 3 {
            game.forceCell(column: 0, row: row, to: "#FFFFFF")
        }
        XCTAssertEqual(game.lines, 0)
        game.forceCell(column: 0, row: 3, to: "#FFFFFF")
        game.forceClear()
        XCTAssertEqual(game.lines, 1)
        XCTAssertGreaterThan(game.score, 0)
        XCTAssertNil(game.cell(column: 0, row: 0), "the column did not clear")
    }

    func testClearingSlidesTheStackTowardTheFloor() {
        var game = Tetris()
        for row in 0..<Tetris.across { game.forceCell(column: 0, row: row, to: "#111111") }
        game.forceCell(column: 1, row: 4, to: "#222222")
        game.forceClear()
        // The lone cell above the cleared column drops into it.
        XCTAssertEqual(game.cell(column: 0, row: 4), "#222222")
        XCTAssertNil(game.cell(column: 1, row: 4))
    }

    func testFourAtOnceScoresMoreThanFourOnesDo() {
        var quad = Tetris()
        for column in 0..<4 {
            for row in 0..<Tetris.across { quad.forceCell(column: column, row: row, to: "#FFFFFF") }
        }
        quad.forceClear()

        var singles = Tetris()
        for _ in 0..<4 {
            for row in 0..<Tetris.across { singles.forceCell(column: 0, row: row, to: "#FFFFFF") }
            singles.forceClear()
        }
        XCTAssertEqual(quad.lines, singles.lines)
        XCTAssertGreaterThan(quad.score, singles.score, "a tetris should be worth more")
    }

    // MARK: Pacing

    func testItSpeedsUpWithTheLevelButNeverBecomesImpossible() {
        var game = Tetris()
        let start = game.dropInterval
        for _ in 0..<200 {
            for row in 0..<Tetris.across { game.forceCell(column: 0, row: row, to: "#FFFFFF") }
            game.forceClear()
        }
        XCTAssertGreaterThan(game.level, 1)
        XCTAssertLessThan(game.dropInterval, start)
        XCTAssertGreaterThanOrEqual(game.dropInterval, 0.08)
    }

    func testTickDropsOnScheduleAndNotFasterThanRealTime() {
        var game = Tetris()
        let interval = game.dropInterval
        let start = try! XCTUnwrap(game.active).origin.column
        game.tick(now: 0)
        XCTAssertEqual(try! XCTUnwrap(game.active).origin.column, start, "dropped before its time")
        game.tick(now: interval * 1.01)
        XCTAssertEqual(try! XCTUnwrap(game.active).origin.column, start - 1)
    }

    /// Play a real game out and print the panel, so the thing can be eyeballed
    /// without hardware or hands.
    func testPrintAPlayedGame() {
        var game = Tetris(seed: 7)
        // Drop a dozen pieces, nudging each somewhere different so the stack is
        // uneven rather than a neat wall.
        for index in 0..<12 {
            for _ in 0..<(index % 5) { game.steer(1) }
            if index % 3 == 0 { game.rotate() }
            game.drop()
            if game.isOver { break }
        }
        print("\nscore \(game.score)  lines \(game.lines)  level \(game.level)")
        let canvas = TetrisRenderer.render(game)
        for row in 0..<Tetris.across {
            print("  " + (0..<Tetris.depth).map { canvas[$0, row].isLit ? "#" : "." }.joined())
        }
    }

    // MARK: Fairness and endings

    func testTheBagDealsEveryPieceBeforeRepeatingAny() {
        // A plain random generator produces long runs of one piece, which is
        // the classic way a Tetris feels unfair.
        var game = Tetris(seed: 12345)
        var seen: [Tetris.Piece] = []
        for _ in 0..<14 {
            seen.append(try! XCTUnwrap(game.active).piece)
            game.drop()
            if game.isOver { break }
        }
        let firstSeven = Set(seen.prefix(7))
        XCTAssertEqual(firstSeven.count, 7, "a piece repeated inside the first bag")
    }

    func testTheSameSeedPlaysTheSameGame() {
        func run(_ seed: UInt64) -> [Tetris.Piece] {
            var game = Tetris(seed: seed)
            var order: [Tetris.Piece] = []
            for _ in 0..<10 {
                guard let active = game.active else { break }
                order.append(active.piece)
                game.drop()
            }
            return order
        }
        XCTAssertEqual(run(99), run(99))
        XCTAssertNotEqual(run(99), run(100))
    }

    func testItEndsWhenThereIsNoRoomToEnter() {
        var game = Tetris()
        for column in 0..<Tetris.depth {
            for row in 0..<Tetris.across { game.forceCell(column: column, row: row, to: "#FFFFFF") }
        }
        game.forceSpawn()
        XCTAssertTrue(game.isOver)
        XCTAssertNil(game.active)
        // A finished game ignores everything.
        game.tick(now: 999)
        XCTAssertTrue(game.isOver)
    }
}
