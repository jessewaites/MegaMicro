import Foundation

/// The Codex Micro / Creator Micro 2 wire protocol: compact JSON-RPC carried
/// in 64-byte HID reports. Derived from OpenAI's published device kit (as
/// documented by the MIT-licensed DevVig/microbridge project); confirmed by
/// Work Louder that this hardware family is not QMK/VIA.
///
/// Frame layout (64 bytes): [reportID 0x06][channel][payload len 0–61][UTF-8
/// payload…]. Messages longer than 61 bytes span consecutive reports; a
/// report with len < 61 terminates the message.
enum VOAI {
    // MARK: Identity

    static let vendorID = 0x303A                 // Espressif (ESP32-class board)
    static let codexMicroPID = 0x8360
    static let creatorMicro2PIDs = [0x8297, 0x8298]
    static var allPIDs: [Int] { [codexMicroPID] + creatorMicro2PIDs }
    static let usagePage = 0xFF00

    static func productName(forPID pid: Int) -> String? {
        switch pid {
        case codexMicroPID: "Codex Micro"
        case 0x8297, 0x8298: "Creator Micro 2"
        default: nil
        }
    }

    // MARK: Framing

    static let reportID: UInt8 = 0x06
    static let reportSize = 64
    static let maxChunk = 61
    static let channelDebug: UInt8 = 1
    static let channelRPC: UInt8 = 2

    /// Split a message into 64-byte reports (report id included as byte 0).
    /// A message that fills its last chunk exactly gets a zero-length
    /// terminator report so the receiver knows it ended.
    static func frames(channel: UInt8, message: Data) -> [[UInt8]] {
        var reports: [[UInt8]] = []
        var offset = 0
        repeat {
            let chunk = message.dropFirst(offset).prefix(maxChunk)
            var report = [UInt8](repeating: 0, count: reportSize)
            report[0] = reportID
            report[1] = channel
            report[2] = UInt8(chunk.count)
            for (i, byte) in chunk.enumerated() {
                report[3 + i] = byte
            }
            reports.append(report)
            offset += chunk.count
        } while offset < message.count
        if message.count > 0, message.count % maxChunk == 0 {
            var terminator = [UInt8](repeating: 0, count: reportSize)
            terminator[0] = reportID
            terminator[1] = channel
            reports.append(terminator)
        }
        return reports
    }

    /// Reassembles chunked incoming reports into complete messages.
    struct FrameAccumulator {
        private var buffers: [UInt8: Data] = [:]   // per channel

        /// Feed one incoming report; returns (channel, message) when complete.
        mutating func append(_ report: [UInt8]) -> (channel: UInt8, message: Data)? {
            // Tolerate transports that strip the leading report id.
            let bytes = report.first == VOAI.reportID ? Array(report.dropFirst()) : report
            guard bytes.count >= 2 else { return nil }
            let channel = bytes[0]
            let length = Int(bytes[1])
            guard length <= maxChunk, bytes.count >= 2 + length else { return nil }
            buffers[channel, default: Data()].append(contentsOf: bytes[2..<(2 + length)])
            if length < maxChunk {
                let message = buffers.removeValue(forKey: channel) ?? Data()
                return (channel, message)
            }
            return nil
        }
    }

    // MARK: RPC

    /// Per-key lighting, one entry per agent slot.
    /// Optionals are omitted from the JSON entirely.
    ///
    /// IMPORTANT: omitted fields *latch* on the device — they keep whatever
    /// value they had. A stale `sk: 1` from an earlier call keeps washing the
    /// whole keys zone with one thread's colour and silently defeats per-key
    /// lighting, so we always send `sk`/`sa` explicitly.
    struct ThreadParam: Codable, Hashable, Sendable {
        var id: Int
        var c: UInt32?     // packed 0xRRGGBB
        var b: Double?     // brightness 0–1
        var e: UInt8?      // effect (see Effect)
        var s: Double?     // speed 0–1
        var sk: UInt8?     // syncKeysLighting  (1 = wash whole keys zone)
        var sa: UInt8?     // syncAmbientLighting
    }

