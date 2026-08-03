import Foundation

/// The hotkey a physical control emits after one-time vendor-configurator
/// setup (keys pre-mapped to F13–F20 and Hyper/⌃⌥⌘ chords). MegaMicro's
/// event tap matches incoming keystrokes against these.
struct Trigger: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: Modifiers

    var display: String {
        modifiers.symbols + (KeyCodes.name(for: keyCode) ?? "vk\(keyCode)")
    }
}

/// One row of the global trigger table: chord → (control, gesture).
struct TriggerBinding: Codable, Hashable, Identifiable, Sendable {
    var trigger: Trigger
    var control: ControlID
    var gesture: ControlGesture

    var id: String { "\(trigger.modifiers.rawValue).\(trigger.keyCode)" }
}

enum DefaultTriggers {
    /// Default assignment for the Codex Micro: 13 keys, dial press/rotate,
    /// joystick 4-way, touch strip 2-way = 22 signals.
    static let codexMicro: [TriggerBinding] = {
        let fkeys: [UInt16] = [KeyCodes.f13, KeyCodes.f14, KeyCodes.f15, KeyCodes.f16,
                               KeyCodes.f17, KeyCodes.f18, KeyCodes.f19, KeyCodes.f20]
        var bindings: [TriggerBinding] = []
        // Keys 0–4: plain F13–F17. F18–F20 are reserved for the dial below —
        // on v.oai hardware the agent keys report over HID instead of sending
        // keystrokes, so these plain bindings only matter for boards that are
        // programmed the classic way.
        for i in 0..<5 {
            bindings.append(TriggerBinding(
                trigger: Trigger(keyCode: fkeys[i], modifiers: []),
                control: .key(i), gesture: .press))
        }
        // Dial without modifiers: the Creator Micro 2 encoder can only emit a
        // bare keycode, and macOS delivers nothing above F20.
        bindings.append(TriggerBinding(trigger: Trigger(keyCode: fkeys[5], modifiers: []), control: .dial, gesture: .press))
        bindings.append(TriggerBinding(trigger: Trigger(keyCode: fkeys[6], modifiers: []), control: .dial, gesture: .clockwise))
        bindings.append(TriggerBinding(trigger: Trigger(keyCode: fkeys[7], modifiers: []), control: .dial, gesture: .counterclockwise))
        // Keys 8–12: Hyper+F13–F17
        for i in 8..<13 {
            bindings.append(TriggerBinding(
                trigger: Trigger(keyCode: fkeys[i - 8], modifiers: .hyper),
                control: .key(i), gesture: .press))
        }
        // (The dial is bound above, without modifiers — the encoder can only
        // send a bare keycode.)
        // Joystick: ⌃⌥⌘+F13..F16
        let com: Modifiers = [.control, .option, .command]
        let joyGestures: [ControlGesture] = [.up, .down, .left, .right]
        for (i, g) in joyGestures.enumerated() {
            bindings.append(TriggerBinding(trigger: Trigger(keyCode: fkeys[i], modifiers: com), control: .joystick, gesture: g))
        }
        return bindings
    }()
}
