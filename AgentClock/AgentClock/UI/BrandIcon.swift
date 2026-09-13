import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Brand icons — used anywhere the app mentions Claude, Codex, Conductor, etc.
/// macOS loads the loose `assets/*.svg` bundle resources via `NSImage`;
/// iOS/watchOS load the same marks from `BrandAssets.xcassets` (vector-preserved
/// imagesets, template-tinted for the monochrome ones).
struct BrandIcon: View {
    let asset: String
    var size: CGFloat = 13
    /// Tint for monochrome (template) marks. Default follows the appearance;
    /// pass a fixed color on always-white surfaces like the keycaps.
    var tint: Color? = nil

    /// Monochrome marks are template-rendered so they stay visible on any
    /// background. Colorful marks (Claude, Gemini) keep their brand colors.
    private static let monochromeAssets: Set<String> = [
        "codex", "conductor", "cursor", "opencode", "github-copilot",
        "cline", "roocode", "goose", "qwen", "ghostty", "ghostty-mono",
    ]

    var body: some View {
        let isMono = Self.monochromeAssets.contains(asset)
        if Self.assetExists(asset) {
            image
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .modifier(BrandTint(active: isMono, tint: tint))
        } else {
            Image(systemName: "cpu")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.secondary)
        }
    }

    private var image: Image {
        #if os(macOS)
        if Self.monochromeAssets.contains(asset), let template = Self.templateImage(named: asset) {
            return Image(nsImage: template)
        }
        return Image(nsImage: Self.image(named: asset) ?? NSImage())
        #else
        return Image(asset)
        #endif
    }

    // MARK: Asset existence + source→asset mapping (cross-platform)

    static func assetExists(_ name: String) -> Bool {
        #if os(macOS)
        return image(named: name) != nil
        #else
        return UIImage(named: name) != nil
        #endif
    }

    /// Agent source string (webhook `source` field) → asset name. Convention-
    /// based: any source whose name matches a bundled mark gets its logo.
    static func asset(forSource source: String) -> String? {
        let aliases: [String: String] = [
            "claude-code": "claude", "claude": "claude", "codex": "codex",
            "conductor": "conductor", "gemini-cli": "gemini", "google-gemini": "gemini",
            "antigravity": "antigravity-color", "antigravity-cli": "antigravity-color",
            "agy": "antigravity-color", "github-copilot": "github-copilot",
            "copilot-cli": "github-copilot", "kiro-cli": "kiro", "cline-cli": "cline",
            "roo-code": "roocode", "roocode": "roocode", "roo": "roocode",
            "qwen": "qwen", "qwen-code": "qwen", "continue-cli": "continue",
        ]
        if let alias = aliases[source], assetExists(alias) { return alias }
        let slug = source.lowercased().replacingOccurrences(of: " ", with: "-")
        return assetExists(slug) ? slug : nil
    }

    #if os(macOS)
    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }

    static func templateImage(named name: String) -> NSImage? {
        if let cached = cache["template-" + name] { return cached }
        guard let base = image(named: name), let copy = base.copy() as? NSImage else { return nil }
        copy.isTemplate = true
        cache["template-" + name] = copy
        return copy
    }
    #endif
}

/// Applies a monochrome tint (macOS template images and iOS template imagesets
/// both respond to `foregroundStyle`); leaves colorful marks untouched.
private struct BrandTint: ViewModifier {
    let active: Bool
    let tint: Color?
    func body(content: Content) -> some View {
        if active {
            content.foregroundStyle(tint ?? Color.primary)
        } else {
            content
        }
    }
}

/// Icon for an agent session: its brand logo, or a terminal glyph for
/// unbranded CLI sources.
struct SourceIcon: View {
    let source: String
    var size: CGFloat = 13

    var body: some View {
        if let asset = BrandIcon.asset(forSource: source) {
            BrandIcon(asset: asset, size: size)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.secondary)
        }
    }
}
