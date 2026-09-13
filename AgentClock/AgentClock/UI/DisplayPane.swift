import SwiftUI

/// What the clock shows, and in what colour.
struct DisplayPane: View {
    @Environment(AppModel.self) private var model
    @State private var isSendingTest = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Display").font(.title2.bold())
                    Spacer()
                    Button(model.isDemoRunning ? "Stop demo" : "Run demo") { model.toggleDemo() }
                    Button("Send test page") { sendTest() }
                        .disabled(model.config.clockHost.isEmpty || isSendingTest)
                    if isSendingTest { ProgressView().controlSize(.small) }
                }

                // The live preview sits above the settings on purpose: every
                // toggle below changes what it shows, and seeing that happen
                // beats reasoning about it.
                SimulatedClockView(pixelSize: 12)
                    .padding(.bottom, 4)

                if !model.config.clockHost.isEmpty {
                    Label("Demo's opening animation requires Art-Net to be enabled in the clock's web interface.",
                          systemImage: "network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Form {
                    Section {
                        Toggle("Focused agent", isOn: $model.config.display.showAgentPage)
                        Picker("Show", selection: $model.config.display.agentPageStyle) {
                            Text("Work and elapsed").tag(DisplayConfig.AgentPageStyle.label)
                            Text("What it's doing").tag(DisplayConfig.AgentPageStyle.state)
                            Text("Both, in turn").tag(DisplayConfig.AgentPageStyle.both)
                        }
                        .disabled(!model.config.display.showAgentPage)
                        Toggle("Fleet summary", isOn: $model.config.display.showFleetPage)
                        Toggle("One page per project", isOn: $model.config.display.showProjectPages)
                        Stepper("At most \(model.config.display.maxProjectPages) project pages",
                                value: $model.config.display.maxProjectPages, in: 1...12)
                    } header: {
                        Text("Pages in the rotation")
                    } footer: {
                        Text("The fleet page appears only with more than one agent running, and project pages only when agents are spread across more than one project.")
                            .font(.caption)
                    }

                    Section {
                        Toggle("Needs permission or input", isOn: $model.config.display.notifyOnWaiting)
                        Toggle("Errors", isOn: $model.config.display.notifyOnError)
                        Toggle("Task complete", isOn: $model.config.display.notifyOnSuccess)
                    } header: {
                        Text("Interrupts")
                    } footer: {
                        Text("Interrupts jump the queue instead of waiting their turn in the rotation.")
                            .font(.caption)
                    }

                    Section {
                        Toggle("Hold \"needs you\" until the agent is unblocked",
                               isOn: $model.config.display.holdWaiting)
                        Toggle("Hold errors on screen", isOn: $model.config.display.holdError)
                        Toggle("Wake a dark panel for \"needs you\"",
                               isOn: $model.config.display.wakeOnWaiting)
                        Toggle("Play a sound", isOn: $model.config.display.soundsEnabled)
                    } header: {
                        Text("Behaviour")
                    } footer: {
                        Text("A held interrupt stays up until AgentClock retracts it, which happens the moment that agent stops waiting. \"Task complete\" never wakes a dark panel.")
                            .font(.caption)
                    }

                    Section("Timing") {
                        Picker("Page duration", selection: $model.config.display.pageDurationMs) {
                            Text("Clock's default").tag(0)
                            Text("3 seconds").tag(3000)
                            Text("5 seconds").tag(5000)
                            Text("8 seconds").tag(8000)
                        }
                        Picker("Long labels", selection: $model.config.display.longText) {
                            Text("Shorten to fit").tag(DisplayConfig.LongText.shorten)
                            Text("Scroll").tag(DisplayConfig.LongText.scroll)
                        }
                        Picker("Scroll speed", selection: $model.config.display.scrollSpeed) {
                            Text("Slow").tag(40)
                            Text("Comfortable").tag(60)
                            Text("Brisk").tag(80)
                            Text("Device default").tag(100)
                        }
                        Picker("Refresh pages every", selection: $model.config.display.heartbeatSeconds) {
                            Text("1 minute").tag(TimeInterval(60))
                            Text("5 minutes").tag(TimeInterval(300))
                            Text("15 minutes").tag(TimeInterval(900))
                        }
                        Text("The panel's font is 5 pixels tall and there is no smaller one, so a 32x8 panel fits about six characters beside an icon. Shortening keeps pages still; scrolling shows everything but takes time to read.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Pushed pages live in the clock's memory and are lost when it reboots. The refresh puts them back.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: 560)
                .onChange(of: model.config.display) { model.scheduleConfigSave() }
            }
            .frame(maxWidth: 640, alignment: .leading)
        }
        .onAppear { model.startSimulatorTick() }
        .onDisappear { model.stopSimulatorTick() }
    }

    private func sendTest() {
        isSendingTest = true
        Task {
            await model.sendTestPage()
            isSendingTest = false
        }
    }
}
