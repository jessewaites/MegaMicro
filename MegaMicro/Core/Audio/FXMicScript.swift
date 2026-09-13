import Foundation

/// The script MegaMicro installs on the mic's disk as `main.py`.
///
/// The firmware runs `/fat/main.py` at boot after its own app is up, and the
/// app registers a single Python callback for buttons, ticks and the handle.
/// This script wraps that callback. It swallows FX2/FX3/FX4 so the stock
/// behaviour (effect presets, sample cycling, sample playback) never runs,
/// and instead plays short chirp codes out the line jack — the four sample
/// slots hold the four chirps — so MegaMicro can decode every event from
/// audio alone. The red LEDs still count the page.
///
/// Delete the file and the mic is stock again.
enum FXMicScript {
    static let fileName = "main.py"
    static let version = 1

    /// Symbols are the four sample slots. Codes:
    ///   0 / 1 / 2          FX3 down / FX4 down / handle down   (single, fast)
    ///   3 0 / 3 1 / 3 2    FX3 up   / FX4 up   / handle up
    ///   3 3 1 0            page level 0 (clean)
    ///   3 3 0 L            page level L+1 (1…4)
    /// 3 is only ever a prefix, so a lone 0/1/2 is unambiguous the moment it
    /// lands.
    static let source = """
    # MegaMicro control script v\(version) for the EP-2350 FX-MIC.
    # Installed by MegaMicro. Delete this file to get the stock behaviour back.
    import teenage
    _ui = teenage.ui
    _spl = teenage.spl
    _orig = teenage.python_callback

    SPACING = \(spacingTicks)
    HANDLE_ON = 0.05

    _page = -1
    _handle = False
    _queue = []
    _tick = 0
    _next = 0

    def _send(*symbols):
        _queue.extend(symbols)

    def _send_page():
        level = _page + 1
        if level == 0:
            _send(3, 3, 1, 0)
        else:
            _send(3, 3, 0, level - 1)

    def _hook(m):
        global _page, _handle, _tick, _next
        try:
            t = m >> 16
            v = m & 0xFFFF
            if t == 1:
                if v == 2:
                    _page = _page + 1 if _page < 3 else -1
                    teenage.fx_pos = _page
                    _ui.leds(_page, 0)
                    _send_page()
                    return None
                if v == 1:
                    _send(0)
                    return None
                if v == 0:
                    _send(1)
                    return None
            elif t == 2:
                if v == 2:
                    return None
                if v == 1:
                    _send(3, 0)
                    return None
                if v == 0:
                    _send(3, 1)
                    return None
            elif t == 3:
                h = _ui.handle() > HANDLE_ON
                if h != _handle:
                    _handle = h
                    if h:
                        _send(2)
                    else:
                        _send(3, 2)
                if _queue and _tick >= _next:
                    _spl.trigger(-1, _queue.pop(0), True)
                    _next = _tick + SPACING
                _tick += 1
        except Exception:
            pass
        return _orig(m)

    teenage.mm_hook = _hook
    _ui.callback(_hook)
    teenage.fx_pos = -1
    _ui.leds(-1, 0)
    _next = 60
    _send_page()
    """

    /// Ticks between chirps. The firmware ticks at ~60 Hz; 15 ticks is 240 ms,
    /// leaving an 80 ms gap after a 160 ms chirp — at least one silent 50 ms
    /// block, which is what lets two identical symbols in a row be told apart.
    static let spacingTicks = 15
}
