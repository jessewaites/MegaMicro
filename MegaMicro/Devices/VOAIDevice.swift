import Foundation

/// Codex Micro / Creator Micro 2 backend: per-key agent lighting over the
/// firmware's JSON-RPC HID protocol (`v.oai.thstatus`). The firmware animates
/// effects on-device, so we send one small message per state change instead
/// of a 20 Hz color stream.
///
/// UNVALIDATED ON HARDWARE until the first physical unit arrives — built from
/// the OpenAI device-kit protocol as documented by DevVig/microbridge (MIT),
/// confirmed non-VIA by Work Louder.
final class VOAIDevice: KeyboardDevice {
    /// The firmware addresses six agent keys, ids 0–5.
    static let agentKeyCount = 6

    let layout: KeyboardLayout
    let capabilities = DeviceCapabilities(perKeyRGB: true, underglow: true, maxBrightness: 255)

    private let transport: HIDTransport
    private var accumulator = VOAI.FrameAccumulator()
    private var requestID = 0
    private var callID = 100
    private var pending: [Int: (Result<Any?, Error>) -> Void] = [:]
    private var lastParams: [VOAI.ThreadParam]?
    private(set) var isConnected = false
    private(set) var connectedProduct: String?

    var onConnectionChange: ((Bool) -> Void)?
    /// Semantic input from the pad itself (keys, dial, joystick) — no event
    /// tap or Input-app setup involved.
    var onDeviceEvent: ((VOAI.DeviceEvent) -> Void)?

    init(layout: KeyboardLayout, transport: HIDTransport = HIDTransport(reportSize: VOAI.reportSize, usesLeadingReportID: true)) {
        self.layout = layout
        self.transport = transport
        transport.onConnectionChange = { [weak self] connected in
            self?.isConnected = connected
            if !connected { self?.lastParams = nil }
            self?.onConnectionChange?(connected)
        }
        transport.onInputReport = { [weak self] report in
            guard let self else { return }
            guard let (channel, message) = self.accumulator.append(report) else { return }
            // Responses carry an `id` plus `result`/`error`; notifications use
            // the abbreviated m/p envelope. Route responses first so a pending
            // call isn't mistaken for a device event.
            if channel == VOAI.channelRPC, self.completePending(message) { return }
            if let event = VOAI.parseMessage(channel: channel, message: message) {
                self.onDeviceEvent?(event)
            }
        }
    }

    func connect() throws {
        try transport.open(
            vendorID: VOAI.vendorID,
            productIDs: VOAI.allPIDs,
            usagePage: VOAI.usagePage,
            usage: nil)
        isConnected = true
    }

    func disconnect() {
        transport.close()
        isConnected = false
        lastParams = nil
    }

    /// Translate the frame's semantic per-LED specs into thread lighting
    /// params; send only when something actually changed.
    func apply(_ frame: EffectFrame) {
        guard isConnected else { return }
        var params: [VOAI.ThreadParam] = []
        for slot in VOAI.ledIndexForAgentSlot.indices {
            let led = VOAI.ledIndexForAgentSlot[slot]
            guard let spec = frame.perLEDSpecs[led] else { continue }
            let (effect, speed) = VOAI.effectParams(for: spec.kind)
            var brightness = Double(spec.color.v) / 255.0
            if case .fadeOut = spec.kind, led < frame.perLED.count {
                // Firmware has no fade effect: ride the host-rendered value,
                // quantized so the fade is ~16 messages, not 900.
                brightness = (Double(frame.perLED[led].v) / 255.0 * 16).rounded() / 16
            }
            params.append(VOAI.ThreadParam(
                id: slot,
                c: VOAI.packedRGB(spec.color),
                b: brightness,
                e: effect.rawValue,
                s: speed,
                // Always explicit: these latch on the device, and a leftover
                // sk:1 washes the whole keys zone with a single thread colour.
                sk: 0,
                sa: 0))
        }
        guard params != lastParams else { return }
        lastParams = params
        do {
            requestID += 1
            let message = try VOAI.threadStatusRequest(id: requestID, params: params)
            for report in VOAI.frames(channel: VOAI.channelRPC, message: message) {
                try transport.write(report)
            }
        } catch {
            // Dropped frame; next state change retries.
        }
    }

    func sendRaw(_ report: [UInt8]) throws {
        try transport.write(report)
    }

    // MARK: - Underglow

    private var lastAmbient: VOAI.ZoneParam?

    /// Drives the perimeter ring through `v.oai.rgbcfg`.
    ///
    /// Deliberately not `lights.preview`: once the layer's keys are bound to
    /// `KV_OAI_AG*` the firmware runs in OAI mode and ignores preview calls
    /// outright — they still answer, they just do nothing.
    ///
    /// The `keys` zone is sent off so it can't wash out the per-key agent
    /// colours that `thstatus` paints.
    func setUnderglow(_ ambient: VOAI.ZoneParam) {
        guard isConnected, ambient != lastAmbient else { return }
        lastAmbient = ambient
        do {
            requestID += 1
            let message = try VOAI.rgbConfigRequest(id: requestID, ambient: ambient, keys: .off)
            for report in VOAI.frames(channel: VOAI.channelRPC, message: message) {
                try transport.write(report)
            }
        } catch {
            lastAmbient = nil   // let the next state change retry
        }
    }

    // MARK: - Request/response

