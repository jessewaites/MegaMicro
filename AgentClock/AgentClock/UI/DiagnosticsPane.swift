import SwiftUI

/// Everything needed to answer "why isn't my clock showing anything?" without
/// leaving the app: is the webhook up, is the clock reachable, what has come in.
struct DiagnosticsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Diagnostics").font(.title2.bold())

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Webhook", model.webhookError ?? "Listening on 127.0.0.1:\(String(model.config.webhookPort))")
                    row("Clock", model.clockStatusText)
                    row("Agents", "\(model.liveSessions.count) live, \(model.sessionStore.sessions.count) known")
                    row("Conductor", model.workspaces.isEmpty
                        ? "No workspaces found" : "\(model.workspaces.count) workspaces")
                }
                .font(.callout)

                if !model.activityFeed.isEmpty {
                    Text("Recent activity").font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.activityFeed.prefix(20)) { item in
                            HStack(spacing: 6) {
                                Text(item.at.formatted(date: .omitted, time: .standard))
                                    .foregroundStyle(.secondary)
                                Text("\(item.agentName) \(item.message)")
                                if let project = item.project {
                                    Text("· \(project)").foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        }
                    }
                }

                Text("Log").font(.headline)
                Text(model.logLines.suffix(40).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.controlSurface, in: RoundedRectangle(cornerRadius: 6))
            }
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
