import XCTest
@testable import MegaMicro

final class ConfigRoundtripTests: XCTestCase {
    func testDefaultsRoundTripThroughJSON() throws {
        let config = AppConfig()
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testSaveAndLoad() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("megamicro-tests-\(UUID().uuidString)")
        let store = ConfigStore(fileURL: dir.appendingPathComponent("config.json"))
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = AppConfig()
        config.activeProfileID = "ghostty"
        config.keyBindings = [0: .workspace("flightwatch/dallas"), 3: .path("/Users/j/code/app"), 5: .off]
        try store.save(config)

        let loaded = store.load()
        XCTAssertEqual(loaded, config)
    }

    func testLoadMissingFileYieldsDefaults() {
        let store = ConfigStore(fileURL: URL(fileURLWithPath: "/nonexistent/nope.json"))
        XCTAssertEqual(store.load(), AppConfig())
    }

    func testCorruptFileYieldsDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("megamicro-corrupt-\(UUID().uuidString).json")
        try Data("not json {{{".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ConfigStore(fileURL: url).load(), AppConfig())
    }

    func testOlderConfigMissingNewKeysDecodesWithDefaults() throws {
        // A config file written before keyLegends existed.
        let old = #"{"version":1,"webhookPort":48802,"activeProfileID":"ghostty","workspaceKeyPins":{"proj/ws":3}}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.activeProfileID, "ghostty")
        XCTAssertEqual(decoded.workspaceKeyPins, ["proj/ws": 3], "raw decode keeps legacy pins for migration")
        XCTAssertEqual(decoded.keyLegends, [:])
        XCTAssertFalse(decoded.profiles.isEmpty, "missing profiles falls back to defaults")
        XCTAssertEqual(decoded.promptSnippets, DefaultPromptSnippets.all)
    }

    func testDefaultPromptSnippetsContainNoTemplateVariables() {
        for snippet in DefaultPromptSnippets.all {
            XCTAssertFalse(snippet.prompt.contains("{{"), snippet.name)
            XCTAssertFalse(snippet.prompt.contains("}}"), snippet.name)
        }
        XCTAssertEqual(DefaultPromptSnippets.all.first?.name, "How This Works")
        XCTAssertEqual(DefaultPromptSnippets.worker.name, "Parallel Builder")
        XCTAssertTrue(
            DefaultPromptSnippets.planner.prompt.contains(
                "prefixed by phase (A1, A2, B1...)"))
        XCTAssertTrue(
            DefaultPromptSnippets.planner.prompt.contains(
                "Commit to the current parent feature branch and push that branch."))
        XCTAssertTrue(
            DefaultPromptSnippets.planner.prompt.contains(
                "Default to a single phase."))
        XCTAssertTrue(
            DefaultPromptSnippets.planner.prompt.contains(
                "MASTER.md states the phases"))
        XCTAssertTrue(
            DefaultPromptSnippets.planner.prompt.contains(
                "exactly one track owner or is explicitly listed in MASTER.md as integration-owned"))
        XCTAssertTrue(
            DefaultPromptSnippets.planner.prompt.contains("its expected branch name"))
        XCTAssertFalse(DefaultPromptSnippets.planner.prompt.contains("megaplan-v1"))
        XCTAssertTrue(
            DefaultPromptSnippets.worker.prompt.contains("`TODO(integration):`"))
        XCTAssertTrue(
            DefaultPromptSnippets.worker.prompt.contains(
                "Tracks in earlier phases are already merged into your branch."))
        XCTAssertTrue(
            DefaultPromptSnippets.worker.prompt.contains(
                "Do not edit anything under MegaPlan/."))
        XCTAssertTrue(
            DefaultPromptSnippets.worker.prompt.contains(
                "The final implementation commit message must summarize"))
        XCTAssertTrue(
            DefaultPromptSnippets.integrator.prompt.contains(
                "Grep the merged tree for `TODO(integration):` and resolve every one."))
        XCTAssertTrue(
            DefaultPromptSnippets.howThisWorks.prompt.contains(
                "For each track in phase A, create a Conductor workspace from branch-name"))
        XCTAssertTrue(
            DefaultPromptSnippets.howThisWorks.prompt.contains(
                "0. PREPARE THE FEATURE BRANCH"))
        XCTAssertTrue(
            DefaultPromptSnippets.howThisWorks.prompt.contains(
                "git checkout -b branch-name"))
        XCTAssertTrue(
            DefaultPromptSnippets.howThisWorks.prompt.contains(
                "When creating each new workspace, set Base Branch to branch-name."))
        XCTAssertTrue(
            DefaultPromptSnippets.howThisWorks.prompt.contains(
                "only ship to main after you know it all works together."))
        XCTAssertFalse(
            DefaultPromptSnippets.howThisWorks.prompt.contains(
                "If you revise the plan mid-flight"))
        XCTAssertFalse(
            DefaultPromptSnippets.howThisWorks.prompt.contains(
                "What you give up by trimming"))
        XCTAssertTrue(
            DefaultPromptSnippets.howThisWorks.prompt.contains(
                "git worktree add ../proj-a1 -b track/a1 branch-name"))
        XCTAssertTrue(
            DefaultPromptSnippets.howThisWorks.prompt.contains(
                "run the full checkpoint verification from MASTER.md."))
        XCTAssertTrue(
            DefaultPromptSnippets.howThisWorks.prompt.contains(
                "git diff --name-only \"$(git merge-base <parent-feature-branch> <track-branch>)\"...<track-branch>"))
        XCTAssertTrue(
            DefaultPromptSnippets.howThisWorks.prompt.contains(
                "Do not create phase B workspaces unless the checkpoint is green."))
        XCTAssertTrue(
            DefaultPromptSnippets.integrator.prompt.contains(
                "All track work has already been merged into this branch."))
        XCTAssertTrue(
            DefaultPromptSnippets.integrator.prompt.contains(
                "inspect its original branch diff and the corresponding merge commit"))
        XCTAssertFalse(
            DefaultPromptSnippets.integrator.prompt.contains(
                "Merge in the order given in MASTER.md."))
        XCTAssertTrue(
            DefaultPromptSnippets.all.allSatisfy {
                !$0.prompt.contains("MegaPlan/reports") &&
                !$0.prompt.contains("git show track/") &&
                !$0.prompt.contains("INTEGRATION.md") &&
                !$0.prompt.contains("briefs/")
            })
    }

    func testDefaultProfilesCoverAllMappedControls() {
        let layout = CodexMicroLayout.layout
        for profile in DefaultProfiles.all {
            for (control, gestures) in profile.mappings {
                let spec = layout.control(control)
                XCTAssertNotNil(spec, "\(profile.id) maps unknown control \(control.rawValue)")
                for gesture in gestures.keys {
                    XCTAssertTrue(spec?.gestures.contains(gesture) ?? false,
                                  "\(profile.id): \(control.rawValue) does not support \(gesture)")
                }
            }
        }
    }

    func testTriggerBindingsAreUnique() {
        let triggers = DefaultTriggers.codexMicro.map(\.trigger)
        XCTAssertEqual(triggers.count, Set(triggers).count, "duplicate trigger chords")
        let pairs = DefaultTriggers.codexMicro.map { "\($0.control.rawValue)/\($0.gesture.rawValue)" }
        XCTAssertEqual(pairs.count, Set(pairs).count, "duplicate control/gesture assignment")
    }

    func testMigrationRefreshesBuiltinsKeepsCustom() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("megamicro-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(fileURL: dir.appendingPathComponent("config.json"))

        var old = AppConfig()
        old.version = 1
        var custom = DefaultProfiles.ghostty
        custom.id = "my-custom"
        custom.name = "Mine"
        old.profiles.append(custom)
        old.workspaceKeyPins = ["p/w": 2]
        old.keyBindings = [:]
        try store.save(old)

        let migrated = store.load()
        XCTAssertEqual(migrated.version, AppConfig.currentVersion)
        XCTAssertTrue(migrated.profiles.contains { $0.id == "my-custom" }, "custom profiles survive")
        XCTAssertEqual(migrated.layoutSettings["codex-micro"]?.keyBindings[2], .workspace("p/w"),
                       "legacy pins become per-layout key bindings")
        XCTAssertTrue(migrated.workspaceKeyPins.isEmpty, "legacy pin store emptied after migration")
        XCTAssertTrue(migrated.keyBindings.isEmpty, "intermediate v3 store emptied after v5")
        let conductor = migrated.profiles.first { $0.id == "conductor" }
        XCTAssertEqual(conductor, DefaultProfiles.conductor, "built-ins refreshed to current defaults")
    }

    func testMigrationV4MapsKey10ToCycleProfileEverywhere() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("megamicro-v4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(fileURL: dir.appendingPathComponent("config.json"))

        var old = AppConfig()
        old.version = 3
        var custom = DefaultProfiles.ghostty
        custom.id = "custom"
        custom.mappings[.key(10)] = [.press: .shell(command: "echo old")]
        old.profiles.append(custom)
        try store.save(old)

        let migrated = store.load()
        for profile in migrated.profiles {
            XCTAssertEqual(profile.action(for: .key(10), gesture: .press), .cycleProfile,
                           "\(profile.id) key 10 must be the profile switcher")
        }
    }

    func testDefaultProfilesHaveCycleProfileOnKey10() {
        for profile in DefaultProfiles.all {
            XCTAssertEqual(profile.action(for: .key(10), gesture: .press), .cycleProfile)
        }
    }

    func testMosaicProfileUsesTerminalSafeApprovalAndAggregateUnderglow() {
        let profile = DefaultProfiles.mosaic

        XCTAssertEqual(profile.appBundleIDs, ["mosaic.com.emergent.app"])
        XCTAssertEqual(
            profile.action(for: .key(6), gesture: .press),
            .keystroke(
                chord: KeyChord(keyCode: KeyCodes.f13, modifiers: []),
                target: .frontmost))
        XCTAssertEqual(profile.underglow, .aggregate)
    }

    func testCodexLayoutHasNoTouchStrip() {
        XCTAssertNil(CodexMicroLayout.layout.control(.touchStrip))
        XCTAssertFalse(DefaultTriggers.codexMicro.contains { $0.control == .touchStrip })
        for profile in DefaultProfiles.all {
            XCTAssertNil(profile.mappings[.touchStrip], "\(profile.id) must not map the touch strip")
        }
    }

    func testLayoutHasTwelveLEDsAndThirteenControlsThatPress() {
        let layout = CodexMicroLayout.layout
        XCTAssertEqual(layout.ledCount, 12)
        XCTAssertEqual(layout.controls.filter { $0.kind == .key }.count, 12)
        XCTAssertEqual(layout.controls.filter { $0.kind == .touchButton }.count, 1,
                       "the round profile button is a touch button, not a keycap")
        let ledIndices = layout.controls.compactMap(\.ledIndex).sorted()
        XCTAssertEqual(ledIndices, Array(0..<12), "LED indices must be 0–11 with no gaps")
        // Only the six translucent agent keys host agents — matching the
        // firmware's addressable agent-key ids 0–5.
        let hostable = layout.controls.filter { $0.kind == .key && $0.hostsAgents }
        XCTAssertEqual(hostable.map(\.ledIndex), [0, 1, 2, 3, 4, 5])
    }

    func testControlSpecWithoutHostsAgentsFieldDecodesTrue() throws {
        var spec = CodexMicroLayout.layout.controls[1]
        spec.hostsAgents = true
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as! [String: Any]
        json.removeValue(forKey: "hostsAgents")
        let decoded = try JSONDecoder().decode(ControlSpec.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.hostsAgents, "older imported layouts host agents on every key")
    }

    func testMigrationV7MakesKey11TheTalkKey() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("megamicro-v7-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(fileURL: dir.appendingPathComponent("config.json"))

        var old = AppConfig()
        old.version = 6
        var settings = LayoutSettings()
        settings.keyLegends[.key(11)] = "Talk"
        old.layoutSettings["codex-micro"] = settings
        try store.save(old)

        let migrated = store.load()
        let talk = Action.holdKeystroke(
            chord: KeyChord(keyCode: KeyCodes.z, modifiers: .command), target: .frontmost)
        for profile in migrated.profiles {
            XCTAssertEqual(profile.action(for: .key(11), gesture: .press), talk)
        }
        XCTAssertNil(migrated.layoutSettings["codex-micro"]?.keyLegends[.key(11)],
                     "legacy Talk text label retired in favor of the mic glyph")
    }
}
