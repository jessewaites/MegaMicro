import SwiftUI

struct DashboardPane: View {
    @Environment(AppState.self) private var appState

    private enum Filter: String, CaseIterable, Hashable {
        case all = "All"
        case attention = "Attention"
        case working = "Working"
        case completed = "Completed"
    }

    @State private var filter: Filter = .all
    @State private var page = 0
    @State private var deviceTilt = CGSize.zero
    @State private var deviceNameDraft = ""
    @State private var deviceNameEditing = false

    /// Rows shown at once. Keeps the pane — and therefore the window, which
    /// sizes to its tallest tab — at a fixed height no matter how many events
    /// accumulate (the feed itself holds up to 200).
    private let pageSize = 12

    /// On/off for the physical board, where you can actually find it. Off
    /// leaves it dark and typing letters again — dark for real, written into
    /// the board, so it stays that way on a desk we've walked away from — and
    /// hands it to another app (Codex, Work Louder Input) if one wants it;
    /// only one host can drive it at a time.
    @ViewBuilder
    private var keyboardPowerControl: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.hardwareConnected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(appState.hardwareConnected ? "Keyboard on" : "Keyboard off")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(appState.hardwareConnected ? "Turn Off" : "Turn On") {
                if appState.hardwareConnected {
                    appState.disconnectHardware()
                } else {
                    appState.connectHardware()
                }
            }
            .controlSize(.small)
            Button(appState.lightShowRunning ? "Testing…" : "Test Connection") {
                appState.runConnectionTest()
            }
            .controlSize(.small)
            .disabled(!appState.hardwareConnected || appState.lightShowRunning)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
                GroupBox("Device") {
                    VStack(spacing: 8) {
                        KeyboardView()
                            .environment(\.agentBoardMode, true)
                            .rotation3DEffect(.degrees(Double(deviceTilt.height / 9)), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
                            .rotation3DEffect(.degrees(Double(deviceTilt.width / 9)), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                            .frame(minHeight: 250)
                            .padding(18)
                            // A click still reaches an assigned agent key;
                            // movement becomes the independent 3D inspection
                            // gesture only after the pointer travels 8 points.
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 8)
                                    .onChanged { value in
                                        deviceTilt = CGSize(
                                            width: min(90, max(-90, value.translation.width)),
                                            height: min(65, max(-65, -value.translation.height)))
                                    }
                                    .onEnded { _ in
                                        withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                                            deviceTilt = .zero
                                        }
                                    }
                            )
                        HStack {
                            keyboardPowerControl
                            Spacer()
                            Label("Drag to inspect", systemImage: "move.3d")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                }

                GroupBox("Device Info") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Name").foregroundStyle(.secondary)
                            if deviceNameEditing {
                                HStack {
                                    TextField("My MegaMicro", text: $deviceNameDraft)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit(saveDeviceName)
                                    Button("Save", action: saveDeviceName)
                                        .disabled(deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    Button("Cancel") {
                                        deviceNameDraft = appState.config.deviceName
                                        deviceNameEditing = false
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                HStack {
                                    Text(appState.config.deviceName)
                                    Spacer()
                                    Button {
                                        deviceNameDraft = appState.config.deviceName
                                        deviceNameEditing = true
                                    } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Rename device")
                                }
                            }
                        }
                        infoRow("Model", appState.hardwareName ?? appState.layout.name)
                        infoRow("Status", appState.hardwareConnected ? "Connected" : "Simulator")
                        infoRow("Layout", "\(appState.layout.controls.count) controls")
                        GridRow {
                            Text("Profile").foregroundStyle(.secondary)
                            Picker("Profile", selection: profileBinding) {
                                ForEach(appState.config.profiles) { profile in
                                    Text(profile.name).tag(profile.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            }
            .frame(minWidth: 390, idealWidth: 460, maxWidth: 540)

            VStack(alignment: .leading, spacing: 14) {
                Text("Activity")
                    .font(.title2.weight(.semibold))

                let notice = appState.fleetNotification
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(color(notice.state)).frame(width: 11, height: 11).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(notice.headline).font(.headline)
                        Text(notice.detail).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ScrollView {
                    LazyVStack(spacing: 0) {
                if filteredItems.isEmpty {
                    ContentUnavailableView("No activity yet", systemImage: "waveform.path.ecg",
                                           description: Text("Meaningful agent and keyboard events will appear here."))
                }
                ForEach(pagedItems) { item in
                    HStack(alignment: .top, spacing: 10) {
                        SourceIcon(source: item.source, size: 17).frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(item.agentName + " " + item.message).font(.headline)
                                if item.simulated {
                                    Text("DEMO").font(.system(size: 8, weight: .bold)).foregroundStyle(.orange)
                                }
                            }
                            HStack(spacing: 5) {
                                if let project = item.project { Text(project).fontWeight(.medium); Text("·") }
                                if let slot = item.keySlot { Text("Key \(slot + 1)"); Text("·") }
                                Text(item.at.formatted(.relative(presentation: .named)))
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle().fill(color(item.state)).frame(width: 8, height: 8).padding(.top, 5)
                    }
                    .padding(.vertical, 9)
                    Divider()
                }
                    }
                }
                .frame(maxHeight: .infinity)

                if pageCount > 1 {
                    HStack {
                        Button {
                            page = max(0, page - 1)
                        } label: { Image(systemName: "chevron.left") }
                        .disabled(clampedPage == 0)

                        Spacer()
                        Text(rangeLabel).font(.caption).foregroundStyle(.secondary)
                        Spacer()

                        Button {
                            page = min(pageCount - 1, page + 1)
                        } label: { Image(systemName: "chevron.right") }
                        .disabled(clampedPage >= pageCount - 1)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        // A filter change can shrink the list past the current page; snap back
        // to the first page so the view never lands on an empty slice.
        .onChange(of: filter) { page = 0 }
        .onAppear {
            deviceNameDraft = appState.config.deviceName
        }
    }

    private func saveDeviceName() {
        let name = deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        deviceNameDraft = name
        appState.config.deviceName = name
        if appState.saveConfigNow() {
            deviceNameEditing = false
        }
    }

    private var profileBinding: Binding<String> {
        Binding(
            get: { appState.config.activeProfileID },
            set: { appState.config.activeProfileID = $0 })
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(1)
        }
    }

    private var filteredItems: [ActivityFeedItem] {
        appState.activityFeed.filter { item in
            switch filter {
            case .all: true
            case .attention: item.category == .attention
            case .working: item.category == .working
            case .completed: item.category == .completed
            }
        }
    }

    // MARK: Pagination

    private var pageCount: Int {
        max(1, (filteredItems.count + pageSize - 1) / pageSize)
    }

    /// The live feed can grow or shrink between renders; keep the requested
    /// page within bounds rather than trusting the stored value.
    private var clampedPage: Int {
        min(max(0, page), pageCount - 1)
    }

    private var pagedItems: [ActivityFeedItem] {
        let start = clampedPage * pageSize
        let end = min(start + pageSize, filteredItems.count)
        guard start < end else { return [] }
        return Array(filteredItems[start..<end])
    }

    private var rangeLabel: String {
        let total = filteredItems.count
        guard total > 0 else { return "" }
        let start = clampedPage * pageSize + 1
        let end = min(start + pageSize - 1, total)
        return "\(start)–\(end) of \(total)"
    }


    private func color(_ state: AgentState) -> Color {
        Color(hsv: appState.activeProfile.rgbRules.spec(for: state).color)
    }
}