    /// The six agent keys must be bound to these keycodes **on the active
    /// layer** before per-key lighting renders. Without them the firmware
    /// still answers `{"ok":1}` to every thstatus call and lights nothing —
    /// there is no error to detect, so verify the keymap, not the response.
    static let agentKeycodes = (0..<13).map { String(format: "KV_OAI_AG%02d", $0) }

    /// Parses "AG03" (as sent in `v.oai.hid` notifications) into a slot index.
    static func agentSlot(fromKeyName name: String) -> Int? {
        guard name.hasPrefix("AG"), let n = Int(name.dropFirst(2)) else { return nil }
        return n
    }

    /// Physical key index for each agent slot — the slot number is NOT the key
    /// index. Slots 0–5 are the top two rows (keys 0–5).
    ///
    /// The bottom row is not 1:1: the wide key spans TWO switches, so slots 6
    /// and 7 both belong to key 11 and a single press reports both. Slot 6 is
    /// mapped to nil so the press dispatches once instead of twice; it still
    /// takes colour (see `agentSlots(forKeyIndex:)`).
    static let agentSlotKeyIndices: [Int?] = [0, 1, 2, 3, 4, 5, nil, 11, 12, 6, 7, 8, 9]

    static func keyIndex(forAgentSlot slot: Int) -> Int? {
        guard agentSlotKeyIndices.indices.contains(slot) else { return nil }
        return agentSlotKeyIndices[slot]
    }

    /// Every slot that lights a given key. The wide key needs both of its
    /// switches set to the same colour to look uniform.
    static func agentSlots(forKeyIndex key: Int) -> [Int] {
        if key == 11 { return [6, 7] }
        return agentSlotKeyIndices.indices.filter { agentSlotKeyIndices[$0] == key }
    }

    /// LED index each agent slot draws its colour from. Slots 6 and 7 share
    /// LED 10 so both halves of the wide key light the same.
    static let ledIndexForAgentSlot = [0, 1, 2, 3, 4, 5, 10, 10, 11, 6, 7, 8, 9]

    /// The factory keymap, used to hand the board back. Restoring this makes
    /// the keys type letters again instead of reporting to MegaMicro.
    static let stockKeymap = [
        ["KC_A", "KC_B"],
        ["KC_C", "KC_D", "KC_E", "KC_F"],
        ["KC_G", "KC_H", "KC_I", "KC_J"],
        ["KC_K", "KC_L", "KC_M"],
    ]
    static let stockEncoders = [["KC_VOLU", "KC_VOLD", "KC_MPLY"]]

    /// Keycodes the dial sends after MegaMicro programs it. These must match
    /// the dial entries in `DefaultTriggers`, and must be F20 or below —
    /// macOS has no virtual keycode for F21 and up, so those arrive nowhere.
    static let dialClockwise = "KC_F19"
    static let dialCounterclockwise = "KC_F20"
    static let dialPress = "KC_F18"

    /// Which keymap positions get agent keycodes: (row, first position, slots).
    ///
    /// All 13 keys are bound: an unbound key sends a raw letter (KC_G and
    /// friends) that MegaMicro cannot see, so it would type into whatever is
    /// focused instead of running its action. The bottom-left layer button is
    /// NOT in the keymap — the firmware handles it — so row 3 is safe too.
    static let agentRows: [(row: Int, position: Int, slots: Range<Int>)] = [
        (0, 0, 0..<2), (1, 0, 2..<6), (3, 0, 6..<9), (2, 0, 9..<13),
    ]

    enum Effect: UInt8 {
        case off = 0, solid = 1, snake = 2, rainbow = 3
        case breath = 4, gradient = 5, shallowBreath = 6
    }

