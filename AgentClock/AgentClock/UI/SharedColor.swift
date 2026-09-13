import SwiftUI

extension Color {
    /// Neutral control-surface fill, resolved per platform (macOS uses the
    /// AppKit control background; iOS/watchOS a system grouped background).
    static var controlSurface: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #elseif os(watchOS)
        Color.gray.opacity(0.18)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}
