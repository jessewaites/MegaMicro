import Foundation

/// Reads the current git branch for a working directory by parsing `.git`
/// directly — no `git` subprocess, so it's cheap enough to call from label
/// resolution. Handles both a normal repo (`.git` is a directory) and a
/// worktree (`.git` is a file with a `gitdir:` pointer, as Conductor and
/// `git worktree` create). Returns nil when the path isn't in a repo or HEAD
/// is detached.
enum GitBranchResolver {
    static func branch(atPath path: String, fileManager fm: FileManager = .default) -> String? {
        var dir = URL(fileURLWithPath: path).standardizedFileURL
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let gitDir: URL
                if isDirectory.boolValue {
                    gitDir = dotGit
                } else if let resolved = worktreeGitDir(dotGit) {
                    gitDir = resolved
                } else {
                    return nil
                }
                return headBranch(at: gitDir.appendingPathComponent("HEAD"))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }  // reached the filesystem root
            dir = parent
        }
    }

    /// Resolve a worktree's `.git` file (`gitdir: /path/to/.git/worktrees/x`)
    /// to the directory whose HEAD holds that worktree's branch.
    private static func worktreeGitDir(_ dotGitFile: URL) -> URL? {
        guard let contents = try? String(contentsOf: dotGitFile, encoding: .utf8) else { return nil }
        for line in contents.split(whereSeparator: \.isNewline) where line.hasPrefix("gitdir:") {
            let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            let url = URL(fileURLWithPath: target)
            // gitdir may be relative to the worktree directory.
            return url.path.hasPrefix("/")
                ? url
                : dotGitFile.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
        }
        return nil
    }

    /// Parse `HEAD`: `ref: refs/heads/<branch>` → the branch; a raw SHA
    /// (detached HEAD) → nil.
    private static func headBranch(at headURL: URL) -> String? {
        guard let head = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard trimmed.hasPrefix(prefix) else { return nil }
        let branch = String(trimmed.dropFirst(prefix.count))
        return branch.isEmpty ? nil : branch
    }
}
