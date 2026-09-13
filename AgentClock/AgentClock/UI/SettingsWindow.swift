import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case device = "Clock"
    case integrations = "Integrations"
    case aiControl = "AI Control"
    case display = "Display"
    case colors = "Colours"
    case diagnostics = "Diagnostics"
    case game = "Games"
    case cameraLab = "Camera lab"
    /// EXPERIMENTAL — remove with TextLab once the treatment is chosen.
    case textLab = "Text lab"
    case fleetLab = "Fleet strip"
    case usageLab = "Usage gauge"
    case providerLab = "Provider pages"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .device: "display"
        case .integrations: "puzzlepiece.extension"
        case .aiControl: "sparkles.rectangle.stack"
        case .display: "slider.horizontal.3"
        case .colors: "paintpalette"
        case .diagnostics: "stethoscope"
        case .game: "gamecontroller"
        case .cameraLab: "camera"
        case .textLab: "textformat.size"
        case .fleetLab: "rectangle.split.3x1"
        case .usageLab: "gauge.medium"
        case .providerLab: "person.2"
        }
    }
}

struct SettingsWindow: View {
    @Environment(AppModel.self) private var model
    /// Demo mode exists to be watched, so land on the pane with the panel on it
    /// rather than making the first click a navigation step.
    @State private var section: SettingsSection =
        UserDefaults.standard.bool(forKey: "demo") ? .display : .device

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            Group {
                switch section {
                case .device: DevicePane()
                case .integrations: IntegrationsPane()
                case .aiControl: AIControlPane()
                case .display: DisplayPane()
                case .colors: ColorsPane()
                case .diagnostics: DiagnosticsPane()
                case .game: GamePane()
                case .cameraLab: CameraLabPane()
                case .textLab: TextLabPane()
                case .fleetLab: FleetLabPane()
                case .usageLab: UsageLabPane()
                case .providerLab: ProviderLabPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
        }
    }
}
