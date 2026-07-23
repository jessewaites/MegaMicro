import SwiftUI

enum ConfigSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case agents = "Manage Agents"
    case fleet = "Manage Fleet"
    case keyboard = "Keyboard"
    case layers = "Manage Layers"
    case profiles = "Profiles"
    case states = "States & Colors"
    case snippets = "Prompt Snippets"
    case hooks = "Integrations"
    case permissions = "Permissions"
    case diagnostics = "Diagnostics"
    case settings = "Settings"
    case logs = "Logs"
    case credits = "Credits"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .agents: "cpu"
        case .fleet: "sailboat"   // fallback; sidebar prefers assets/fleet.svg
        case .dashboard: "gauge.with.dots.needle.50percent"
        case .keyboard: "keyboard"
        case .layers: "square.on.square"
        case .profiles: "slider.horizontal.3"
        case .states: "paintpalette"
        case .snippets: "text.quote"
        case .hooks: "link"
        case .permissions: "lock.shield"
        case .diagnostics: "stethoscope"
        case .settings: "gearshape"
        case .logs: "text.alignleft"
        case .credits: "info.circle"
        }
    }
}

struct ConfigurationWindow: View {
    @Environment(AppState.self) private var appState

    private var sectionBinding: Binding<ConfigSection?> {
        @Bindable var state = appState
        return Binding(
            get: { state.activeSection },
            set: { state.activeSection = $0 ?? .keyboard })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: sectionBinding) {
                Section {
                    sidebarRow(.dashboard)
                }
                Section {
                    ForEach(ConfigSection.allCases.filter { $0 != .dashboard }) { item in
                        sidebarRow(item)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch appState.activeSection {
            case .agents: AgentsPane()
            case .fleet: FleetPane()
            case .dashboard: DashboardPane()
            case .keyboard: KeyboardPane()
            case .layers: LayersPane()
            case .profiles: ProfileListView()
            case .states: StatesPane()
            case .snippets: PromptSnippetsPane()
            case .hooks: HooksPane()
            case .permissions: PermissionsView()
            case .diagnostics: DiagnosticsPane()
            case .settings: SettingsPane()
            case .logs: LogsPane()
            case .credits: CreditsPane()
            }
        }
        .navigationTitle("MegaMicro")
        .sheet(item: Binding(
            get: { appState.glyphTarget },
            set: { appState.glyphTarget = $0 }
        )) { control in
            GlyphPickerSheet(control: control)
        }
        .sheet(isPresented: Binding(
            get: { !appState.config.onboardingComplete },
            set: { showing in if !showing { appState.config.onboardingComplete = true } }
        )) {
            OnboardingSheet()
        }
        .toolbar {
            // Status pill only when real hardware is live — no pill, no noise.
            if appState.hardwareConnected {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("\(appState.hardwareName ?? "Keyboard") connected")
                            .font(.caption)
                    }
                }
            }
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) {
                    byline
                }
                .sharedBackgroundVisibility(.hidden)   // no glass capsule behind plain text
            } else {
                ToolbarItem(placement: .primaryAction) {
                    byline
                }
            }
        }
    }

    @ViewBuilder
    private func sidebarRow(_ item: ConfigSection) -> some View {
        Label {
            Text(item.rawValue)
        } icon: {
            if item == .fleet, let fleet = BrandIcon.templateImage(named: "fleet") {
                Image(nsImage: fleet)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: item.symbol)
            }
        }
        .tag(item)
    }

    private var byline: some View {
        HStack(spacing: 4) {
            Text("Built in Boston by")
                .foregroundStyle(.secondary)
            Link("Jesse Waites", destination: URL(string: "https://JesseWaites.com")!)
        }
        .font(.callout)
    }
}

struct KeyboardPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 12) {
            Text("Configure what each physical control does for the selected profile. Edit changes mappings; Simulate lets you test them on screen without pressing the keyboard.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Picker("Active Profile", selection: $state.config.activeProfileID) {
                    ForEach(appState.config.profiles) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 260)
                Spacer()
                Picker("Mode", selection: $state.editMode) {
                    Text("Edit").tag(true)
                    Text("Simulate").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }

            Text(appState.editMode
                 ? "Click any control to edit what it does."
                 : "Clicks fire the mapped action, exactly like a hardware press.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            KeyboardView()
                .frame(minHeight: 260)

            SimulatorControls()

            GroupBox {
                LayoutsSection()
            }
        }
        .padding(16)
        .sheet(item: $state.editTarget) { target in
            MappingEditorView(target: target)
        }
    }
}
