import Foundation

/// One page of the AWTRIX payload schema — the same 40-key shape serves both
/// pushed apps and notifications, so this type serves both too. Only the
/// handful of keys AgentClock actually uses are modelled; the schema rejects
/// unknown top-level keys with 422, so being conservative here is a feature.
struct ClockPage: Equatable, Sendable {
    var text: String
    var icon: String?
    var textColor: String
    /// 0 or nil means "use the device's global app duration".
    var durationMs: Int?
    var scroll: ScrollMode?
    /// Scroll rate as a percentage of the device's base 21 px/s. Lower is
    /// slower and more readable; the default is deliberately under 100 because
    /// 21 px/s pushes a label past a 24-pixel window in about a second.
    var scrollSpeed: Int?
    /// Extra pixels painted over the page — used for the fleet's state pips.
    var draw: [DrawCommand] = []

    // Notification-only keys. Setting any of these on a pushed app is a 422.
    var name: String?
    var hold: Bool?
    var stack: Bool?
    var wakeup: Bool?
    var soundRtttl: String?
    /// AgentClock-only entrance treatment. It is intentionally absent from
    /// `jsonObject`; animated hardware frames travel over Art-Net.
    var animation: MessageAnimation? = nil

    enum ScrollMode: String, Equatable, Sendable {
        case `static`, wrap, loop, bounce
    }

    /// A `draw` entry: operation name first, then coordinates, then an optional
    /// trailing colour.
    struct DrawCommand: Equatable, Sendable {
        let op: String
        let args: [Int]
        let color: String?

        static func pixel(x: Int, y: Int, color: String) -> DrawCommand {
            DrawCommand(op: "pixel", args: [x, y], color: color)
        }

        /// A horizontal run. One of these replaces up to 32 `pixel` commands,
        /// which matters when the whole page is drawn rather than typed: the
        /// body of the Claude mark is an 11-pixel run on two rows.
        static func line(x0: Int, y0: Int, x1: Int, y1: Int, color: String) -> DrawCommand {
            DrawCommand(op: "line", args: [x0, y0, x1, y1], color: color)
        }

        var jsonArray: [Any] {
            var array: [Any] = [op]
            array.append(contentsOf: args)
            if let color { array.append(color) }
            return array
        }
    }

    /// How long this page should hold, in seconds.
    ///
    /// `durationMs` is 0 — not nil — when the user asked for "the clock's own
    /// default", because that is what the wire format means by 0. Anything
    /// reading the field has to apply that rule too: `durationMs ?? fallback`
    /// silently returns 0, and a zero-length page advances every frame. That
    /// bug made the simulator flip pages thirty times a second.
    func holdSeconds(default fallback: Int) -> TimeInterval {
        let milliseconds = (durationMs ?? 0) > 0 ? durationMs! : fallback
        return TimeInterval(milliseconds) / 1000
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = ["text": text, "textColor": textColor]
        if let icon { object["icon"] = icon }
        if let durationMs, durationMs > 0 { object["durationMs"] = durationMs }
        if let scroll {
            var settings: [String: Any] = ["mode": scroll.rawValue]
            if let scrollSpeed { settings["speed"] = scrollSpeed }
            object["scroll"] = settings
        }
        if !draw.isEmpty { object["draw"] = draw.map(\.jsonArray) }
        if let name { object["name"] = name }
        if let hold { object["hold"] = hold }
        if let stack { object["stack"] = stack }
        if let wakeup { object["wakeup"] = wakeup }
        if let soundRtttl { object["soundRtttl"] = soundRtttl }
        return object
    }

    /// Serialized with sorted keys so byte equality is a valid "has this page
    /// changed?" test — that is what keeps the publisher from re-sending an
    /// identical page every tick.
    func payload() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
    }
}

/// AWTRIX app and notification names travel in a URL path and are matched
/// exactly on delete, so they have to be stable and boring.
enum ClockName {
    /// The device reserves this word for "whatever is on screen right now".
    static let reserved = "active"

    static func sanitize(_ raw: String, prefix: String) -> String {
        let allowed = raw.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        var slug = String(allowed)
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "x" }
        // Keep names short: they show up in the device's own app list.
        let name = prefix + String(slug.prefix(24))
        return name == Self.reserved ? name + "-1" : name
    }
}
