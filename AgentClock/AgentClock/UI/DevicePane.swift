import SwiftUI

/// Point AgentClock at the pixel clock. Bonjour fills this in automatically;
/// the text field is the fallback for VLANs and guest networks where mDNS is
/// blocked, and for anyone who'd rather pin an IP.
struct DevicePane: View {
    @Environment(AppModel.self) private var model
    @State private var isTesting = false
    @State private var verdict: FirmwareCheck.Verdict?
    @State private var isChecking = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Clock").font(.title2.bold())
                status

                Form {
                    Section {
                        TextField("Host or IP", text: $model.config.clockHost,
                                  prompt: Text("awtrixng-a1b2c3.local"))
                            .onSubmit { test() }
                        HStack {
                            Button("Test connection") { test() }
                                .disabled(model.config.clockHost.isEmpty || isTesting)
                            if isTesting { ProgressView().controlSize(.small) }
                        }
                    } footer: {
                        Text("The panel scrolls its IP address in rainbow text when it joins Wi-Fi. A DHCP reservation or a custom hostname saves you doing this again.")
                            .font(.caption)
                    }

                    Section("Password protection") {
                        TextField("Username", text: $model.config.clockUsername)
                        SecureField("Password", text: $model.config.clockPassword)
                        Text("Only needed if you turned on authentication in the clock's web UI.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: 520)
                .onChange(of: model.config.clockHost) { model.scheduleConfigSave() }
                .onChange(of: model.config.clockUsername) { model.scheduleConfigSave(); model.refreshClockEndpoint() }
                .onChange(of: model.config.clockPassword) { model.scheduleConfigSave(); model.refreshClockEndpoint() }

                discovered
                setup
            }
            .frame(maxWidth: 620, alignment: .leading)
        }
        .onAppear { model.discovery.start(); check() }
        .onDisappear { model.discovery.stop() }
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.clockIsReachable ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(model.clockIsReachable
                 ? "Connected to \(model.config.clockHost) · \(model.panelWidth)×8"
                 : model.config.clockHost.isEmpty
                   ? "No clock configured"
                   : "Cannot reach \(model.config.clockHost)")
                .font(.callout)
            if let error = model.clockLastError, !model.clockIsReachable {
                Text("· \(error)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var discovered: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("On this network").font(.headline)
                if model.discovery.isBrowsing && model.discovery.results.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            if model.discovery.results.isEmpty {
                Text("Nothing found yet. Bonjour is blocked on some networks — typing the address above always works.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.discovery.results) { found in
                    HStack {
                        Image(systemName: "display")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(found.name).font(.callout)
                            Text(found.host).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Use") { model.adoptDiscovered(host: found.host) }
                            .disabled(model.config.clockHost == found.host)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    /// Setup help, and only when it is needed: once the panel answers there is
    /// nothing here worth the space.
    @ViewBuilder
    private var setup: some View {
        if let verdict, !verdict.isReady {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text("Setup").font(.headline)
                    if isChecking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Check again") { check() }.disabled(isChecking)
                }
                Text(verdict.summary).font(.callout)
                if let advice = verdict.advice {
                    Text(advice)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .notFlashed(let port) = verdict {
                    Text("Found on \(port)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Link("Open the flasher", destination: FirmwareCheck.flasherURL)
                    Text(FirmwareCheck.browserNote)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("AgentClock does not flash anything itself: a failed write leaves the board unbootable, and the stock firmware is overwritten in the process. The browser flasher already does this well.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
    }

    private func check() {
        isChecking = true
        Task {
            let host = model.config.clockHost.isEmpty
                ? model.discovery.results.first?.host
                : model.config.clockHost
            verdict = await FirmwareCheck.probe(host: host)
            isChecking = false
        }
    }

    private func test() {
        isTesting = true
        Task {
            await model.testClockConnection()
            isTesting = false
            check()
        }
    }
}
