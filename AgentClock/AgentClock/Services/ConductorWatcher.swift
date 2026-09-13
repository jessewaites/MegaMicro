import Foundation

/// Watches Conductor's workspace root with FSEvents. Workspace directories
/// appearing/disappearing (agents spawned/archived) update the list; the
/// webhook's `cwd` field then routes agent states to the pinned key.
final class ConductorWatcher {
    let root: URL
    var onChange: ([ConductorWorkspace]) -> Void = { _ in }

    private var stream: FSEventStreamRef?

    init(root: URL) {
        self.root = root
    }

    func start() {
        onChange(scan())
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ConductorWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async {
                watcher.onChange(watcher.scan())
            }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Two-level scan: projects at depth 1, workspaces at depth 2.
    ///
    /// A real worktree is a directory that is NOT a symlink; those are the
    /// workspaces. A sibling symlink (Conductor's branch/feature alias) is
    /// folded into its target's `displayName` rather than counted as a second
    /// workspace. Non-directories and dotfiles are never workspaces.
    func scan() -> [ConductorWorkspace] {
        let fm = FileManager.default
        var result: [ConductorWorkspace] = []
        for project in subdirectories(of: root) {
            var realDirs: [String: URL] = [:]     // city dir name -> url
            var aliasFor: [String: String] = [:]  // city dir name -> branch alias
            for entry in childEntries(of: project) {
                let values = try? entry.resourceValues(
                    forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isSymbolicLink == true {
                    // Resolve the alias to its real worktree; the last path
                    // component is the city directory it stands in for.
                    let realName = entry.resolvingSymlinksInPath().lastPathComponent
                    if aliasFor[realName] == nil {
                        aliasFor[realName] = entry.lastPathComponent
                    }
                } else if values?.isDirectory == true {
                    realDirs[entry.lastPathComponent] = entry
                }
            }
            for (dirName, url) in realDirs {
                result.append(ConductorWorkspace(
                    project: project.lastPathComponent,
                    name: dirName,
                    path: url.path,
                    displayName: aliasFor[dirName] ?? dirName))
            }
        }
        // Stable order: by creation date, so auto-pinned key slots don't shuffle.
        return result.sorted { lhs, rhs in
            let l = (try? fm.attributesOfItem(atPath: lhs.path)[.creationDate] as? Date) ?? .distantPast
            let r = (try? fm.attributesOfItem(atPath: rhs.path)[.creationDate] as? Date) ?? .distantPast
            return l == r ? lhs.id < rhs.id : l < r
        }
    }

    /// Real subdirectories only (symlinks excluded) — used for the project level.
    private func subdirectories(of url: URL) -> [URL] {
        childEntries(of: url).filter { entry in
            let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            return values?.isSymbolicLink != true && values?.isDirectory == true
        }
    }

    /// Every visible child (directories and symlinks alike), so the scan can
    /// tell a real worktree apart from its branch-name alias.
    private func childEntries(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
    }
}
