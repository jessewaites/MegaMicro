import Foundation

/// Installs a named hook bundle into Antigravity CLI's global hooks file.
/// Antigravity sends identity on stdin, so a tiny bridge extracts the
/// conversation/workspace and forwards a normal AgentClock state report.
final class AntigravityHooksInstaller {
    static let hookName = "agentclock"
    enum InstallError: LocalizedError {
        case malformedHooks
        var errorDescription: String? { "Antigravity hooks.json is malformed; AgentClock left it untouched." }
    }

    let hooksURL: URL
    let bridgeURL: URL
    let backupDir: URL
    let port: UInt16

    init(hooksURL: URL, bridgeURL: URL, backupDir: URL, port: UInt16) {
        self.hooksURL = hooksURL
        self.bridgeURL = bridgeURL
        self.backupDir = backupDir
        self.port = port
    }

    convenience init(port: UInt16) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(
            hooksURL: home.appendingPathComponent(".gemini/config/hooks.json"),
            bridgeURL: BridgeLocator.installedURL,
            backupDir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentClock/backups"),
            port: port)
    }

    var isDetected: Bool {
        let home = hooksURL.deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: home.appendingPathComponent("antigravity-cli").path)
    }

    func isInstalled() -> Bool { load()[Self.hookName] != nil }

    func install() throws {
        _ = try BridgeLocator.ensureInstalled()
        var root = try loadForMutation()
        let handler: [String: Any] = [
            "type": "command",
            "command": "\(shellQuote(bridgeURL.path)) --provider antigravity --event %EVENT% --port \(port) #agentclock",
            "timeout": 5,
        ]
        func command(_ event: String) -> [String: Any] {
            var value = handler
            value["command"] = (handler["command"] as! String).replacingOccurrences(of: "%EVENT%", with: event)
            return value
        }
        root[Self.hookName] = [
            "enabled": true,
            "PreInvocation": [command("PreInvocation")],
            "PreToolUse": [["matcher": "*", "hooks": [command("PreToolUse")]]],
            "PostToolUse": [["matcher": "*", "hooks": [command("PostToolUse")]]],
            "Stop": [command("Stop")],
        ]
        try write(root)
    }

    func uninstall() throws {
        var root = try loadForMutation()
        root.removeValue(forKey: Self.hookName)
        try write(root)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: hooksURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return root
    }

    private func loadForMutation() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: hooksURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.malformedHooks
        }
        return root
    }

    private func write(_ root: [String: Any]) throws {
        if FileManager.default.fileExists(atPath: hooksURL.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? PrivateFileStore.backup(hooksURL,
                to: backupDir.appendingPathComponent("antigravity-hooks-\(stamp).json"))
            PrivateFileStore.pruneBackups(in: backupDir, prefix: "antigravity-hooks-")
        }
        let data = try JSONSerialization.data(withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try PrivateFileStore.write(data, to: hooksURL)
    }
}
