import Foundation

/// Tetris, turned on its side to fit a 32×8 panel.
///
/// A normal well is 10 wide and 20 deep. This panel is 32×8 and cannot be
/// rotated, so the game is: the well is **8 cells across** — the panel's eight
/// rows — and **32 deep**. Pieces enter at the right and fall leftward, and a
/// "line" is a full column of eight. That gives a slightly narrower well than
/// standard (harder) and a much deeper one (more room to recover). Tetrominoes
/// are at most four across, so they still rotate freely in eight.
///
/// Pure logic: no drawing, no timers, no input handling. `tick` is driven with
/// an explicit time so the whole game can be played out in a test.
struct Tetris {
    /// The panel's eight rows — the axis you steer along.
    static let across = 8
    /// The panel's thirty-two columns — the axis gravity pulls along, toward 0.
    static let depth = 32

    enum Piece: CaseIterable {
        case i, o, t, s, z, j, l

        /// Side of the box the piece rotates inside. Keeping each piece in its
        /// natural box is what makes rotation a single formula instead of a
        /// hand-written table per state.
        var box: Int {
            switch self {
            case .i: 4
            case .o: 2
            default: 3
            }
        }

        /// Cells at rotation 0, as (column, row) inside the box.
        var cells: [Cell] {
            switch self {
            case .i: [Cell(0, 1), Cell(1, 1), Cell(2, 1), Cell(3, 1)]
            case .o: [Cell(0, 0), Cell(1, 0), Cell(0, 1), Cell(1, 1)]
            case .t: [Cell(0, 1), Cell(1, 0), Cell(1, 1), Cell(2, 1)]
            case .s: [Cell(1, 0), Cell(2, 0), Cell(0, 1), Cell(1, 1)]
            case .z: [Cell(0, 0), Cell(1, 0), Cell(1, 1), Cell(2, 1)]
            case .j: [Cell(0, 0), Cell(0, 1), Cell(1, 1), Cell(2, 1)]
            case .l: [Cell(2, 0), Cell(0, 1), Cell(1, 1), Cell(2, 1)]
            }
        }

        /// The classic colours, which double as the only way to tell pieces
        /// apart once they have landed.
        var color: String {
            switch self {
            case .i: "#00F0F0"
            case .o: "#F0F000"
            case .t: "#A000F0"
            case .s: "#00F000"
            case .z: "#F00000"
            case .j: "#0000F0"
            case .l: "#F0A000"
            }
        }
    }

    struct Cell: Equatable, Hashable {
        var column: Int
        var row: Int
        init(_ column: Int, _ row: Int) {
            self.column = column
            self.row = row
        }
    }

    struct Active: Equatable {
        var piece: Piece
        var rotation: Int
        /// Where the piece's box sits in the well.
        var origin: Cell
    }

    // MARK: State

    /// Landed cells, by colour. nil is empty.
    private(set) var board: [String?]
    private(set) var active: Active?
    private(set) var next: Piece
    private(set) var score = 0
    private(set) var lines = 0
    private(set) var isOver = false

    /// Rows survive; the level rises every ten.
    var level: Int { 1 + lines / 10 }

    /// How long a piece takes to fall one column. Speeds up with the level and
    /// floors out so it stays possible to play.
    var dropInterval: TimeInterval {
        max(0.08, 0.55 - Double(level - 1) * 0.045)
    }

    /// Optional rather than a zero sentinel: a game whose first tick arrives
    /// at time zero would otherwise re-arm its clock on every call and never
    /// drop a piece at all.
    private var lastDrop: TimeInterval?
    private var bag: [Piece] = []
    private var random: SeededGenerator

    // MARK: Setup

    /// Seedable so a test can play a deterministic game.
    init(seed: UInt64 = 0x5EED) {
        var generator = SeededGenerator(seed: seed)
        board = Array(repeating: nil, count: Tetris.depth * Tetris.across)
        bag = []
        // Prime the bag before drawing the first two pieces.
        var starter = Tetris.refill(&generator, into: [])
        next = starter.removeFirst()
        bag = starter
        random = generator
        spawn()
    }

    /// A seven-bag: every piece appears once before any repeats. Long runs of
    /// the same piece are the classic way a random Tetris feels unfair.
    private static func refill(_ generator: inout SeededGenerator,
                               into bag: [Piece]) -> [Piece] {
        bag + Piece.allCases.shuffled(using: &generator)
    }

    private mutating func draw() -> Piece {
        if bag.isEmpty { bag = Tetris.refill(&random, into: []) }
        return bag.removeFirst()
    }

    // MARK: Board access

    func cell(column: Int, row: Int) -> String? {
        guard column >= 0, column < Tetris.depth, row >= 0, row < Tetris.across else { return nil }
        return board[column * Tetris.across + row]
    }

