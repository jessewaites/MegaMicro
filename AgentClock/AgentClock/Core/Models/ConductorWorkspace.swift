import Foundation

/// One Conductor workspace (an isolated git worktree) on disk at
/// ~/conductor/workspaces/<project>/<workspace>.
///
/// Conductor names the real worktree directory after a city (e.g. `bozeman`)
/// and keeps that name stable for the workspace's whole life. Once work starts
/// it drops a sibling *symlink* named after the branch/feature
/// (`font-color-changes -> bozeman`) — that alias is what the user sees. We key
/// identity off the stable city directory and surface the alias as `displayName`.
///
/// Pure data (shared with the iOS/watchOS companions); the FSEvents watcher that
/// produces these lives in `ConductorWatcher` (macOS only).
struct ConductorWorkspace: Identifiable, Hashable, Sendable, Codable {
    let project: String
    /// Real on-disk directory name (the city). Stable for the workspace's life.
    let name: String
    /// Canonical worktree path (the real directory, never the symlink).
    let path: String
    /// Human-facing name: Conductor's branch/feature alias if one points here,
    /// otherwise the city `name`.
    let displayName: String

    /// Stable id used as the key in workspaceKeyPins. Based on the city dir so
    /// pins survive Conductor renaming the workspace (which only adds a symlink).
    var id: String { "\(project)/\(name)" }
}