    static let methodThreadStatus = "v.oai.thstatus"
    /// Ambient ring + key backlight. Live once the layer is agent-bound; it is
    /// `lights.preview` that goes inert in that mode, not this.
    static let methodRGBConfig = "v.oai.rgbcfg"
    /// Whole-device lighting: the two global surfaces. Works on fw ≥ 0.4.
    static let methodLightsPreview = "lights.preview"
    static let methodDeviceStatus = "device.status"
    static let methodFSRead = "fs.read"
    static let methodFSWrite = "fs.write"
    static let notifyHID = "v.oai.hid"
    static let notifyJoystick = "v.oai.rad"
    /// Older/base firmware names the joystick notification differently.
    static let notifyJoystickLegacy = "kb.radial"

    /// Compact JSON request. Ids cycle 0–999 — the firmware ignores ids ≥ 1000.
    static func threadStatusRequest(id: Int, params: [ThreadParam]) throws -> Data {
        struct Request: Encodable {
            let id: Int
            let method: String
            let params: [ThreadParam]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Request(id: id % 1000, method: methodThreadStatus, params: params))
    }

    /// One of the two global lighting surfaces driven by `lights.preview`.
    struct SurfaceParam: Codable, Hashable, Sendable {
        var effect: String          // "off" | "solid" | "breath" | "rainbow" | …
        var brightness: Double      // 0–1
        var speed: Double           // 0–1
        var magic: Double
        var color: UInt32           // packed 0xRRGGBB

        static let off = SurfaceParam(effect: "off", brightness: 0, speed: 0, magic: 1, color: 0)
    }

    /// One lighting zone for `v.oai.rgbcfg`. Unlike `lights.preview`, this
    /// takes the **numeric** effect enum, not effect names.
    struct ZoneParam: Codable, Hashable, Sendable {
        var e: UInt8       // Effect
        var b: Double      // brightness 0–1
        var s: Double      // speed 0–1
        var m: Double      // "magic"
        var c: UInt32      // packed 0xRRGGBB

        static let off = ZoneParam(e: Effect.off.rawValue, b: 0, s: 0, m: 1, c: 0)
    }

