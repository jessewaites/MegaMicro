import XCTest
@testable import MegaMicro

@MainActor
final class GhosttyMatchTests: XCTestCase {
    typealias Terminal = AgentFocusService.GhosttyTerminal

    // Ghostty's real ordering: the parent-folder tab is listed before the
    // project's own tab, which is what made first-match-wins pick it.
    private let board = [
        Terminal(id: "A", path: "/Users/j/code/designed-with-ai-next", title: "npm run dev"),
        Terminal(id: "B", path: "/Users/j/code", title: "Code"),
        Terminal(id: "C", path: "/Users/j/code/airtest", title: "✳ Debug Jira integration"),
        Terminal(id: "D", path: "/Users/j/code/MegaMicro", title: "⠐ Fix ghostty forwarding"),
    ]

    private func match(_ path: String, titles: [String] = []) -> String? {
        AgentFocusService.bestGhosttyMatch(
            terminals: board, workingDirectory: path, titles: titles)?.id
    }

    func testExactDirectoryBeatsParentFolderListedEarlier() {
        XCTAssertEqual(match("/Users/j/code/airtest"), "C")
    }

    func testParentFolderTabIsNeverPreferredOverTheProjectsOwn() {
        XCTAssertEqual(match("/Users/j/code/MegaMicro"), "D")
        XCTAssertEqual(match("/Users/j/code/designed-with-ai-next"), "A")
    }

    func testParentFolderStillMatchesWhenNothingElseDoes() {
        XCTAssertEqual(match("/Users/j/code/no-tab-open"), "B")
    }

    func testNearestParentWins() {
        let terminals = board + [Terminal(id: "E", path: "/Users/j", title: "home")]
        XCTAssertEqual(AgentFocusService.bestGhosttyMatch(
            terminals: terminals, workingDirectory: "/Users/j/code/no-tab-open",
            titles: [])?.id, "B")
    }

    func testSubdirectoryOfTheProjectCounts() {
        XCTAssertEqual(match("/Users/j/code/MegaMicro/Docs"), "D")
    }

    func testPathComparisonIsCaseInsensitive() {
        XCTAssertEqual(match("/Users/j/Code/MegaMicro"), "D")
    }

    func testTrailingSlashDoesNotBreakTheExactMatch() {
        XCTAssertEqual(match("/Users/j/code/airtest/"), "C")
    }

    func testTitleBreaksTiesBetweenTabsSharingADirectory() {
        let terminals = [
            Terminal(id: "server", path: "/Users/j/code/site", title: "npm run dev"),
            Terminal(id: "agent", path: "/Users/j/code/site", title: "claude — site"),
        ]
        XCTAssertEqual(AgentFocusService.bestGhosttyMatch(
            terminals: terminals, workingDirectory: "/Users/j/code/site",
            titles: ["claude"])?.id, "agent")
    }

    func testTitleMatchIsUsedWhenNoDirectoryMatches() {
        XCTAssertEqual(match("/elsewhere/project", titles: ["npm run dev"]), "A")
    }

    func testUnrelatedPathWithNoTitleMatchesNothing() {
        XCTAssertNil(match("/elsewhere/project"))
        XCTAssertNil(match("/elsewhere/project", titles: ["nothing here"]))
    }

    func testEmptyInputs() {
        XCTAssertNil(match(""))
        XCTAssertNil(AgentFocusService.bestGhosttyMatch(
            terminals: [], workingDirectory: "/Users/j/code/airtest", titles: []))
    }
}
