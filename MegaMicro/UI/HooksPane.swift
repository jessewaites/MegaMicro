import SwiftUI

/// Install/uninstall agent lifecycle hooks (Claude Code and Codex CLI) that
/// report agent state to MegaMicro, with a copyable manual test command.
struct HooksPane: View {
    @Environment(AppState.self) private var appState

    private var testCommand: String {
        "curl -X POST http://127.0.0.1:\(appState.config.webhookPort)/state -d '{\"source\":\"claude-code\",\"state\":\"success\",\"session\":\"manual-test\"}'"
    }

    /// Universal adapter: wraps ANY command — key lights while it runs,
    /// green on success, red strobe on failure.
    private var shellWrapper: String {
        let port = appState.config.webhookPort
        return """
        # MegaMicro: wrap any command with agent-state reporting.
        # Usage:  mm opencode …   ·   mm pnpm test   ·   mm cargo build
        mm() {
          local _session="mm-$PPID-$(uuidgen)"
          local _source="$(basename "$1")"
          local _report='{"source":"'"$_source"'","state":"%@","session":"'"$_session"'","cwd":"'"$PWD"'"}'
          curl -m 2 -s -X POST http://127.0.0.1:\(port)/state -d "${_report//%@/coding}" >/dev/null 2>&1
          "$@"
          local _code=$?
          local _state=success; [ $_code -ne 0 ] && _state=error
          curl -m 2 -s -X POST http://127.0.0.1:\(port)/state -d "${_report//%@/$_state}" >/dev/null 2>&1
          return $_code
        }
        """
    }

