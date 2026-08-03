import SwiftUI
import AppKit

struct ProfileListView: View {
    @Environment(AppState.self) private var appState
    @State private var editingProfileID: String?

    private var builtinIDs: Set<String> { Set(DefaultProfiles.all.map(\.id)) }

    var body: some View {
        @Bindable var state = appState
        // A List nested in a VStack inside the split-view detail column gives
        // SwiftUI an unresolvable layout: the whole window renders blank until
        // something forces a re-layout (resizing the window brings it back).
        // Every other pane uses Form, so this one does too.
        Form {
            Section {
                Text("A profile is a complete set of key assignments, shortcuts, and agent-light colors. Choose one manually, or have MegaMicro switch profiles automatically when a particular app is in front.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ForEach(appState.config.profiles) { profile in
                    row(profile)
                }
            } header: {
                HStack {
                    Text("Profiles")
                    Spacer()
                    Button {
                        createProfile()
                    } label: {
                        Label("New Profile", systemImage: "plus")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: Binding(
            get: { editingProfileID.flatMap { id in appState.config.profile(id: id) } },
            set: { editingProfileID = $0?.id }
        )) { profile in
            ProfileEditorView(profileID: profile.id, isBuiltin: builtinIDs.contains(profile.id))
        }
    }

    @ViewBuilder
    private func row(_ profile: Profile) -> some View {
        @Bindable var state = appState
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.headline)
                    if builtinIDs.contains(profile.id) {
                        Text("Built-in")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                    if profile.id == appState.config.activeProfileID {
                        Text("Active")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.2)))
                            .foregroundStyle(.green)
                    }
                }
                Text(profile.appBundleIDs.isEmpty
                     ? "Manual activation only"
                     : "Auto-activates: \(profile.appBundleIDs.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit…") { editingProfileID = profile.id }
                .buttonStyle(.link)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            state.config.activeProfileID = profile.id
        }
        .help("Click to activate this profile. Edit it to change its name or automatic app switching.")
        .contextMenu {
            Button("Activate") { state.config.activeProfileID = profile.id }
            Button("Edit…") { editingProfileID = profile.id }
            Button("Duplicate") { duplicate(profile) }
            if !builtinIDs.contains(profile.id) {
                Button("Delete", role: .destructive) { delete(profile.id) }
            } else {
                Button("Reset to Shipped Defaults") { resetBuiltin(profile.id) }
            }
        }
    }

    // MARK: Actions

    private func createProfile() {
        let profile = Profile(
            id: "profile-\(UUID().uuidString.prefix(8).lowercased())",
            name: "New Profile",
            appBundleIDs: [],
            mappings: [:],
            rgbRules: .standard)
        appState.config.profiles.append(profile)
        appState.config.activeProfileID = profile.id
        editingProfileID = profile.id
    }

    private func duplicate(_ profile: Profile) {
        var copy = profile
        copy.id = "profile-\(UUID().uuidString.prefix(8).lowercased())"
        copy.name = "\(profile.name) Copy"
        copy.appBundleIDs = []
        appState.config.profiles.append(copy)
        editingProfileID = copy.id
    }

    private func delete(_ id: String) {
        appState.config.profiles.removeAll { $0.id == id }
        if appState.config.activeProfileID == id {
            appState.config.activeProfileID = appState.config.profiles.first?.id ?? "conductor"
        }
    }

    private func resetBuiltin(_ id: String) {
        guard let shipped = DefaultProfiles.all.first(where: { $0.id == id }),
              let index = appState.config.profiles.firstIndex(where: { $0.id == id }) else { return }
        appState.config.profiles[index] = shipped
        appState.log("profile \(shipped.name) reset to shipped defaults")
    }
}

/// Edit a profile's name, auto-activation apps, and (for custom profiles)
/// deletion. Key mappings are edited on the Keyboard pane while the profile
/// is active.
struct ProfileEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let profileID: String
    let isBuiltin: Bool

    @State private var name = ""
    @State private var bundleIDs: [String] = []
    @State private var manualBundleID = ""

    private var runningApps: [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let appName = app.localizedName else { return nil }
                return (appName, id)
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isBuiltin ? "Edit Built-in Profile" : "Edit Profile")
                .font(.title3.bold())

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            GroupBox("Auto-activate when one of these apps is frontmost") {
                VStack(alignment: .leading, spacing: 6) {
                    if bundleIDs.isEmpty {
                        Text("None — activate this profile manually.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(bundleIDs, id: \.self) { id in
                        HStack {
                            Text(id).font(.system(.callout, design: .monospaced))
                            Spacer()
                            Button {
                                bundleIDs.removeAll { $0 == id }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Menu("Add Running App") {
                            ForEach(runningApps, id: \.bundleID) { app in
                                Button("\(app.name) — \(app.bundleID)") {
                                    if !bundleIDs.contains(app.bundleID) { bundleIDs.append(app.bundleID) }
                                }
                            }
                        }
                        .frame(width: 170)
                        TextField("or bundle id, e.g. com.figma.Desktop", text: $manualBundleID)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addManual)
                        Button("Add", action: addManual)
                            .disabled(manualBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(6)
            }

            Text("Key mappings: activate this profile, then click keys on the Keyboard pane.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if !isBuiltin {
                    Button("Delete Profile", role: .destructive) {
                        appState.config.profiles.removeAll { $0.id == profileID }
                        if appState.config.activeProfileID == profileID {
                            appState.config.activeProfileID = appState.config.profiles.first?.id ?? "conductor"
                        }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            guard let profile = appState.config.profile(id: profileID) else { return }
            name = profile.name
            bundleIDs = profile.appBundleIDs
        }
    }

    private func addManual() {
        let trimmed = manualBundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !bundleIDs.contains(trimmed) { bundleIDs.append(trimmed) }
        manualBundleID = ""
    }

    private func save() {
        guard let index = appState.config.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        appState.config.profiles[index].name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : name
        appState.config.profiles[index].appBundleIDs = bundleIDs
    }
}
