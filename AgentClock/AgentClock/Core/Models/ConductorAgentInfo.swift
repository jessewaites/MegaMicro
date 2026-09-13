import Foundation

/// The tool and model Conductor has recorded for a workspace. Pure data (shared
/// with the iOS/watchOS companions); read from Conductor's database by the macOS
/// `ConductorMetadataStore`.
struct ConductorAgentInfo: Sendable, Equatable, Codable {
    /// Conductor's `agent_type`, e.g. "codex" or "claude".
    let agentType: String
    /// The workspace's model, e.g. "gpt-5.5". Nil when Conductor hasn't set one.
    let model: String?
}
