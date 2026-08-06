import AppKit
import ApplicationServices

/// Raises the window most likely to contain an agent. Window-title matching
/// gets us to an existing terminal/editor window without starting a duplicate;
/// source-specific app activation is the safe fallback.
@MainActor
final class AgentFocusService {
    var log: (String) -> Void = { _ in }

    private static let openCodeDesktopBundleIDs = [
        "ai.opencode.desktop",
        "ai.opencode.desktop.beta",
        "ai.opencode.desktop.dev",
    ]

    /// Conductor 0.71+ exposes existing workspaces in its documented command
    /// palette. Unlike the public deep-link API (which creates workspaces),
    /// this navigates to an existing workspace and needs no live hook session.
    func focusConductorWorkspace(project: String, name: String, workspacePath: String) {
        Task { @MainActor in
            // Conductor's Copy Link action uses this stable workspace UUID.
            // Resolve it lazily from Conductor's read-only local database so
            // newly created workspaces need no manual setup in MegaMicro.
            let workspaceID = conductorWorkspaceID(
                project: project, name: name, workspacePath: workspacePath)

            // Compatibility fallback for an older or changed Conductor
            // database: use its documented command palette by workspace name.
            let bundleID = DefaultProfiles.conductorBundleID
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate(options: [.activateAllWindows])
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
            } else {
                log("Conductor app not found")
                return
            }

            try? await Task.sleep(for: .milliseconds(220))
            post(KeyChord(keyCode: KeyCodes.k, modifiers: .command))
            try? await Task.sleep(for: .milliseconds(140))
            postText(name)
            try? await Task.sleep(for: .milliseconds(180))
            post(KeyChord(keyCode: KeyCodes.returnKey, modifiers: []))
            if let workspaceID {
                log("requested local Conductor workspace \(project)/\(name) [\(workspaceID)]")
            } else {
                log("requested local Conductor workspace \(project)/\(name)")
            }
        }
    }

    private func conductorWorkspaceID(project: String, name: String,
                                      workspacePath: String) -> String? {
        let databaseURL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.conductor.app/conductor.db")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        func sqlString(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
        let query = """
        SELECT w.id
        FROM workspaces w
        LEFT JOIN repos r ON r.id = w.repository_id
        WHERE w.workspace_path = \(sqlString(workspacePath))
           OR (r.name = \(sqlString(project)) AND w.directory_name = \(sqlString(name)))
        ORDER BY CASE WHEN w.workspace_path = \(sqlString(workspacePath)) THEN 0 ELSE 1 END
        LIMIT 1;
        """

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", databaseURL.path, query]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let value = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard UUID(uuidString: value) != nil else { return nil }
            return value.lowercased()
        } catch {
            return nil
        }
    }

    func focus(session: AgentSession, isConductorWorkspace: Bool, activeProfileID: String) {
        let project = session.cwd.map { ($0 as NSString).lastPathComponent } ?? session.agent ?? session.source

        // OpenCode Desktop registers a supported open-project deep link. Use
        // it only when Desktop is already running: an OpenCode CLI session in
        // Ghostty should continue to focus its exact terminal instead of
        // unexpectedly launching the desktop client.
        if session.source.lowercased() == "opencode",
           let cwd = session.cwd,
           focusOpenCodeDesktop(workingDirectory: cwd, label: session.agent ?? project) {
            return
        }

        if activeProfileID == "iterm2",
           !isConductorWorkspace,
           focusITerm2Session(session, workingDirectory: session.cwd,
                              label: session.agent ?? project) {
            return
        }

        if activeProfileID == "wezterm", !isConductorWorkspace,
           focusWezTermPane(session, label: session.agent ?? project) {
            return
        }

        if activeProfileID == "kitty", !isConductorWorkspace,
           focusKittyWindow(session, label: session.agent ?? project) {
            return
        }

        // Ghostty 1.3+ exposes terminals (including tabs and splits) through
        // AppleScript with their live working directories. This is an exact
        // target, unlike window-title matching, and `focus` also raises the
        // owning window when Ghostty is behind another application.
        if activeProfileID == "ghostty",
           !isConductorWorkspace,
           let cwd = session.cwd,
           focusGhosttyTerminal(
                workingDirectory: cwd,
                matchingTitles: [project, session.agent].compactMap { $0 },
                label: session.agent ?? project) {
            return
        }

        if raiseWindow(matching: [project, session.agent].compactMap { $0 }) {
            log("focused \(session.agent ?? project)")
            return
        }

        let bundleID = if isConductorWorkspace {
            DefaultProfiles.conductorBundleID
        } else if let profileBundleID = terminalBundleID(for: activeProfileID) {
            profileBundleID
        } else {
            fallbackBundleID(for: session.source)
        }
        guard let bundleID else {
            log("no running window found for \(session.agent ?? project)")
            return
        }
        activate(bundleID: bundleID, label: session.agent ?? project)
    }

    private func focusOpenCodeDesktop(workingDirectory path: String, label: String) -> Bool {
        guard let app = Self.openCodeDesktopBundleIDs.lazy
            .compactMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first })
            .first,
              let appURL = app.bundleURL,
              var components = URLComponents(string: "opencode://open-project") else { return false }
        components.queryItems = [URLQueryItem(name: "directory", value: path)]
        guard let deepLink = components.url else { return false }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [deepLink], withApplicationAt: appURL, configuration: configuration
        ) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.log("OpenCode focus failed for \(label): \(error.localizedDescription)")
                } else {
                    self?.log("focused OpenCode Desktop for \(label)")
                }
            }
        }
        return true
    }

    private func focusITerm2Session(_ session: AgentSession, workingDirectory path: String?,
                                    label: String) -> Bool {
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: DefaultProfiles.iTerm2BundleID).first != nil else { return false }

        // iTerm2 documents this URL specifically for returning to an existing
        // session. ITERM_SESSION_ID distinguishes tabs and split panes even
        // when several agents share one working directory.
        if let id = session.terminalSession,
           var components = URLComponents(string: "iterm2:///reveal") {
            components.queryItems = [URLQueryItem(name: "sessionid", value: id)]
            if let url = components.url {
                NSWorkspace.shared.open(url)
                log("focused iTerm2 session for \(label)")
                return true
            }
        }

        guard let path else { return false }
        return focusITerm2ByWorkingDirectory(path, label: label)
    }

    private func focusITerm2ByWorkingDirectory(_ path: String, label: String) -> Bool {
        func appleScriptString(_ value: String) -> String {
            "\"" + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = """
        tell application id "com.googlecode.iterm2"
            repeat with candidateWindow in windows
                repeat with candidateTab in tabs of candidateWindow
                    repeat with candidateSession in sessions of candidateTab
                        set sessionPath to variable "path" of candidateSession
                        if sessionPath is \(appleScriptString(path)) or sessionPath starts with \(appleScriptString(path + "/")) then
                            select candidateSession
                            select candidateTab
                            activate
                            return unique id of candidateSession
                        end if
                    end repeat
                end repeat
            end repeat
            return ""
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int
            if number == -1743 {
                log("iTerm2 automation permission is required to focus \(label)")
            } else {
                log("iTerm2 focus failed for \(label): \(error[NSAppleScript.errorMessage] ?? "unknown error")")
            }
            return false
        }
        guard !result.stringValue.isNilOrEmpty else { return false }
        log("focused iTerm2 terminal for \(label)")
        return true
    }

    private func focusWezTermPane(_ session: AgentSession, label: String) -> Bool {
        guard session.terminalKind == "wezterm", let paneID = session.terminalSession,
              let executable = executableURL([
                "/Applications/WezTerm.app/Contents/MacOS/wezterm",
                "/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm"
              ]), run(executable, arguments: ["cli", "activate-pane", "--pane-id", paneID]) else {
            return false
        }
        activate(bundleID: DefaultProfiles.wezTermBundleID, label: label)
        log("focused WezTerm pane for \(label)")
        return true
    }

    private func focusKittyWindow(_ session: AgentSession, label: String) -> Bool {
        guard session.terminalKind == "kitty", let windowID = session.terminalSession,
              let endpoint = session.terminalEndpoint,
              let executable = executableURL([
                "/Applications/kitty.app/Contents/MacOS/kitten",
                "/opt/homebrew/bin/kitten", "/usr/local/bin/kitten"
              ]), run(executable, arguments: [
                "@", "--to", endpoint, "focus-window", "--match", "id:\(windowID)"
              ]) else { return false }
        activate(bundleID: DefaultProfiles.kittyBundleID, label: label)
        log("focused Kitty window for \(label)")
        return true
    }

    private func executableURL(_ paths: [String]) -> URL? {
        paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }

    private func run(_ executable: URL, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func terminalBundleID(for profileID: String) -> String? {
        switch profileID {
        case "iterm2": DefaultProfiles.iTerm2BundleID
        case "cursor": DefaultProfiles.cursorBundleID
        case "vscode": DefaultProfiles.vsCodeBundleID
        case "warp": DefaultProfiles.warpBundleIDs.first(where: {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }) ?? DefaultProfiles.warpBundleIDs.first
        case "kitty": DefaultProfiles.kittyBundleID
        case "wezterm": DefaultProfiles.wezTermBundleID
        case "ghostty": DefaultProfiles.ghosttyBundleID
        case "mosaic": DefaultProfiles.mosaicBundleID
        default: nil
        }
    }

    struct GhosttyTerminal: Equatable {
        let id: String
        let path: String
        let title: String
    }

    private func focusGhosttyTerminal(workingDirectory path: String,
                                      matchingTitles titles: [String],
                                      label: String) -> Bool {
        var terminals = ghosttyTerminals(label: label)
        var match = Self.bestGhosttyMatch(
            terminals: terminals, workingDirectory: path, titles: titles)

        if match == nil, !terminals.isEmpty {
            // No tab admits to being in this project. Usually one of them is —
            // it just never got to report the directory, because the agent was
            // launched in the same command line as the `cd` that entered it.
            // Ask the running processes where they actually are, tell their
            // terminals, and look again.
            let corrections = TerminalDirectoryReporter.announceDirectories(under: path)
            guard !corrections.isEmpty else {
                // Falling through to a plain app activation lands on whatever
                // tab was already frontmost, which reads as a dead key. Name
                // the directory nothing claimed so the log says why.
                log("no Ghostty tab is in \(path) for \(label)")
                return false
            }
            terminals = ghosttyTerminals(label: label)
            match = Self.bestGhosttyMatch(
                terminals: terminals, workingDirectory: path, titles: titles)
            if match != nil {
                log("corrected \(corrections.count == 1 ? "a stale directory" : "\(corrections.count) stale directories") to find \(label)")
            }
        }
        guard let match else {
            log("no Ghostty tab is in \(path) for \(label)")
            return false
        }
        guard runAppleScript("""
        tell application id "com.mitchellh.ghostty"
            focus (first terminal whose id is \(Self.appleScriptString(match.id)))
        end tell
        """, label: label) != nil else { return false }
        // Name the surface we actually landed on: several tabs can share a
        // working directory, so a silent "focused" hides a wrong-tab jump.
        log("focused Ghostty terminal for \(label) — \(match.title) [\(match.path)]")
        return true
    }

    /// Ghostty lists surfaces in a fixed order, so a first-match-wins search
    /// hands the key to whichever tab happens to come first — including a tab
    /// parked in a parent folder, which "matches" every project beneath it.
    /// Rank instead: the tab whose directory *is* the agent's beats one that
    /// merely contains it, and a title naming the agent breaks ties between
    /// tabs sharing a directory (the agent's tab over the dev server's).
    static func bestGhosttyMatch(terminals: [GhosttyTerminal],
                                 workingDirectory: String,
                                 titles: [String]) -> GhosttyTerminal? {
        let target = normalizedPath(workingDirectory)
        guard !target.isEmpty else { return nil }
        let needles = titles.map { $0.lowercased() }.filter { !$0.isEmpty }

        var best: (rank: (Int, Int, Int), terminal: GhosttyTerminal)?
        for terminal in terminals {
            let candidate = normalizedPath(terminal.path)
            let tier = if candidate == target { 3 }                     // the agent's own directory
                else if candidate.hasPrefix(target + "/") { 2 }         // inside the agent's project
                else if target.hasPrefix(candidate + "/") { 1 }         // a parent folder: last resort
                else { 0 }                                             // title match only
            let named = needles.contains { terminal.title.lowercased().contains($0) } ? 1 : 0
            guard tier > 0 || named == 1 else { continue }
            // Closest relative first, so /code/airtest wins over /code.
            let closeness = -abs(candidate.split(separator: "/").count
                                 - target.split(separator: "/").count)
            let rank = (tier, named, closeness)
            if best == nil || rank > best!.rank { best = (rank, terminal) }
        }
        return best?.terminal
    }

    /// macOS paths are case-insensitive and hooks report whatever casing the
    /// user typed (`~/Code` vs `~/code`), so compare folded and unslashed.
    private static func normalizedPath(_ path: String) -> String {
        var value = path.lowercased()
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private func ghosttyTerminals(label: String) -> [GhosttyTerminal] {
        // U+0001 separates fields so titles and paths need no escaping on the
        // way back out of AppleScript.
        guard let output = runAppleScript("""
        tell application id "com.mitchellh.ghostty"
            set fieldSeparator to character id 1
            set listing to ""
            repeat with candidate in terminals
                set listing to listing & (id of candidate) & fieldSeparator & ¬
                    (working directory of candidate) & fieldSeparator & ¬
                    (name of candidate) & linefeed
            end repeat
            return listing
        end tell
        """, label: label) else { return [] }

        return output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\u{1}")
            guard fields.count >= 3, !fields[0].isEmpty else { return nil }
            return GhosttyTerminal(id: fields[0], path: fields[1], title: fields[2])
        }
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func runAppleScript(_ source: String, label: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            if error[NSAppleScript.errorNumber] as? Int == -1743 {
                log("Ghostty automation permission is required to focus \(label)")
            } else {
                log("Ghostty focus failed for \(label): \(error[NSAppleScript.errorMessage] ?? "unknown error")")
            }
            return nil
        }
        return result.stringValue ?? ""
    }

    private func fallbackBundleID(for source: String) -> String? {
        switch source.lowercased() {
        case "cursor": return DefaultProfiles.cursorBundleID
        case "conductor": return DefaultProfiles.conductorBundleID
        // CLI agents normally report from the user's terminal. Window-title
        // matching above selects the exact project tab when shell integration
        // includes the cwd; this fallback at least brings Ghostty forward.
        case "claude", "claude-code", "codex", "opencode", "antigravity",
             "antigravity-cli", "agy", "github-copilot", "copilot-cli",
             "kiro", "kiro-cli", "cline", "cline-cli", "goose", "qwen",
             "qwen-code": return DefaultProfiles.ghosttyBundleID
        default: return nil
        }
    }

    private func activate(bundleID: String, label: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [.activateAllWindows])
            log("opened \(label)")
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
                Task { @MainActor in
                    if let error { self?.log("could not open \(label): \(error.localizedDescription)") }
                    else { self?.log("opened \(label)") }
                }
            }
        } else {
            log("app not found for \(label)")
        }
    }

    private func post(_ chord: KeyChord) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: false)
        else { return }
        down.flags = chord.modifiers.cgFlags
        up.flags = chord.modifiers.cgFlags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        var units = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func raiseWindow(matching terms: [String]) -> Bool {
        let needles = terms.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !needles.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        for window in windows {
            guard let title = window[kCGWindowName as String] as? String,
                  needles.contains(where: { title.lowercased().contains($0) }),
                  let pidNumber = window[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pid_t(pidNumber.intValue)
            guard pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let appElement = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
                  let axWindows = value as? [AXUIElement] else { continue }
            for axWindow in axWindows {
                var titleValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue) == .success,
                      let axTitle = titleValue as? String,
                      needles.contains(where: { axTitle.lowercased().contains($0) }) else { continue }
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
                return true
            }
        }
        return false
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty != false }
}
