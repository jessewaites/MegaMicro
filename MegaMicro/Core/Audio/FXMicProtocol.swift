import Foundation

/// The wire format between MegaMicro and the agent it installs on the
/// EP-2350's MicroPython REPL, plus the control ids that hang off it.
///
/// The mic's firmware exposes a Python REPL over its USB-C port (it's a
/// Raspberry Pi RP2 running MicroPython, with a `ui` module for the switches,
/// handle and LEDs, and a `teenage` module holding the current effect and
/// sample positions). MegaMicro pastes a small hook into that REPL which
/// wraps the firmware's own 60 Hz callback and prints one line whenever an
/// input changes. Nothing is stored on the mic; power-cycling it forgets the
/// hook, and reconnecting installs it again.
/// The names MegaMicro uses for the mic's four physical controls, everywhere
/// they're mentioned — the callouts beside the drawing, the grid, the log.
/// Short and numbered because "the small round orange one" is how confusion
/// starts.
enum FXMicControlName {
    static let handle = "FX1"
    static let fxButton = "FX2"
    static let middleButton = "FX3"
    static let bottomButton = "FX4"
}

enum FXMicProtocol {
    /// Serial line: `MM <play> <select> <fx> <handle0-20> <fxPos> <samPos>`.
    /// Switches are 1 when pressed (the hook inverts the active-low pins).
    static let linePrefix = "MM "

    struct State: Equatable, Sendable {
        var play = false        // bottom button (plays the selected sample)
        var select = false      // middle button (steps the sample slot)
        var fx = false          // small orange button (steps the effect page)
        /// Handle squeeze, 0…1 in twentieths.
        var handle: Double = 0
        /// Firmware effect position: -1 clean, 0…3 the four presets. This is
        /// the "page" the orange button steps through.
        var fxPos = -1
        var samPos = 0

        var handleDown: Bool { handle > 0 }
        var page: Int { fxPos + 1 }   // 0…4, for control ids and the grid
    }

    static func parse(_ line: String) -> State? {
        guard line.hasPrefix(linePrefix) else { return nil }
        let fields = line.dropFirst(linePrefix.count).split(separator: " ")
        guard fields.count == 6,
              let play = Int(fields[0]), let select = Int(fields[1]), let fx = Int(fields[2]),
              let handle = Int(fields[3]), let fxPos = Int(fields[4]), let samPos = Int(fields[5])
        else { return nil }
        return State(play: play != 0, select: select != 0, fx: fx != 0,
                     handle: Double(max(0, min(20, handle))) / 20,
                     fxPos: fxPos, samPos: samPos)
    }

    // MARK: Pages and controls

    /// Clean plus the four effect presets — what the orange button cycles.
    static let pageCount = 5

    /// The mic's own effect at each page position, per its readme.
    static let pageEffects = ["clean", "echo", "spring", "pixie", "robot"]

    static func pageLabel(_ page: Int) -> String {
        "Page \(page + 1)"
    }

    static func pageEffect(_ page: Int) -> String {
        pageEffects.indices.contains(page) ? pageEffects[page] : "?"
    }

    enum Button: String, CaseIterable, Sendable {
        case select, play
        var label: String {
            switch self {
            case .select: FXMicControlName.middleButton
            case .play: FXMicControlName.bottomButton
            }
        }
    }

    /// `mic.p<page>.<button>` — one control per page × button, so the orange
    /// button multiplies the two mappable buttons by five.
    static func control(page: Int, button: Button) -> ControlID {
        ControlID(rawValue: "mic.p\(page).\(button.rawValue)")
    }

    static func describe(_ control: ControlID) -> String? {
        let raw = control.rawValue
        guard raw.hasPrefix("mic.p") else { return nil }
        let rest = raw.dropFirst("mic.p".count)
        guard let dot = rest.firstIndex(of: "."),
              let page = Int(rest[..<dot]),
              let button = Button(rawValue: String(rest[rest.index(after: dot)...])) else { return nil }
        return "\(pageLabel(page)) · \(button.label)"
    }

    // MARK: The agent

    /// Pasted through the raw REPL. Wraps whatever callback the firmware
    /// registered (kept in `_mm_orig` so a reinstall never chains two hooks),
    /// samples the inputs each tick, and prints a line on change. Errors
    /// inside the hook are swallowed so a bug here can never take the mic's
    /// own button handling down with it.
    static let agentSource = """
    import teenage
    try:
        _mm_orig
    except NameError:
        _mm_orig = teenage.python_callback
    _mm_state = [None]
    def _mm_hook(*a, **k):
        try:
            h = int(ui.handle() * 20 + 0.5)
            s = (1 - ui.sw(0), 1 - ui.sw(1), 1 - ui.sw(2), h, teenage.fx_pos, teenage.sam_pos)
            if s != _mm_state[0]:
                _mm_state[0] = s
                print("MM", s[0], s[1], s[2], s[3], s[4], s[5])
        except Exception:
            pass
        return _mm_orig(*a, **k)
    ui.callback(_mm_hook)
    print("MM-READY")
    """
}
