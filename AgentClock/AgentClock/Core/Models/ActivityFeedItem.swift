import Foundation

struct ActivityFeedItem: Identifiable, Sendable, Codable {
    enum Category: String, CaseIterable, Sendable, Codable {
        case attention = "Attention"
        case working = "Working"
        case completed = "Completed"
        case presence = "Online / Idle"
    }

    var id = UUID()
    let at: Date
    let category: Category
    let state: AgentState
    let source: String
    let agentName: String
    let project: String?
    let keySlot: Int?
    let message: String
    let simulated: Bool
}
