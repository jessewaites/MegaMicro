import Foundation

/// A Claude Code skill, discovered from disk so keys can be bound to one
/// without typing its name from memory.
struct Skill: Identifiable, Hashable, Sendable {
    /// The slug used to invoke it: `/deploy`.
    var name: String
    /// First line of the frontmatter description, for the picker.
    var summary: String
    /// Personal (~/.claude) or belonging to a project checkout.
    var isPersonal: Bool
    /// The project directory this came from, when it isn't personal.
    var projectName: String?

    var id: String { "\(projectName ?? "~"):\(name)" }
    var invocation: String { "/\(name)" }
}

/// Claude Code's own slash commands — the ones that aren't skills and so
/// never appear on disk. Same delivery as a skill: type it, press return.
enum ClaudeCommands {
    static let all: [Skill] = [
        ("model", "Switch Claude models for this session or as the new default"),
        ("fast", "Toggle Fast mode (Opus 5) — faster output, same model"),
        ("clear", "Clear the conversation and start fresh"),
        ("compact", "Summarise the conversation to free up context"),
        ("resume", "Reopen a previous conversation"),
        ("agents", "Manage subagents"),
        ("context", "Show what's currently using the context window"),
        ("cost", "Show token usage and cost for this session"),
        ("config", "Open the settings panel"),
        ("permissions", "Review and edit tool permissions"),
        ("memory", "Edit the project memory files"),
        ("mcp", "Manage MCP server connections"),
        ("status", "Show version, model, account and connectivity"),
        ("doctor", "Diagnose problems with the installation"),
        ("init", "Generate a CLAUDE.md for this codebase"),
        ("help", "List every available command"),
    ].map { Skill(name: $0.0, summary: $0.1, isPersonal: true, projectName: nil) }

    static func contains(_ name: String) -> Bool {
        all.contains { $0.name == name }
    }

}

/// Finds skills in the two places Claude Code keeps them: `~/.claude/skills`
/// and `<project>/.claude/skills`. Each skill is a directory holding a
/// `SKILL.md` whose YAML frontmatter carries `name` and `description`.
enum SkillCatalog {
    static func discover(projectDirectories: [URL] = []) -> [Skill] {
        var found: [Skill] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        found += skills(in: home.appending(path: ".claude/skills"), isPersonal: true, projectName: nil)
        for project in projectDirectories {
            found += skills(in: project.appending(path: ".claude/skills"),
                            isPersonal: false,
                            projectName: project.lastPathComponent)
        }
        // Project skills win over personal ones with the same name, matching
        // how Claude Code resolves them.
        var byName: [String: Skill] = [:]
        for skill in found {
            if let existing = byName[skill.name], !existing.isPersonal { continue }
            byName[skill.name] = skill
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    private static func skills(in directory: URL, isPersonal: Bool, projectName: String?) -> [Skill] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        return entries.compactMap { entry in
            let manifest = entry.appending(path: "SKILL.md")
            guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return nil }
            let fields = frontmatter(of: text)
            // Fall back to the directory name — a skill with no `name:` still
            // invokes fine by its folder.
            let name = fields["name"] ?? entry.lastPathComponent
            guard !name.isEmpty else { return nil }
            return Skill(name: name,
                         summary: fields["description"] ?? "",
                         isPersonal: isPersonal,
                         projectName: projectName)
        }
    }

    /// Minimal YAML frontmatter reader: the `key: value` pairs between the
    /// opening and closing `---`. Enough for `name` and `description`, which
    /// are always single-line in a SKILL.md.
    static func frontmatter(of text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty { fields[key] = value }
        }
        return fields
    }
}
