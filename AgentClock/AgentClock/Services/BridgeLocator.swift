import Foundation

enum BridgeLocator {
    static var bundledURL: URL {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AgentClockBridge"),
           FileManager.default.isExecutableFile(atPath: url.path) { return url }
        // Useful for unit tests and development runs before the copy phase.
        return Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("AgentClockBridge")
    }

    static var installedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentClock/bin/AgentClockBridge")
    }

    @discardableResult
    static func ensureInstalled() throws -> URL {
        let source = bundledURL
        let destination = installedURL
        let sourceData = try Data(contentsOf: source)
        let existingData = try? Data(contentsOf: destination)
        if existingData != sourceData { try PrivateFileStore.write(sourceData, to: destination) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        return destination
    }

    static func command(provider: String, event: String, port: UInt16, url: URL? = nil) -> String {
        let selected = url ?? ((try? ensureInstalled()) ?? bundledURL)
        let path = selected.path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(path)' --provider \(provider) --event \(event) --port \(port) #agentclock"
    }
}
