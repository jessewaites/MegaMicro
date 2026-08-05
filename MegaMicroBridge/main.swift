import Foundation

/// Provider-neutral hook bridge. It reads one provider hook payload from
/// stdin, forwards only structural metadata to MegaMicro's loopback webhook,
/// and prints the provider's neutral/fail-open response to stdout.
struct BridgeArguments {
    var provider = "generic"
    var event = ""
    var port = 48_802
    var dryRunReport = false

    init(_ values: [String]) {
        var index = 1
        while index < values.count {
            let value = values[index]
            if value == "--provider", index + 1 < values.count { provider = values[index + 1]; index += 2 }
            else if value == "--event", index + 1 < values.count { event = values[index + 1]; index += 2 }
            else if value == "--port", index + 1 < values.count { port = Int(values[index + 1]) ?? port; index += 2 }
            else if value == "--dry-run-report" { dryRunReport = true; index += 1 }
            else { index += 1 }
        }
    }
}

struct NormalizedReport: Codable {
    let source: String
    let state: String
    let session: String
    let cwd: String?
    let agent: String?
    let parentSession: String?
    let model: String?
    let task: String?
    let terminalSession: String?
    let terminalKind: String?
    let terminalEndpoint: String?
}

func string(_ root: [String: Any], _ keys: String...) -> String? {
    for key in keys {
        if let value = root[key] as? String, !value.isEmpty { return value }
    }
    return nil
}

func nestedString(_ root: [String: Any], object: String, key: String) -> String? {
    (root[object] as? [String: Any])?[key] as? String
}

func normalize(_ root: [String: Any], args: BridgeArguments) -> NormalizedReport {
    let provider = args.provider.lowercased()
    let event = args.event.isEmpty ? (string(root, "hook_event_name", "event", "type") ?? "") : args.event
    let tool = string(root, "tool_name", "toolName")
        ?? nestedString(root, object: "toolCall", key: "name")
    let lowerEvent = event.lowercased()
    let lowerTool = tool?.lowercased() ?? ""
    let error = string(root, "error", "error_message", "errorMessage")
    let termination = string(root, "terminationReason", "reason")?.lowercased()
    let notification = string(root, "notification_type", "notificationType")?.lowercased()
    let state: String
    if lowerEvent.contains("failure") || lowerEvent.contains("error") || error?.isEmpty == false
        || termination == "error" || termination == "max_steps_exceeded" {
        state = "error"
    } else if lowerEvent.contains("permission") || lowerEvent.contains("elicitation")
                || (lowerEvent == "notification" && ["permission_prompt", "idle_prompt", "elicitation_dialog"].contains(notification))
                || lowerTool == "ask_question" || lowerTool == "askuserquestion" || lowerTool == "ask_user" {
        state = "waiting"
    } else if lowerEvent.contains("userprompt") || lowerEvent.contains("preinvocation")
                || lowerEvent.contains("subagentstart") || lowerEvent == "session.created" {
        state = "thinking"
    } else if lowerEvent.contains("pretool") || lowerEvent.contains("beforetool")
                || lowerEvent.contains("beforeshell") || lowerEvent.contains("afterfileedit")
                || lowerEvent == "tool.execute.before" {
        state = "coding"
    } else if lowerEvent == "session.idle" || lowerEvent.contains("sessionend")
                || lowerEvent.contains("teammateidle") {
        state = "idle"
    } else if lowerEvent == "stop" || lowerEvent.contains("taskcompleted")
                || lowerEvent.contains("subagentstop") {
        let fullyIdle = root["fullyIdle"] as? Bool
        state = fullyIdle == false ? "coding" : "success"
    } else if lowerEvent.contains("posttool") || lowerEvent == "tool.execute.after" {
        state = "thinking"
    } else if lowerEvent.contains("sessionstart") { state = "idle" }
    else { state = "thinking" }

    let parent = string(root, "parent_session_id", "parentSessionId", "parentSession")
    let mainSession = string(root, "session_id", "sessionId", "conversationId", "conversation_id")
        ?? ProcessInfo.processInfo.environment["CLAUDE_SESSION_ID"]
        ?? "\(provider)-\(ProcessInfo.processInfo.processIdentifier)"
    let agentID = string(root, "agent_id", "agentId", "subagent_id", "subagentId")
    let session = agentID ?? mainSession
    let derivedParent = agentID == nil ? parent : (parent ?? mainSession)
    let workspacePaths = (root["workspacePaths"] as? [String])
        ?? (root["workspace_roots"] as? [String])
    let cwd = string(root, "cwd", "working_dir", "working_directory", "directory")
        ?? workspacePaths?.first
        ?? ProcessInfo.processInfo.environment["PWD"]
    let agent = string(root, "agent_type", "agentType", "agent_name", "agentName")
    let model = string(root, "model", "model_id", "modelId")
    // Do not forward raw prompts, command arguments, tool results, or diffs.
    let task = string(root, "task_name", "taskName", "task_title", "taskTitle")

    let source: String = switch provider {
    case "claude": "claude-code"
    case "antigravity", "agy": "antigravity-cli"
    case "copilot": "github-copilot"
    case "qwen": "qwen-code"
    default: provider
    }
    let environment = ProcessInfo.processInfo.environment
    let terminal: (kind: String?, session: String?, endpoint: String?) = if let id = environment["ITERM_SESSION_ID"] {
        ("iterm2", id, nil)
    } else if let id = environment["WEZTERM_PANE"] {
        ("wezterm", id, environment["WEZTERM_UNIX_SOCKET"])
    } else if let id = environment["KITTY_WINDOW_ID"] {
        ("kitty", id, environment["KITTY_LISTEN_ON"])
    } else if environment["TERM_PROGRAM"] == "vscode" {
        ("vscode", nil, nil)
    } else if environment["TERM_PROGRAM"]?.lowercased().contains("warp") == true
                || environment["WARP_IS_LOCAL_SHELL"] != nil {
        ("warp", nil, nil)
    } else {
        (nil, nil, nil)
    }
    return NormalizedReport(
        source: source, state: state, session: session, cwd: cwd,
        agent: agent, parentSession: derivedParent, model: model, task: task,
        terminalSession: terminal.session, terminalKind: terminal.kind,
        terminalEndpoint: terminal.endpoint)
}