    private mutating func set(column: Int, row: Int, to color: String?) {
        guard column >= 0, column < Tetris.depth, row >= 0, row < Tetris.across else { return }
        board[column * Tetris.across + row] = color
    }

    /// Where a piece's cells actually sit in the well.
    static func cells(of active: Active) -> [Cell] {
        let box = active.piece.box
        return active.piece.cells.map { cell in
            var column = cell.column
            var row = cell.row
            // Rotate inside the box: (c, r) → (box-1-r, c), applied n times.
            for _ in 0..<(((active.rotation % 4) + 4) % 4) {
                let rotatedColumn = box - 1 - row
                let rotatedRow = column
                column = rotatedColumn
                row = rotatedRow
            }
            return Cell(active.origin.column + column, active.origin.row + row)
        }
    }

    func fits(_ active: Active) -> Bool {
        Tetris.cells(of: active).allSatisfy { cell in
            cell.column >= 0 && cell.column < Tetris.depth
                && cell.row >= 0 && cell.row < Tetris.across
                && board[cell.column * Tetris.across + cell.row] == nil
        }
    }

    // MARK: Play

    private mutating func spawn() {
        let piece = next
        next = draw()
        // Enter at the far end, centred across the well.
        let candidate = Active(piece: piece, rotation: 0,
                               origin: Cell(Tetris.depth - piece.box,
                                            (Tetris.across - piece.box) / 2))
        guard fits(candidate) else {
            isOver = true
            active = nil
            return
        }
        active = candidate
    }

    /// Steer across the well — the panel's vertical axis.
    mutating func steer(_ delta: Int) {
        guard var moved = active else { return }
        moved.origin.row += delta
        if fits(moved) { active = moved }
    }

    mutating func rotate() {
        guard var turned = active else { return }
        turned.rotation = (turned.rotation + 1) % 4
        if fits(turned) { active = turned; return }
        // Wall kick: nudge across by one, then two, before giving up. Without
        // this a piece against the edge simply refuses to turn, which feels
        // broken rather than difficult.
        for offset in [1, -1, 2, -2] {
            var kicked = turned
            kicked.origin.row += offset
            if fits(kicked) { active = kicked; return }
        }
    }

    /// One column closer to the floor. Returns false if it could not move,
    /// which is what locks the piece.
    @discardableResult
    mutating func fall() -> Bool {
        guard var dropped = active else { return false }
        dropped.origin.column -= 1
        if fits(dropped) {
            active = dropped
            return true
        }
        lock()
        return false
    }

    mutating func drop() {
        while fall() {}
    }

    private mutating func lock() {
        guard let active else { return }
        for cell in Tetris.cells(of: active) {
            set(column: cell.column, row: cell.row, to: active.piece.color)
        }
        self.active = nil
        clearFullColumns()
        spawn()
    }

    /// A full column of eight is this game's "line".
    private mutating func clearFullColumns() {
        var kept: [[String?]] = []
        var cleared = 0
        for column in 0..<Tetris.depth {
            let contents = (0..<Tetris.across).map { cell(column: column, row: $0) }
            if contents.allSatisfy({ $0 != nil }) {
                cleared += 1
            } else {
                kept.append(contents)
            }
        }
        guard cleared > 0 else { return }

        // Everything above the cleared column slides toward the floor.
        while kept.count < Tetris.depth {
            kept.append(Array(repeating: nil, count: Tetris.across))
        }
        for column in 0..<Tetris.depth {
            for row in 0..<Tetris.across {
                set(column: column, row: row, to: kept[column][row])
            }
        }
        lines += cleared
        score += [0, 100, 300, 500, 800][min(cleared, 4)] * level
    }

    // MARK: Time

    /// Advance the game. `now` is passed in rather than read so a test can play
    /// a whole game in an instant.
    mutating func tick(now: TimeInterval) {
        guard !isOver else { return }
        guard let started = lastDrop else { lastDrop = now; return }
        var elapsedFrom = started
        while now - elapsedFrom >= dropInterval {
            elapsedFrom += dropInterval
            fall()
            if isOver { break }
        }
        lastDrop = elapsedFrom
    }

    /// Nudge the piece along now and reset the fall clock, so a soft drop feels
    /// immediate instead of fighting the timer.
    mutating func softDrop(now: TimeInterval) {
        fall()
        lastDrop = now
    }

    // MARK: Test support

    /// Place a cell directly, to build a board state a test needs without
    /// playing thirty pieces to get there.
    mutating func forceCell(column: Int, row: Int, to color: String?) {
        set(column: column, row: row, to: color)
    }

    mutating func forceClear() {
        clearFullColumns()
    }

    mutating func forceSpawn() {
        spawn()
    }
}

/// Deterministic randomness, so a seeded game replays identically.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> UInt64 {
        // xorshift64*, plenty for shuffling seven pieces.
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2685821657736338717
    }
}