    /// Ambient ring + key backlight, the OAI-mode counterpart to `thstatus`.
    ///
    /// This — not `lights.preview` — is what drives lighting once the layer's
    /// keys are bound to `KV_OAI_AG*`. In that mode the firmware owns the LEDs
    /// and ignores `lights.preview` entirely, which is why the preview call
    /// silently does nothing on an agent-bound layer.
    static func rgbConfigRequest(id: Int, ambient: ZoneParam, keys: ZoneParam) throws -> Data {
        struct Params: Encodable { let ambient: ZoneParam; let keys: ZoneParam }
        struct Request: Encodable { let id: Int; let method: String; let params: Params }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Request(id: id % 1000,
                                          method: methodRGBConfig,
                                          params: Params(ambient: ambient, keys: keys)))
    }

    static func lightsPreviewRequest(id: Int, backlight: SurfaceParam, underglow: SurfaceParam) throws -> Data {
        struct Params: Encodable { let backlight: SurfaceParam; let underglow: SurfaceParam }
        struct Request: Encodable { let id: Int; let method: String; let params: Params }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Request(id: id % 1000,
                                          method: methodLightsPreview,
                                          params: Params(backlight: backlight, underglow: underglow)))
    }

    /// `fs.read` / `fs.write` move whole JSON documents (the keymap), unlike
    /// the chunked `fs.readbin`/`fs.writebin` pair.
    static func deviceStatusRequest(id: Int) throws -> Data {
        struct Request: Encodable { let id: Int; let method: String }
        return try JSONEncoder().encode(Request(id: id % 1000, method: methodDeviceStatus))
    }

    static func fsReadRequest(id: Int, file: String) throws -> Data {
        struct Params: Encodable { let file: String }
        struct Request: Encodable { let id: Int; let method: String; let params: Params }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(Request(id: id % 1000, method: methodFSRead, params: Params(file: file)))
    }

    static func fsWriteRequest(id: Int, file: String, data: String) throws -> Data {
        struct Params: Encodable { let file: String; let data: String }
        struct Request: Encodable { let id: Int; let method: String; let params: Params }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(Request(id: id % 1000, method: methodFSWrite,
                                          params: Params(file: file, data: data)))
    }

    // MARK: Incoming events

    enum DeviceEvent: Equatable {
        case key(index: Int, action: String?)
        case joystick(angle: Double, distance: Double)
        case debug(String)
        case other(method: String)
    }

    /// Device→host **notifications** use the abbreviated envelope `{"m":…,"p":…}`;
    /// only *responses* use `method`/`params`. Matching on `method` alone drops
    /// every key and joystick event and makes the agent keys look inert.
    static func parseMessage(channel: UInt8, message: Data) -> DeviceEvent? {
        if channel == channelDebug {
            return .debug(String(decoding: message, as: UTF8.self))
        }
        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              let method = (object["m"] as? String) ?? (object["method"] as? String)
        else { return nil }
        let params = (object["p"] as? [String: Any]) ?? (object["params"] as? [String: Any]) ?? [:]
        switch method {
        case notifyHID:
            // `k` is a key *name* ("AG01") on current firmware; older builds
            // sent a bare index.
            let index: Int?
            if let name = params["k"] as? String {
                index = agentSlot(fromKeyName: name)
            } else {
                index = params["k"] as? Int
            }
            guard let index else { return .other(method: method) }
            // `act` is numeric (1 = down) on current firmware.
            let action = (params["act"] as? String) ?? (params["act"] as? Int).map(String.init)
            return .key(index: index, action: action)
        case notifyJoystick, notifyJoystickLegacy:
            let angle = (params["a"] as? NSNumber)?.doubleValue ?? 0
            let distance = (params["d"] as? NSNumber)?.doubleValue ?? 0
            return .joystick(angle: angle, distance: distance)
        default:
            return .other(method: method)
        }
    }

    // MARK: Effect translation (our States & Colors → firmware effects)

    static func packedRGB(_ hsv: HSV) -> UInt32 {
        // Hue/saturation at full value; brightness travels separately in `b`.
        let rgb = HSV(h: hsv.h, s: hsv.s, v: 255).rgb
        let r = UInt32((rgb.r * 255).rounded())
        let g = UInt32((rgb.g * 255).rounded())
        let b = UInt32((rgb.b * 255).rounded())
        return (r << 16) | (g << 8) | b
    }

    /// Our animation kinds → firmware effect + speed. The firmware animates
    /// on-device, so state changes are one message, not a 20 Hz stream.
    static func effectParams(for kind: EffectSpec.Kind) -> (effect: Effect, speed: Double?) {
        switch kind {
        case .solid:
            (.solid, nil)
        case .breathing(let period):
            (.breath, clamp(1.54 / max(period, 0.1), 0.15, 1.0))
        case .blink(let hz):
            (.breath, clamp(hz / 2.4, 0.2, 1.0))
        case .strobe:
            (.breath, 1.0)
        case .fadeOut:
            (.solid, nil)   // brightness rides in `b`, quantized by the device layer
        }
    }

    static func ambientZoneParam(for spec: EffectSpec, renderedColor: HSV) -> ZoneParam {
        if case .breathing = spec.kind {
            let (effect, speed) = effectParams(for: spec.kind)
            return ZoneParam(
                e: effect.rawValue,
                b: Double(spec.color.v) / 255.0,
                s: speed ?? 0.5,
                m: 1,
                c: packedRGB(spec.color))
        }
        return ZoneParam(
            e: Effect.solid.rawValue,
            b: Double(renderedColor.v) / 255.0,
            s: 0.5,
            m: 1,
            c: packedRGB(renderedColor))
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