/// Ghostty learns a tab's directory from OSC 7, which the shell emits at each
/// prompt — so a tab whose agent was started in the same breath as its `cd`
/// (`cd project && claude`) keeps reporting the directory the shell sat in
/// before. MegaMicro finds Ghostty tabs by directory, so that stale value
/// sends the project's key to the wrong tab, or nowhere.
///
/// The hook runs inside the tab it is reporting about, so it can correct the
/// record: writing OSC 7 to the controlling terminal is exactly what a shell
/// prompt does. Ghostty rejects a URI with no authority, so name this host.
func reportWorkingDirectoryToTerminal(_ path: String?) {
    let environment = ProcessInfo.processInfo.environment
    // Scoped to Ghostty: every other terminal MegaMicro supports identifies
    // its tab through an environment variable the report already carries.
    guard environment["TERM_PROGRAM"]?.lowercased() == "ghostty"
            || environment["GHOSTTY_RESOURCES_DIR"] != nil else { return }
    guard let path, path.hasPrefix("/"),
          let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    else { return }
    guard let descriptor = openControllingTerminal() else { return }
    defer { close(descriptor) }
    // Ghostty ignores a directory it reads as remote, and it decides that by
    // matching the authority against the local hostname exactly — the
    // lowercase form `ProcessInfo.hostName` returns is rejected, as is an
    // empty authority. `localhost` is always understood as this machine.
    let sequence = Array("\u{1b}]7;file://localhost\(encoded)\u{7}".utf8)
    _ = sequence.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }
}

/// Agents spawn their hooks detached from the terminal, so `/dev/tty` is
/// usually unopenable here even though the agent itself is sitting in one —
/// and `access` still says yes, so only the open tells the truth. The kernel
/// records every process's controlling terminal, so fall back to walking up to
/// the first ancestor that has one and addressing that device by name.
/// O_NOCTTY throughout: reporting a directory must never claim a terminal.
func openControllingTerminal() -> Int32? {
    let descriptor = open("/dev/tty", O_WRONLY | O_NOCTTY)
    if descriptor >= 0 { return descriptor }
    var pid = getpid()
    // bridge → shell → agent is the deep case; stop well short of launchd.
    for _ in 0..<8 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        if device != -1, let name = devname(device, S_IFCHR) {
            let terminal = open("/dev/" + String(cString: name), O_WRONLY | O_NOCTTY)
            return terminal >= 0 ? terminal : nil
        }
        let parent = info.kp_eproc.e_ppid
        guard parent > 1 else { return nil }
        pid = parent
    }
    return nil
}

func neutralOutput(provider: String, event: String) -> String {
    let provider = provider.lowercased()
    let event = event.lowercased()
    if provider == "antigravity" || provider == "agy" {
        if event == "pretooluse" { return #"{"decision":"allow"}"# }
        if event == "preinvocation" { return #"{"injectSteps":[]}"# }
        if event == "posttooluse" { return "{}" }
        if event == "stop" { return #"{"decision":"stop"}"# }
    }
    // For Claude, Codex, Copilot, and Qwen an empty object observes without
    // approving, denying, blocking, or mutating the provider's behavior.
    return "{}"
}

func post(_ report: NormalizedReport, port: Int) {
    guard let url = URL(string: "http://127.0.0.1:\(port)/state"),
          let body = try? JSONEncoder().encode(report) else { return }
    var request = URLRequest(url: url, timeoutInterval: 0.75)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let semaphore = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { _, _, _ in semaphore.signal() }.resume()
    _ = semaphore.wait(timeout: .now() + 0.8)
}

let args = BridgeArguments(CommandLine.arguments)
let input = FileHandle.standardInput.readDataToEndOfFile()
let root = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any]) ?? [:]
let report = normalize(root, args: args)
if args.dryRunReport {
    FileHandle.standardOutput.write((try? JSONEncoder().encode(report)) ?? Data("{}".utf8))
} else {
    reportWorkingDirectoryToTerminal(report.cwd)
    post(report, port: args.port)
    FileHandle.standardOutput.write(Data((neutralOutput(provider: args.provider, event: args.event) + "\n").utf8))
}
