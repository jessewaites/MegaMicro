import Foundation

/// Reads Conductor's local database (read-only) to learn the actual agent tool
/// running in each workspace. Unlike live webhook telemetry, this is recorded
/// even when no agent is active — so a Conductor workspace key can show the real
/// tool (Codex, Claude, …) instead of a generic Conductor mark.
struct ConductorMetadataStore: Sendable {
    let databaseURL: URL

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.conductor.app/conductor.db")
    }

    /// Agent info keyed by BOTH the workspace's disk path and its directory
    /// name, so a scanned workspace matches by whichever is available (older
    /// rows predate `workspace_path`). Empty when the database can't be read.
    func agentInfoByWorkspace() -> [String: ConductorAgentInfo] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [:] }
        // Latest session per workspace decides the tool; a workspace can outlive
        // several sessions but the most recent is the one that's live/relevant.
        let query = """
        SELECT COALESCE(w.workspace_path, ''), COALESCE(w.directory_name, ''),
               s.agent_type, COALESCE(s.model, '')
        FROM workspaces w
        JOIN sessions s ON s.workspace_id = w.id
        WHERE s.agent_type IS NOT NULL AND s.agent_type != ''
        GROUP BY w.id
        HAVING s.updated_at = MAX(s.updated_at);
        """

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-separator", "\u{1f}", databaseURL.path, query]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [:] }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return Self.parse(text)
        } catch {
            return [:]
        }
    }

    /// Parse the unit-separator-delimited rows into a lookup keyed by path and
    /// directory name. Split out for direct testing.
    static func parse(_ text: String) -> [String: ConductorAgentInfo] {
        var result: [String: ConductorAgentInfo] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count == 4 else { continue }
            let path = fields[0]
            let directoryName = fields[1]
            let agentType = fields[2]
            let model = fields[3].isEmpty ? nil : fields[3]
            guard !agentType.isEmpty else { continue }
            let info = ConductorAgentInfo(agentType: agentType, model: model)
            if !path.isEmpty { result[path] = info }
            if !directoryName.isEmpty { result[directoryName] = info }
        }
        return result
    }
}
