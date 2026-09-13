import SwiftUI

/// Install/remove the hooks that make agents report to AgentClock.
///
/// Every installer writes whole-file JSON (unknown keys preserved), takes a
/// timestamped backup first, and marks its own entries with `#agentclock` so
/// uninstall removes exactly those and nothing else. That marker is why
/// AgentClock and MegaMicro can both hook the same `~/.claude/settings.json`
/// without either one clobbering the other.
struct IntegrationsPane: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Integrations").font(.title2.bold())
                Text("AgentClock listens on 127.0.0.1:\(String(model.config.webhookPort)). Installing a hook tells that agent to report its lifecycle there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let webhookError = model.webhookError {
                    Label(webhookError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                ForEach(model.integrations) { integration in
                    row(integration)
                    Divider()
                }

                if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }

                manualSection
            }
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    private func row(_ integration: IntegrationStatus) -> some View {
        HStack(spacing: 12) {
            SourceIcon(source: integration.source, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(integration.name).font(.callout.weight(.medium))
                Text(integration.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(integration.installed ? "Remove" : "Install") {
                error = nil
                do {
                    try model.setIntegration(integration.id, installed: !integration.installed)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// The escape hatch. Anything that can POST JSON can drive the clock, which
    /// matters for agents AgentClock ships no installer for.
    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Anything else").font(.headline)
            Text("Any tool that can make an HTTP request can report state:")
                .font(.callout).foregroundStyle(.secondary)
            Text("""
            curl -s -XPOST http://127.0.0.1:\(String(model.config.webhookPort))/state \\
              -d '{"source":"my-agent","state":"waiting","session":"1","cwd":"'"$PWD"'"}'
            """)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.controlSurface, in: RoundedRectangle(cornerRadius: 6))
            Text("Valid states: idle, thinking, coding, waiting, success, error.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}
