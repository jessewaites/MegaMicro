import Foundation

/// How a key (or the whole board) renders one agent state.
struct EffectSpec: Codable, Hashable, Sendable {
    enum Kind: Codable, Hashable, Sendable {
        case solid
        case breathing(period: Double)
        case blink(hz: Double)
        case strobe(hz: Double)
        case fadeOut(total: Double)
    }
    var color: HSV
    var kind: Kind
}

/// AgentState → visual effect, per profile. Default palette: idle dim white,
/// working breathing, waiting yellow blink, success green fade, error red
/// strobe — all user-editable in the States & Colors pane.
struct RGBRules: Codable, Hashable, Sendable {
    var rules: [AgentState: EffectSpec]

    func spec(for state: AgentState) -> EffectSpec {
        rules[state] ?? EffectSpec(color: .off, kind: .solid)
    }

    static let standard = RGBRules(rules: [
        // Idle is dim white, not off: an occupied-but-resting key still has to
        // read as occupied. At v:25 it was invisible through a diffused keycap
        // and looked like a broken or unassigned key.
        .idle: EffectSpec(color: HSV(h: 0, s: 0, v: 90), kind: .solid),
        .thinking: EffectSpec(color: HSV(h: 170, s: 255, v: 150), kind: .breathing(period: 3.6)),
        .coding: EffectSpec(color: HSV(h: 128, s: 255, v: 150), kind: .breathing(period: 2.8)),
        .waiting: EffectSpec(color: HSV(h: 40, s: 255, v: 150), kind: .blink(hz: 1.2)),
        .success: EffectSpec(color: HSV(h: 85, s: 255, v: 150), kind: .fadeOut(total: 45)),
        .error: EffectSpec(color: HSV(h: 0, s: 255, v: 150), kind: .strobe(hz: 5)),
    ])
}

/// What the perimeter underglow displays (independent of the per-key LEDs).
enum UnderglowMode: Codable, Hashable, Sendable {
    /// Fleet status: the highest-priority state across ALL agents — one
    /// glance at the halo answers "does anything need me?"
    case aggregate
    case solid(HSV)
    case off
    /// The firmware's own rotating rainbow, which the board ships with — but
    /// it turns solid red the moment an agent errors or needs you, so the
    /// pretty default doubles as an alarm. Animated on-device, so it costs one
    /// message per state change rather than a 20 Hz colour stream.
    case rainbowUnlessAlert
}

/// A named set of control→action mappings plus RGB rules, optionally
/// auto-activated when one of `appBundleIDs` owns the frontmost window.
struct Profile: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var appBundleIDs: [String]
    var mappings: [ControlID: [ControlGesture: Action]]
    var rgbRules: RGBRules
    var underglow: UnderglowMode = .aggregate

    init(id: String, name: String, appBundleIDs: [String],
         mappings: [ControlID: [ControlGesture: Action]],
         rgbRules: RGBRules, underglow: UnderglowMode = .aggregate) {
        self.id = id
        self.name = name
        self.appBundleIDs = appBundleIDs
        self.mappings = mappings
        self.rgbRules = rgbRules
        self.underglow = underglow
    }

    // Tolerant decoding: profiles saved before `underglow` existed must not
    // fail (a failed [Profile] decode would reset the user's whole config).
    enum CodingKeys: String, CodingKey {
        case id, name, appBundleIDs, mappings, rgbRules, underglow
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        appBundleIDs = try c.decodeIfPresent([String].self, forKey: .appBundleIDs) ?? []
        mappings = try c.decodeIfPresent([ControlID: [ControlGesture: Action]].self, forKey: .mappings) ?? [:]
        rgbRules = try c.decodeIfPresent(RGBRules.self, forKey: .rgbRules) ?? .standard
        underglow = try c.decodeIfPresent(UnderglowMode.self, forKey: .underglow) ?? .aggregate
    }

    func action(for control: ControlID, gesture: ControlGesture) -> Action {
        mappings[control]?[gesture] ?? .none
    }
}