    var body: some View {
        Form {
            Section {
                Text("Integrations connect your coding tools to MegaMicro so their agents appear automatically and report when they are working, waiting, finished, or in error. Install only the tools you use; existing provider settings are preserved.")
                    .font(.callout)
            }
            Section {
                LabeledContent("Status") {
                    if appState.hooksStale {
                        Label("Installed — needs reinstalling", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Label(
                            appState.hooksInstalled ? "Installed" : "Not installed",
                            systemImage: appState.hooksInstalled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(appState.hooksInstalled ? .green : .secondary)
                    }
                }
                if appState.hooksStale {
                    Text("These hooks were written by an earlier version of MegaMicro. They still report agent states, but not which terminal each agent is running in, so pressing an agent key raises the app instead of its own tab. Reinstall to fix it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Webhook") {
                    if appState.webhookError == nil {
                        Text("127.0.0.1:\(String(appState.config.webhookPort))")
                            .monospaced()
                    } else {
                        Text(appState.webhookError ?? "")
                            .foregroundStyle(.red)
                    }
                }
                HStack {
                    Button(appState.hooksInstalled ? "Reinstall Hooks" : "Install Hooks") {
                        appState.installHooks()
                    }
                    Button("Uninstall", role: .destructive) {
                        appState.uninstallHooks()
                    }
                    .disabled(!appState.hooksInstalled)
                }
                LabeledContent("Conductor") {
                    Label("Workspace routing", systemImage: "folder.badge.gearshape")
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack(spacing: 6) {
                    BrandIcon(asset: "claude", size: 14)
                    Text("Claude Code Hooks")
                }
            } footer: {
                Text("""
                Adds state-reporting hooks to ~/.claude/settings.json so any Claude Code \
                session lights up the keyboard. In Conductor, telemetry comes from whichever \
                underlying Claude, Codex, Cursor, or OpenCode adapter is installed; Conductor \
                supplies workspace routing and focusing. Your existing settings are \
                preserved and backed up first; every entry is tagged \(HooksInstaller.marker) \
                so Uninstall removes only MegaMicro's hooks.
                """)
                .font(.caption)
            }

            Section {
                if !appState.codexDetected {
                    Text("Codex CLI not detected (~/.codex missing). Install Codex and revisit this pane.")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Status") {
                        Label(
                            appState.codexHooksInstalled ? "Installed" : "Not installed",
                            systemImage: appState.codexHooksInstalled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(appState.codexHooksInstalled ? .green : .secondary)
                    }
                    LabeledContent("Feature flag") {
                        Label(
                            appState.codexFeatureEnabled ? "codex_hooks enabled" : "codex_hooks disabled",
                            systemImage: appState.codexFeatureEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(appState.codexFeatureEnabled ? .green : .orange)
                    }
                    HStack {
                        Button(appState.codexHooksInstalled ? "Reinstall Hooks" : "Install Hooks") {
                            appState.installCodexHooks()
                        }
                        Button("Uninstall", role: .destructive) {
                            appState.uninstallCodexHooks()
                        }
                        .disabled(!appState.codexHooksInstalled)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    BrandIcon(asset: "codex", size: 14)
                    Text("Codex CLI Hooks")
                }
            } footer: {
                Text("""
                Writes state-reporting hooks to ~/.codex/hooks.json and enables the hooks feature \
                in ~/.codex/config.toml. The bundled bridge reads real session IDs and event \
                metadata, allowing simultaneous Codex agents in one project to remain distinct.
                """)
                .font(.caption)
            }

            Section("What gets reported") {
                LabeledContent("Prompt submitted", value: "thinking · breathing blue")
                LabeledContent("Tool running", value: "coding · breathing cyan")
                LabeledContent("Agent finished", value: "success · green, fades in 45 s")
                LabeledContent("Needs your input", value: "waiting · yellow blink")
            }

            Section {
                if !appState.antigravityDetected {
                    Text("Antigravity CLI not detected (~/.gemini/antigravity-cli missing).")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Status") {
                        Label(appState.antigravityHooksInstalled ? "Installed" : "Not installed",
                              systemImage: appState.antigravityHooksInstalled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(appState.antigravityHooksInstalled ? .green : .secondary)
                    }
                    HStack {
                        Button(appState.antigravityHooksInstalled ? "Reinstall Hooks" : "Install Hooks") {
                            appState.installAntigravityHooks()
                        }
                        Button("Uninstall", role: .destructive) { appState.uninstallAntigravityHooks() }
                            .disabled(!appState.antigravityHooksInstalled)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    BrandIcon(asset: "antigravity-color", size: 14)
                    Text("Antigravity CLI Hooks")
                }
            } footer: {
                Text("Uses Antigravity conversation IDs and workspace paths. The bridge returns each event's required neutral response and reports ask_question before it waits. Existing hooks are preserved and backed up.")
                    .font(.caption)
            }

            integrationSection(
                title: "OpenCode", asset: "opencode",
                installed: appState.openCodeHooksInstalled, detected: appState.openCodeDetected,
                detail: "Installs a user-level TypeScript plugin that observes session, permission, tool, idle, and error events.",
                install: appState.installOpenCodeHooks, uninstall: appState.uninstallOpenCodeHooks)

            integrationSection(
                title: "Cursor", asset: "cursor",
                installed: appState.cursorHooksInstalled, detected: appState.cursorDetected,
                detail: "Safely merges user-level Cursor IDE and CLI lifecycle hooks for sessions, prompts, tools, file edits, shell work, and completion.",
                install: appState.installCursorHooks, uninstall: appState.uninstallCursorHooks)

            integrationSection(
                title: "GitHub Copilot CLI", asset: "github-copilot",
                installed: appState.copilotHooksInstalled, detected: appState.copilotDetected,
                detail: "Installs an owned hook file in ~/.copilot/hooks with session, prompt, permission, tool, failure, and subagent events.",
                install: appState.installCopilotHooks, uninstall: appState.uninstallCopilotHooks)

            integrationSection(
                title: "Qwen Code", asset: "qwen",
                installed: appState.qwenHooksInstalled, detected: appState.qwenDetected,
                detail: "Safely merges native Qwen lifecycle hooks into ~/.qwen/settings.json and preserves unrelated settings.",
                install: appState.installQwenHooks, uninstall: appState.uninstallQwenHooks)

            Section {
                Text("Anything that can run curl can light a key — MegaMicro's webhook is the universal hook. Two ways in:")
                    .font(.callout)

                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Shell wrapper — add to ~/.zshrc, then prefix any command:")
                        .font(.callout.bold())
                    HStack(alignment: .top) {
                        Text(shellWrapper)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(shellWrapper, forType: .string)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("2. Direct API — POST from hooks of any future tool:")
                        .font(.callout.bold())
                    Text("""
                    POST http://127.0.0.1:\(String(appState.config.webhookPort))/state
                    {"source": "opencode", "state": "thinking|coding|waiting|success|error|idle",
                     "session": "<stable unique id>", "cwd": "<working dir>",
                     "agent": "<optional role/name>", "parentSession": "<optional parent id>",
                     "model": "<optional model id>", "terminalKind": "<optional terminal>",
                     "terminalSession": "<optional pane id>"}
                    """)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                }
            } header: {
                Text("Any Other CLI (OpenCode, tests, builds, …)")
            } footer: {
                Text("`cwd` decides which key lights: a key bound to that folder in the Agents pane, or the next free auto key.")
                    .font(.caption)
            }

            Section {
                DisclosureGroup("Event → State Mappings") {
                    eventMappingEditor(
                        title: "Claude Code",
                        events: eventsBinding(\.claudeHookEvents),
                        defaults: AppConfig.defaultClaudeHookEvents)
                    Divider()
                    eventMappingEditor(
                        title: "Codex CLI",
                        events: eventsBinding(\.codexHookEvents),
                        defaults: AppConfig.defaultCodexHookEvents)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Future-proofing: if a Claude Code or Codex update renames or adds hook events, fix the mapping here and click Reinstall Hooks — no app update needed. Unknown events simply never fire (harmless).")
                    .font(.caption)
            }

            Section("Try it") {
                Text("Run `claude -p \"say hi\"` in any terminal and watch the on-screen keyboard, or fire a fake event:")
                    .font(.callout)
                HStack {
                    Text(testCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(testCommand, forType: .string)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { appState.refreshHooksStatus() }
    }

    // MARK: Event mapping editor

    @State private var newEventName = ""

    @ViewBuilder
    private func integrationSection(title: String, asset: String, installed: Bool, detected: Bool,
                                    detail: String, install: @escaping () -> Void,
                                    uninstall: @escaping () -> Void) -> some View {
        Section {
            LabeledContent("Status") {
                Label(installed ? "Installed" : (detected ? "Available" : "Not detected"),
                      systemImage: installed ? "checkmark.circle.fill" : (detected ? "arrow.down.circle" : "circle"))
                    .foregroundStyle(installed ? .green : .secondary)
            }
            HStack {
                Button(installed ? "Reinstall Integration" : "Install Integration", action: install)
                Button("Uninstall", role: .destructive, action: uninstall).disabled(!installed)
            }
        } header: {
            HStack(spacing: 6) { BrandIcon(asset: asset, size: 14); Text(title) }
        } footer: {
            Text(detail).font(.caption)
        }
    }

    private func eventsBinding(_ keyPath: WritableKeyPath<AppConfig, [String: String]>) -> Binding<[String: String]> {
        @Bindable var state = appState
        return Binding(
            get: { state.config[keyPath: keyPath] },
            set: { state.config[keyPath: keyPath] = $0 })
    }

    @ViewBuilder
    private func eventMappingEditor(title: String, events: Binding<[String: String]>, defaults: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Reset") { events.wrappedValue = defaults }
                    .font(.caption)
            }
            ForEach(events.wrappedValue.keys.sorted(), id: \.self) { event in
                HStack {
                    Text(event).font(.system(.callout, design: .monospaced))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { events.wrappedValue[event] ?? "idle" },
                        set: { events.wrappedValue[event] = $0 })) {
                        ForEach(AgentState.allCases, id: \.self) { state in
                            Text(state.wireName).tag(state.wireName)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Button {
                        events.wrappedValue.removeValue(forKey: event)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("New event name, e.g. SubagentStop", text: $newEventName)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let trimmed = newEventName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    events.wrappedValue[trimmed] = "success"
                    newEventName = ""
                }
            }
            Text("Changes apply on the next Install/Reinstall.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
