import SwiftUI

/// First-class setup for letting terminal assistants write to the display.
/// Lifecycle hooks stay under Integrations; MCP control is a separate concept
/// and gets its own sidebar destination so users do not have to discover it
/// inside an unrelated provider list.
struct AIControlPane: View {
    @Environment(AppModel.self) private var model
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI Control").font(.title2.bold())
                    Text("Connect Claude Code or Codex so you can ask it to put messages on your clock.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    clientRow(.claude)
                    Divider().padding(.leading, 44)
                    clientRow(.codex)
                }
                .padding(.horizontal, 14)
                .background(Color.controlSurface, in: RoundedRectangle(cornerRadius: 10))

                if let message {
                    Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(isError ? Color.red : Color.green)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("How it works").font(.headline)
                    Text("The connection installs AgentClock’s bundled MCP helper into the selected command-line tool. The helper talks only to this app on your Mac; this app keeps the clock address and password private and sends the message to the display.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("After connecting, start a new assistant session and say:")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Make the clock say TESTING")
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.controlSurface, in: RoundedRectangle(cornerRadius: 8))
                }

                Label("AgentClock must be running when the assistant sends a message.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    private func clientRow(_ client: MCPClient) -> some View {
        HStack(spacing: 12) {
            SourceIcon(source: client == .claude ? "claude-code" : "codex", size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.displayName).font(.callout.weight(.medium))
                Text(MCPInstaller.isDetected(client)
                     ? "Command-line tool detected"
                     : "Command-line tool not found")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Connect") { connect(client) }
                .disabled(!MCPInstaller.isDetected(client))
        }
        .padding(.vertical, 12)
    }

    private func connect(_ client: MCPClient) {
        message = nil
        do {
            try MCPInstaller.install(client, port: model.config.webhookPort)
            isError = false
            message = "Connected to \(client.displayName). Start a new session to use it."
            model.log("installed MCP control for \(client.displayName)")
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
}

