import Foundation

enum MessageAnimation: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case stream
    case fall
    case showcase

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "Still"
        case .stream: "Stream from right"
        case .fall: "Fall from above"
        case .showcase: "Showcase loop"
        }
    }
}

/// Commands accepted from AgentClock's bundled CLI/MCP bridge. The bridge
/// never learns the panel address or credentials; it asks the running app to
/// perform the operation through the same client used by the fleet publisher.
struct ExternalMessageRequest: Codable, Sendable {
    var text: String
    var id: String? = nil
    var color: String? = nil
    var durationMs: Int? = nil
    var hold: Bool? = nil
    var wakeup: Bool? = nil
    var animation: MessageAnimation? = nil

    var isReasonable: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512 else { return false }
        guard id.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true else { return false }
        guard durationMs.map({ (500...300_000).contains($0) }) ?? true else { return false }
        guard color.map(Self.isHexColor) ?? true else { return false }
        return text.unicodeScalars.allSatisfy {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func isHexColor(_ value: String) -> Bool {
        let raw = value.hasPrefix("#") ? String(value.dropFirst()) : value
        return raw.count == 6 && raw.allSatisfy(\.isHexDigit)
    }
}

struct ExternalClearRequest: Codable, Sendable {
    var id: String?
}
