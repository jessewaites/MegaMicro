import Foundation

/// Turns the chirp symbols `ToneDetector` hears into the events the mic's
/// script encoded them as. See `FXMicScript` for the code table.
struct CueMessageDecoder {
    enum Message: Equatable {
        case fx3(down: Bool)
        case fx4(down: Bool)
        case handle(down: Bool)
        /// 0 = clean page … 4 = last page.
        case page(level: Int)
    }

    /// Symbols of one message arrive 240 ms apart; anything slower is a new
    /// message and the half-built one is dropped.
    static let gap: TimeInterval = 0.6
    static let prefix = 3

    private var pending: [Int] = []
    private var lastAt: TimeInterval = 0

    mutating func feed(symbol: Int, at time: TimeInterval) -> Message? {
        if !pending.isEmpty, time - lastAt > Self.gap { pending.removeAll() }
        lastAt = time

        if pending.isEmpty {
            switch symbol {
            case 0: return .fx3(down: true)
            case 1: return .fx4(down: true)
            case 2: return .handle(down: true)
            default:
                pending = [symbol]
                return nil
            }
        }

        pending.append(symbol)
        // [3, x]
        if pending.count == 2 {
            switch pending[1] {
            case 0: pending.removeAll(); return .fx3(down: false)
            case 1: pending.removeAll(); return .fx4(down: false)
            case 2: pending.removeAll(); return .handle(down: false)
            default: return nil          // [3, 3] — a page follows
            }
        }
        // [3, 3, x, y]
        if pending.count == 4 {
            defer { pending.removeAll() }
            let x = pending[2], y = pending[3]
            if x == 1 && y == 0 { return .page(level: 0) }
            if x == 0, (0...3).contains(y) { return .page(level: y + 1) }
            return nil
        }
        return nil
    }

    mutating func reset() { pending.removeAll() }
}
