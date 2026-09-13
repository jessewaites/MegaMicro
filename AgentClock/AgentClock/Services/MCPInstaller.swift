import Foundation

enum MCPClient: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }
    var displayName: String { self == .claude ? "Claude Code" : "Codex" }
}

enum MCPInstaller {
    enum InstallError: LocalizedError {
        case executableNotFound(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .executableNotFound(let name): "Could not find the \(name) command-line tool."
            case .commandFailed(let detail): detail
            }
        }
    }

    static func isDetected(_ client: MCPClient) -> Bool { executable(for: client) != nil }

    static func install(_ client: MCPClient, port: UInt16) throws {
        guard let executable = executable(for: client) else {
            throw InstallError.executableNotFound(client.displayName)
        }
        let bridge = try BridgeLocator.ensureInstalled()
        var arguments = ["mcp", "add"]
        if client == .claude { arguments += ["--scope", "user"] }
        arguments += ["agentclock", "--", bridge.path, "--mcp", "--port", String(port)]
        try run(executable, arguments: arguments)
    }

    static func remove(_ client: MCPClient) throws {
        guard let executable = executable(for: client) else {
            throw InstallError.executableNotFound(client.displayName)
        }
        var arguments = ["mcp", "remove"]
        if client == .claude { arguments += ["--scope", "user"] }
        arguments += ["agentclock"]
        try run(executable, arguments: arguments)
    }

    private static func executable(for client: MCPClient) -> URL? {
        let name = client.rawValue
        let roots = [
            "/opt/homebrew/bin", "/usr/local/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/.npm-global/bin",
        ]
        return roots.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func run(_ executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let detail = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw InstallError.commandFailed(detail.isEmpty ? "MCP registration failed." : detail)
        }
    }
}

