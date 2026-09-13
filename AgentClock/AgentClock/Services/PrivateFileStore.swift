import Foundation

/// Shared permissions/retention policy for files that may contain project
/// paths, task text, hook commands, environment values, or API credentials.
enum PrivateFileStore {
    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func write(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func backup(_ source: URL, to destination: URL) throws {
        try ensureDirectory(destination.deletingLastPathComponent())
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func pruneBackups(in directory: URL, prefix: String, keeping limit: Int = 10) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let matching = files.filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for old in matching.dropFirst(limit) { try? FileManager.default.removeItem(at: old) }
    }

    static func hardenExistingTree(_ root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            try? FileManager.default.setAttributes(
                [.posixPermissions: isDirectory ? 0o700 : 0o600], ofItemAtPath: url.path)
        }
    }
}