    enum RPCError: Error, LocalizedError {
        case notConnected
        case device(String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .notConnected: "keyboard not connected"
            case .device(let message): "device refused the call: \(message)"
            case .malformedResponse: "could not parse the device's reply"
            }
        }
    }

    /// Completes a pending call if `message` is a response. Returns true when
    /// the message was consumed.
    private func completePending(_ message: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              let id = object["id"] as? Int,
              let handler = pending.removeValue(forKey: id)
        else { return false }
        if let error = object["error"] as? [String: Any] {
            let text = (error["message"] as? String) ?? "unknown error"
            handler(.failure(RPCError.device(text)))
        } else {
            handler(.success(object["result"]))
        }
        return true
    }

    private func call(_ body: (Int) throws -> Data,
                      completion: @escaping (Result<Any?, Error>) -> Void) {
        guard isConnected else { return completion(.failure(RPCError.notConnected)) }
        // Ids must stay under 1000 or the firmware ignores the request.
        callID = (callID + 1) % 1000
        let id = callID
        do {
            let message = try body(id)
            pending[id] = completion
            for report in VOAI.frames(channel: VOAI.channelRPC, message: message) {
                try transport.write(report)
            }
        } catch {
            pending.removeValue(forKey: id)
            completion(.failure(error))
        }
    }

    // MARK: - Agent keymap

    /// Binds the six agent keys to `KV_OAI_AG00…AG05` on the **active** layer.
    ///
    /// This is the precondition for per-key lighting: without it the firmware
    /// answers `{"ok":1}` to every thstatus call and lights nothing, so the
    /// failure is invisible from the host side. Idempotent — reports `false`
    /// when the keymap was already correct.
    ///
    /// Bound keys stop sending keystrokes; they report as
    /// `{"m":"v.oai.hid","p":{"k":"AG01","act":1}}` instead.
    func ensureAgentKeymap(completion: @escaping (Result<Bool, Error>) -> Void) {
        // Which layer is live? Bindings on any other layer do nothing, and the
        // pad does not report the mismatch.
        call({ try VOAI.deviceStatusRequest(id: $0) }) { [weak self] status in
            guard let self else { return }
            // `layer_index` is 1-based; fall back to the first layer.
            let layer = ((try? status.get()) as? [String: Any])
                .flatMap { $0["layer_index"] as? Int }
                .map { max(0, $0 - 1) } ?? 0
            self.writeAgentKeymap(activeLayer: layer, completion: completion)
        }
    }

    private func writeAgentKeymap(activeLayer: Int,
                                  completion: @escaping (Result<Bool, Error>) -> Void) {
        call({ try VOAI.fsReadRequest(id: $0, file: VOAIDevice.keymapFile) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let payload):
                guard let config = VOAIDevice.keymapConfig(from: payload) else {
                    return completion(.failure(RPCError.malformedResponse))
                }
                guard let updated = VOAIDevice.applyingAgentKeycodes(to: config, layerIndex: activeLayer) else {
                    return completion(.success(false))   // already bound
                }
                guard let encoded = try? JSONSerialization.data(withJSONObject: updated),
                      let text = String(data: encoded, encoding: .utf8) else {
                    return completion(.failure(RPCError.malformedResponse))
                }
                self.call({ try VOAI.fsWriteRequest(id: $0, file: VOAIDevice.keymapFile, data: text) }) { write in
                    completion(write.map { _ in true })
                }
            }
        }
    }

    static let keymapFile = "keymap.json"

    /// `fs.read` returns the document wrapped as `{"data": "<json string>"}`.
    static func keymapConfig(from payload: Any?) -> [String: Any]? {
        if let object = payload as? [String: Any] {
            if let text = object["data"] as? String,
               let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                return parsed
            }
            if object["profiles"] != nil { return object }
        }
        return nil
    }

    /// Returns the config with agent keycodes bound, or nil when already bound.
    /// Rows are [2, 4, 4, 3]; the agent keys are rows 0 and 1.
    static func applyingAgentKeycodes(to config: [String: Any], layerIndex: Int = 0) -> [String: Any]? {
        var config = config
        guard var profiles = config["profiles"] as? [[String: Any]], !profiles.isEmpty else { return nil }
        let profileIndex = min(config["activeProfileId"] as? Int ?? 0, profiles.count - 1)
        var profile = profiles[profileIndex]
        guard var layers = profile["layers"] as? [[String: Any]], !layers.isEmpty else { return nil }
        let target = min(max(layerIndex, 0), layers.count - 1)
        var layer = layers[target]
        guard var layout = layer["layout"] as? [String: Any],
              var keymap = layout["keymap"] as? [[String]], keymap.count >= 2 else { return nil }

        // A layer carrying its own `lights` block runs firmware-side lighting
        // and ignores every host call — rgbcfg included. Clearing it hands
        // control back to us and restores the stock rainbow as the baseline.
        let hadLights = !(layer["lights"] is NSNull) && layer["lights"] != nil

        var desired = keymap
        for (row, position, slots) in VOAI.agentRows {
            guard desired.indices.contains(row) else { continue }
            for (offset, slot) in slots.enumerated() {
                let column = position + offset
                guard desired[row].indices.contains(column) else { continue }
                desired[row][column] = VOAI.agentKeycodes[slot]
            }
        }
        // The dial ships on media keys (volume). Point it at plain F18–F20 so
        // it drives MegaMicro's dial gestures instead of the system volume.
        // The encoder can only emit a bare keycode — no modifier chords — and
        // macOS delivers nothing above F20, which rules out the higher F-keys.
        let encoders = layout["encoders"] as? [[String]] ?? []
        let wantEncoders = [[VOAI.dialClockwise, VOAI.dialCounterclockwise, VOAI.dialPress]]
        let encodersChanged = encoders != wantEncoders

        if desired == keymap, !hadLights, !encodersChanged { return nil }
        keymap = desired

        layout["keymap"] = keymap
        layout["encoders"] = wantEncoders
        layer["layout"] = layout
        layer["lights"] = NSNull()
        layers[target] = layer
        profile["layers"] = layers
        profiles[profileIndex] = profile
        config["profiles"] = profiles
        return config
    }
}
