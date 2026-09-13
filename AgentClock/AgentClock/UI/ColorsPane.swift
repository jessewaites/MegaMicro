import SwiftUI

/// The colour legend, and the place to change it.
///
/// Colour carries almost everything on a 32×8 panel — the state lives in the
/// mark's eyes and the quota lives in a bar, and neither has room to say so in
/// words. That makes "what does amber mean" a question the app has to answer
/// somewhere, and a page of swatches with live examples answers it better than
/// a paragraph would.
struct ColorsPane: View {
    @Environment(AppModel.self) private var model

    /// What each state actually means, in the terms someone glancing at a desk
    /// clock would want.
    private static let meanings: [AgentState: String] = [
        .idle: "Nothing running. The panel hands the rotation back to the clock's own apps.",
        .thinking: "Working out what to do — reading, planning, deciding.",
        .coding: "Actually doing it: editing files, running commands.",
        .waiting: "Stopped and needs you. The panel holds on this until you answer.",
        .success: "Finished its task.",
        .error: "Something went wrong.",
    ]

    private static let bands: [(key: String, label: String, detail: String, sample: Double)] = [
        ("ok", "Plenty left", "Under 50% of the window used.", 0.3),
        ("warn", "Tightening", "50% to 80%.", 0.65),
        ("critical", "Nearly gone", "Over 80% — worth slowing down.", 0.92),
    ]

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                states
                gauge
                brands
                Button("Reset every colour to its default") {
                    model.config.display.stateColors = StatePalette.defaults
                    model.config.display.gaugeColors = StatePalette.gaugeDefaults
                    model.scheduleConfigSave()
                }
                .disabled(model.config.display.stateColors == StatePalette.defaults
                          && model.config.display.gaugeColors == StatePalette.gaugeDefaults)
            }
            .frame(maxWidth: 660, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Colours").font(.title2.bold())
            Text("At 32×8 there is no room to write what an agent is doing, so colour says it. Every example below is drawn the way the panel draws it.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Agent states

    private var states: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent state — the mark's eyes").font(.headline)
            Text("The body keeps its brand colour so you can tell Claude from Codex; the eyes carry what it is doing.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(AgentState.allCases, id: \.self) { state in
                stateRow(state)
                Divider()
            }
        }
    }

    private func stateRow(_ state: AgentState) -> some View {
        @Bindable var model = model
        let hex = StatePalette.color(for: state, in: model.config.display.stateColors)
        return HStack(alignment: .center, spacing: 12) {
            // The real thing, not a swatch: the mark with these eyes.
            MatrixView(canvas: ProviderPage.render(
                .init(source: "claude-code", state: state, subagents: [], quota: 0, context: 0),
                style: .markOnly,
                colors: model.config.display.stateColors,
                gauge: model.config.display.gaugeColors,
                width: 12), pixelSize: 7, showsBezel: false)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.wireName.capitalized).font(.callout.weight(.medium))
                Text(Self.meanings[state] ?? "").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(hex).font(.caption.monospaced()).foregroundStyle(.secondary)
            ColorPicker("", selection: Binding(
                get: { Color(hex: hex) ?? .gray },
                set: { newValue in
                    guard let encoded = newValue.hexString else { return }
                    model.config.display.stateColors[state.wireName] = encoded
                    model.scheduleConfigSave()
                }), supportsOpacity: false)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    // MARK: Quota gauge

    private var gauge: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quota — the bar").font(.headline)
            Text("How much of the provider's window is spent. Three bands rather than a gradient: at this size a continuous ramp just reads as \"some colour\".")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.bands, id: \.key) { band in
                gaugeRow(band)
                Divider()
            }
        }
    }

    private func gaugeRow(_ band: (key: String, label: String, detail: String, sample: Double)) -> some View {
        @Bindable var model = model
        let hex = model.config.display.gaugeColors[band.key]
            ?? StatePalette.gaugeDefaults[band.key] ?? "#FFFFFF"
        return HStack(spacing: 12) {
            MatrixView(canvas: ProviderPage.render(
                .init(source: "claude-code", state: .coding, subagents: [],
                      quota: band.sample, context: 0),
                style: .bossAndCrew,
                colors: model.config.display.stateColors,
                gauge: model.config.display.gaugeColors), pixelSize: 6, showsBezel: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(band.label).font(.callout.weight(.medium))
                Text(band.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(hex).font(.caption.monospaced()).foregroundStyle(.secondary)
            ColorPicker("", selection: Binding(
                get: { Color(hex: hex) ?? .gray },
                set: { newValue in
                    guard let encoded = newValue.hexString else { return }
                    model.config.display.gaugeColors[band.key] = encoded
                    model.scheduleConfigSave()
                }), supportsOpacity: false)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    // MARK: Brand marks

    private var brands: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider marks").font(.headline)
            Text("Baked into the pixel art rather than settings — these are the brands, not preferences. Listed so the legend is complete.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(["claude-code", "codex"], id: \.self) { source in
                HStack(spacing: 12) {
                    MatrixView(canvas: ProviderPage.render(
                        .init(source: source, state: .idle, subagents: [], quota: 0, context: 0),
                        style: .markOnly,
                        colors: model.config.display.stateColors,
                        gauge: model.config.display.gaugeColors,
                        width: 12), pixelSize: 7, showsBezel: false)
                    Text(AppModel.readableSourceName(source)).font(.callout)
                    Spacer()
                    Text(StatePalette.brandColors[source] ?? "")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Text("A subagent is the same creature at 5×4, tinted by its own state.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
