import Foundation

/// Per-state colours for the matrix, as `#RRGGBB` strings — the only colour
/// format the AWTRIX payload schema takes for `textColor` and friends.
///
/// Seeded from MegaMicro's keyboard palette (`RGBRules.standard`), which is
/// authored in QMK HSV where every component is 0–255 and hue wraps at 256
/// rather than 360. Converted here at full value, because the panel has its
/// own global brightness control and dimming twice just makes text unreadable.
///
///     idle      h0   s0   v90   → dim white
///     thinking  h170 s255 v150  → 239° blue
///     coding    h128 s255 v150  → 180° cyan
///     waiting   h40  s255 v150  → 56°  amber
///     success   h85  s255 v150  → 120° green
///     error     h0   s255 v150  → 0°   red
///
/// Users can retune every one of these in Settings → Display; what reads well
/// through a diffuser is a matter of taste and of the panel's brightness.
enum StatePalette {
    static let defaults: [String: String] = [
        "idle": "#808080",
        "thinking": "#0004FF",
        "coding": "#00FFFF",
        "waiting": "#FFEF00",
        "success": "#02FF00",
        "error": "#FF0000",
    ]

    /// Colour for a state, falling back to the built-in default and then to
    /// white — a page with an unreadable colour is worse than a wrong one.
    static func color(for state: AgentState, in overrides: [String: String]) -> String {
        overrides[state.wireName] ?? defaults[state.wireName] ?? "#FFFFFF"
    }

    /// The gauge's three bands. Thresholds rather than a continuous ramp: at
    /// eight pixels a hue gradient just reads as "some colour", where three
    /// distinct bands read as plenty / tightening / nearly gone.
    static let gaugeDefaults: [String: String] = [
        "ok": "#02FF00",
        "warn": "#FFEF00",
        "critical": "#FF0000",
    ]

    /// Where each band starts, as a fraction of the quota used.
    static let warnThreshold = 0.5
    static let criticalThreshold = 0.8

    static func gaugeBand(for utilization: Double) -> String {
        switch utilization {
        case ..<warnThreshold: "ok"
        case ..<criticalThreshold: "warn"
        default: "critical"
        }
    }

    static func gaugeColor(for utilization: Double, in overrides: [String: String]) -> String {
        let band = gaugeBand(for: utilization)
        return overrides[band] ?? gaugeDefaults[band] ?? "#FFFFFF"
    }

    /// The colour each provider's mark rests in. Baked into the pixel art
    /// rather than configurable — it is the brand, not a setting — but worth
    /// showing alongside the rest so the legend is complete.
    static let brandColors: [String: String] = [
        "claude-code": "#D97757",
        "codex": "#011299",
    ]

    /// Validates a user-entered colour. AWTRIX rejects the whole payload on a
    /// malformed colour anywhere in it, so bad input must never reach the wire.
    static func isValidHex(_ value: String) -> Bool {
        guard value.count == 7, value.hasPrefix("#") else { return false }
        return value.dropFirst().allSatisfy(\.isHexDigit)
    }
}
