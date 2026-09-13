import Foundation

/// The 8×8 marks AgentClock puts on the panel.
///
/// AWTRIX takes animated GIF (tried first) or static JPEG. We use GIF even for
/// still icons: at 8×8 a JPEG is a single DCT block, so a logo's hard edges
/// come back ringing and muddy, while GIF is palettized and pixel-exact. It
/// also means animating a mark later is purely a data change — add frames to
/// the source grid, regenerate, re-upload; no code here moves.
///
/// An icon's ID is its filename without the extension, so `acclaude.gif` is
/// referenced as `"icon": "acclaude"`.
enum IconLibrary {
    static let prefix = "ac"
    static let fleetIconID = "acfleet"

    /// Provider source string → icon ID. Mirrors `BrandIcon.asset(forSource:)`
    /// but collapses harder: at 8×8 there is no distinguishing Roo from Cline,
    /// so anything unmapped falls through to a generic terminal mark.
    static let bySource: [String: String] = [
        "claude-code": "acclaude",
        "claude": "acclaude",
        "codex": "accodex",
        "gemini-cli": "acgemini",
        "google-gemini": "acgemini",
        "antigravity-cli": "acgemini",
        "cursor": "accursor",
        "github-copilot": "accopilot",
        "copilot-cli": "accopilot",
        "opencode": "acopencode",
        "qwen-code": "acqwen",
    ]

    /// Every icon that ships with the app, and therefore everything the
    /// uploader has to make sure is on the device.
    static var allIDs: [String] {
        Array(Set(bySource.values)).sorted() + [fleetIconID, genericID, subagentID]
    }

    static let genericID = "acterm"

    /// The subagent glyph: the same creature at 5x4. Drawn white so callers can
    /// tint it per state — shape says what it is, colour says what it's doing.
    static let subagentID = "acclaudesub"

    static func iconID(forSource source: String) -> String {
        bySource[source.lowercased()] ?? genericID
    }

    /// The bundled GIF for an icon ID, if it was generated.
    static func bundledGIF(id: String) -> Data? {
        guard let url = Bundle.main.url(forResource: id, withExtension: "gif") else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Put every missing icon on the device.
    ///
    /// Idempotent and cheap: it lists `/ICONS` first and uploads only the gaps,
    /// so it costs one request on a healthy device. Running it on every connect
    /// means a factory-reset clock re-heals without the user doing anything.
    /// Storage is 512 KB on a 4 MB board — a dozen 8×8 GIFs is a rounding error.
    @discardableResult
    static func syncMissing(using client: AwtrixClient) async -> [String] {
        let present: Set<String>
        do {
            present = try await client.icons().iconIDs
        } catch {
            return []
        }
        var uploaded: [String] = []
        for id in allIDs where !present.contains(id) {
            guard let data = bundledGIF(id: id) else { continue }
            do {
                try await client.uploadIcon(filename: "\(id).gif", data: data)
                uploaded.append(id)
            } catch {
                // A full filesystem or a rejected frame size shouldn't stop the
                // rest; pages render fine without an icon.
                continue
            }
        }
        return uploaded
    }
}
