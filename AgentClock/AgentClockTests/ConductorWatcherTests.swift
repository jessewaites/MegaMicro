import XCTest
@testable import AgentClock

final class ConductorWatcherTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentclock-conductor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(path),
            withIntermediateDirectories: true)
    }

    /// Create a symlink `linkPath` pointing at existing dir `targetPath`,
    /// mirroring how Conductor aliases a worktree by its branch/feature name.
    private func symlink(_ linkPath: String, to targetPath: String) throws {
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(linkPath),
            withDestinationURL: root.appendingPathComponent(targetPath))
    }

    func testScanFindsProjectWorkspacePairs() throws {
        try mkdir("flightwatch/dallas")
        try mkdir("PeopleSmarts/kathmandu")
        try mkdir("PeopleSmarts/warsaw")

        let found = ConductorWatcher(root: root).scan()
        XCTAssertEqual(Set(found.map(\.id)),
                       ["flightwatch/dallas", "PeopleSmarts/kathmandu", "PeopleSmarts/warsaw"])
    }

    func testScanIgnoresFilesAndHiddenEntries() throws {
        try mkdir("proj/ws")
        try mkdir("proj/.hidden")
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("conductor.db").path,
            contents: Data("sqlite".utf8))
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("proj/notes.txt").path,
            contents: Data("x".utf8))

        let found = ConductorWatcher(root: root).scan()
        XCTAssertEqual(found.map(\.id), ["proj/ws"])
    }

    func testScanEmptyOrMissingRoot() {
        XCTAssertEqual(ConductorWatcher(root: root).scan(), [])
        let missing = ConductorWatcher(root: root.appendingPathComponent("nope"))
        XCTAssertEqual(missing.scan(), [])
    }

    // Conductor renames a workspace by adding a symlink named after the branch
    // (font-color-changes -> bozeman), not by renaming the worktree. The alias
    // must fold into one workspace, keyed on the stable city dir, surfacing the
    // branch as displayName — never counted as a second workspace.
    func testSymlinkAliasFoldsIntoOneWorkspaceWithBranchDisplayName() throws {
        try mkdir("PeopleSmarts/bozeman")
        try symlink("PeopleSmarts/font-color-changes", to: "PeopleSmarts/bozeman")

        let found = ConductorWatcher(root: root).scan()
        XCTAssertEqual(found.map(\.id), ["PeopleSmarts/bozeman"])
        XCTAssertEqual(found.first?.name, "bozeman")
        XCTAssertEqual(found.first?.displayName, "font-color-changes")
    }

    func testWorkspaceWithoutAliasDisplaysCityName() throws {
        try mkdir("PeopleSmarts/warsaw")

        let found = ConductorWatcher(root: root).scan()
        XCTAssertEqual(found.map(\.id), ["PeopleSmarts/warsaw"])
        XCTAssertEqual(found.first?.displayName, "warsaw")
    }

    func testMultipleWorkspacesEachKeepTheirOwnAlias() throws {
        try mkdir("PeopleSmarts/bozeman")
        try mkdir("PeopleSmarts/buffalo")
        try mkdir("PeopleSmarts/warsaw")
        try symlink("PeopleSmarts/font-color-changes", to: "PeopleSmarts/bozeman")
        try symlink("PeopleSmarts/kaleidoscope-pulse-effect", to: "PeopleSmarts/buffalo")

        let found = ConductorWatcher(root: root).scan()
        // Three real worktrees, not five entries — the two symlinks are aliases.
        XCTAssertEqual(Set(found.map(\.id)),
                       ["PeopleSmarts/bozeman", "PeopleSmarts/buffalo", "PeopleSmarts/warsaw"])
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.displayName) })
        XCTAssertEqual(byID["PeopleSmarts/bozeman"], "font-color-changes")
        XCTAssertEqual(byID["PeopleSmarts/buffalo"], "kaleidoscope-pulse-effect")
        XCTAssertEqual(byID["PeopleSmarts/warsaw"], "warsaw")
    }
}
