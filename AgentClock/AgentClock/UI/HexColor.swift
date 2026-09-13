import SwiftUI
#if os(macOS)
import AppKit
#endif

extension Color {
    /// Parse a `#RRGGBB` string — the one colour format the AWTRIX payload
    /// schema accepts. Returns nil rather than a default so callers can decide
    /// what a bad value means; the device rejects an entire payload over one
    /// malformed colour, so silently substituting would hide a real error.
    init?(hex: String) {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// Back to `#RRGGBB` for the wire. Converted through sRGB explicitly: the
    /// system picker hands back colours in the display's own space, and an
    /// unconverted component can fall outside 0...1 and encode as garbage the
    /// device would reject.
    var hexString: String? {
        #if os(macOS)
        guard let converted = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let clamp = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X",
                      clamp(converted.redComponent),
                      clamp(converted.greenComponent),
                      clamp(converted.blueComponent))
        #else
        return nil
        #endif
    }
}
