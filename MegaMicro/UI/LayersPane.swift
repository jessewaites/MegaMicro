import AppKit
import SwiftUI

struct LayersPane: View {
    @Environment(AppState.self) private var appState
    @State private var inspection: WorkLouderLayerManager.Inspection?
    @State private var selectedTargetID: Int?
    @State private var status = "Open Work Louder Input, let it retrieve the keyboard configuration, then fully quit it."
    @State private var isError = false
    @State private var working = false
    @State private var lastClone: WorkLouderLayerManager.CloneResult?
    @State private var inputRunning = WorkLouderLayerManager.isInputRunning

    private let manager = WorkLouderLayerManager()
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Hardware layers") {
                Text("Layers change what the Codex Micro firmware emits. MegaMicro Profiles separately decide what this Mac does with those events.")
                    .foregroundStyle(.secondary)
                Label("This tool changes only the selected editable layer’s layout in Work Louder Input’s local configuration. It never writes protected Layer 1 or talks directly to keyboard firmware.", systemImage: "shield.checkered")
                    .font(.callout)
            }

            Section("1. Prepare") {
                if appState.hardwareConnected {
                    Label("MegaMicro is holding the keyboard connection.", systemImage: "cable.connector")
                    Button("Release for Layer Editing") {
                        appState.releaseHardwareForEditing()
                    }
                } else if appState.hardwareReleased {
                    Label("Keyboard released for editing", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("MegaMicro is not connected to the keyboard", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }

                Label(
                    inputRunning
                        ? "Work Louder Input is running — fully quit it before continuing"
                        : "Work Louder Input is not running",
                    systemImage: inputRunning
                        ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(inputRunning ? .orange : .green)

                Button("Inspect Input Configuration") { inspect() }
                    .disabled(working || inputRunning)
            }

            if let inspection {
                Section("2. Confirm the live configuration") {
                    LabeledContent("Device", value: "\(inspection.deviceName) · \(inspection.deviceID)")
                    LabeledContent("Active profile", value: "\(inspection.profileName) · \(inspection.profileID)")
                    layerRow(inspection.source, role: "Protected source")

                    Picker("Editable target", selection: Binding(
                        get: { selectedTargetID ?? inspection.targets.first?.id },
                        set: { selectedTargetID = $0 }
                    )) {
                        ForEach(inspection.targets) { layer in
                            Text("\(layer.name) (Layer \(layer.id + 1), id \(layer.id))")
                                .tag(Optional(layer.id))
                        }
                    }
                    Text("MegaMicro discovered these objects from the live file. It does not use a hardcoded keymap.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("3. Create backups and prepare the target") {
                    Button("Clone Codex Layout into Selected Layer") { clone() }
                        .disabled(working || selectedTargetID == nil
                                  || appState.hardwareConnected
                                  || inputRunning)
                    Text("Before replacement, MegaMicro saves the complete Input database and the target layer’s original layout. It validates that the source is unchanged and no value outside the target layout changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let result = lastClone {
                Section("4. Synchronize with Work Louder Input") {
                    Text("Prepared \(result.target.name). Now open Input, select that layer, temporarily append “ sync” to its name, and wait for “layout updated.” Restore the original name and wait for “layout updated” again. Fully quit Input, reopen it once for device read-back, then fully quit it again.")
                    LabeledContent("Full backup", value: result.fullBackupURL.lastPathComponent)
                    LabeledContent("Layout backup", value: result.layoutBackupURL.lastPathComponent)
                    Button("Reveal Backups in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.fullBackupURL])
                    }
                    Button("Verify Read-Back") { verify() }
                        .disabled(working || inputRunning)
                    Button("Restore Original Layer Layout", role: .destructive) { restore() }
                        .disabled(working || inputRunning || appState.hardwareConnected)
                    if appState.hardwareReleased {
                        Button("Reconnect MegaMicro") { appState.connectHardware() }
                    }
                }
            }

            Section("Status") {
                Label(status, systemImage: isError ? "xmark.octagon.fill" : "info.circle")
                    .foregroundStyle(isError ? .red : .secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            inputRunning = WorkLouderLayerManager.isInputRunning
            if !inputRunning { inspect() }
        }
        .onReceive(refreshTimer) { _ in
            inputRunning = WorkLouderLayerManager.isInputRunning
        }
    }

    @ViewBuilder
    private func layerRow(_ layer: WorkLouderLayerManager.Layer, role: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(layer.name)
                Text("Layer \(layer.id + 1) · id \(layer.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(role)
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.quaternary))
        }
    }

    private func inspect() {
        working = true
        defer { working = false }
        do {
            let found = try manager.inspect()
            inspection = found
            selectedTargetID = found.targets.first(where: { $0.id == 1 })?.id ?? found.targets.first?.id
            status = "Found one Codex source layer and \(found.targets.count) editable target layer\(found.targets.count == 1 ? "" : "s"). Review the IDs before cloning."
            isError = false
        } catch {
            inspection = nil
            status = error.localizedDescription
            isError = true
        }
    }

    private func clone() {
        guard let targetID = selectedTargetID else { return }
        working = true
        defer { working = false }
        do {
            let result = try manager.cloneCodexLayout(to: targetID)
            lastClone = result
            status = "Prepared \(result.target.name) safely. Both backups parse as JSON and the one-value mutation passed validation."
            isError = false
            appState.log("prepared Work Louder \(result.target.name) from protected Codex layer")
        } catch {
            status = error.localizedDescription
            isError = true
        }
    }

    private func verify() {
        guard let targetID = lastClone?.target.id else { return }
        working = true
        defer { working = false }
        do {
            inspection = try manager.verifyClone(targetLayerID: targetID)
            status = "Read-back verified: the target layout still matches the live protected Codex layout."
            isError = false
        } catch {
            status = error.localizedDescription
            isError = true
        }
    }

    private func restore() {
        guard let clone = lastClone else { return }
        working = true
        defer { working = false }
        do {
            let result = try manager.restoreLayout(
                to: clone.target.id, from: clone.layoutBackupURL)
            status = "Original target layout restored locally. A fresh pre-rollback database backup was saved as \(result.safetyBackupURL.lastPathComponent). Repeat the Input name-sync and read-back steps to write the rollback to the keyboard."
            isError = false
            appState.log("restored Work Louder \(clone.target.name) layout from backup")
        } catch {
            status = error.localizedDescription
            isError = true
        }
    }
}
