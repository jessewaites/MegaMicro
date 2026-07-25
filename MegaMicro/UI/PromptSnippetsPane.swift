import AppKit
import SwiftUI

struct PromptSnippetsPane: View {
    @Environment(AppState.self) private var appState
    @State private var selection: String?
    @State private var copied = false

    var body: some View {
        HSplitView {
            snippetList
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 280)

            if let binding = selectedBinding {
                editor(binding)
                    .frame(minWidth: 480)
            } else {
                ContentUnavailableView(
                    "No Prompt Selected",
                    systemImage: "text.quote",
                    description: Text("Create a snippet to build a reusable prompt."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Prompt Snippets")
        .onAppear {
            if selection == nil { selection = appState.config.promptSnippets.first?.id }
        }
    }

    private var snippetList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Built In") {
                    ForEach(appState.config.promptSnippets.filter { $0.builtIn }) { snippet in
                        Label(snippet.name, systemImage: "sparkles").tag(snippet.id)
                    }
                }
                Section("My Snippets") {
                    ForEach(appState.config.promptSnippets.filter { !$0.builtIn }) { snippet in
                        Label(snippet.name, systemImage: "text.quote").tag(snippet.id)
                    }
                }
            }

            Divider()
            HStack {
                Button {
                    selection = appState.addPromptSnippet()
                } label: {
                    Image(systemName: "plus")
                }
                .help("New snippet")

                Button {
                    guard let selection else { return }
                    self.selection = appState.duplicatePromptSnippet(id: selection)
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .disabled(selection == nil)
                .help("Duplicate snippet")

                Spacer()

                Button(role: .destructive) {
                    guard let selection else { return }
                    appState.deletePromptSnippet(id: selection)
                    self.selection = appState.config.promptSnippets.first?.id
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedSnippet?.builtIn != false)
                .help("Delete custom snippet")
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }

    private func editor(_ snippet: Binding<PromptSnippet>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Snippet name", text: snippet.name)
                    .font(.title2.bold())
                    .textFieldStyle(.plain)
                if snippet.wrappedValue.builtIn {
                    Text("BUILT IN")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    Button("Restore Original") {
                        appState.restorePromptSnippet(id: snippet.wrappedValue.id)
                    }
                }
            }

            TextEditor(text: snippet.prompt)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                .frame(minHeight: 250)

            HStack {
                Text("Project details can be pasted after the prompt.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if copied {
                    Label("Copied", systemImage: "checkmark")
                        .foregroundStyle(.green)
                }
                Button("Copy Prompt") { copy(snippet.wrappedValue) }
                    .buttonStyle(.borderedProminent)
                    .disabled(snippet.wrappedValue.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        .padding(20)
        .onChange(of: selection) { copied = false }
    }

    private var selectedSnippet: PromptSnippet? {
        appState.config.promptSnippets.first { $0.id == selection }
    }

    private var selectedBinding: Binding<PromptSnippet>? {
        guard let id = selection,
              appState.config.promptSnippets.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { appState.config.promptSnippets.first { $0.id == id }! },
            set: { value in
                guard let index = appState.config.promptSnippets.firstIndex(where: { $0.id == id }) else { return }
                appState.config.promptSnippets[index] = value
            })
    }

    private func copy(_ snippet: PromptSnippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.prompt, forType: .string)
        copied = true
    }
}
