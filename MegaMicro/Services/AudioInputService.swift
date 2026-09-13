import AVFoundation
import CoreAudio
import Foundation

/// CoreAudio input enumeration and capture, bound to one specific device.
///
/// Deliberately opens the chosen device *directly* rather than reading the
/// system default input: the FX-MIC never has to become the Mac's default
/// microphone, so Zoom, Meet and everything else keep whatever the user had
/// selected. The matching half of that promise — keeping audio *output* on the
/// speakers — lives in `AudioOutputGuard`.
///
/// Everything downstream (tone detection, voice gating) wants the same shape
/// tink-agent uses: 16 kHz mono, 800-sample / 50 ms blocks. The 50 ms cadence
/// also happens to be the app's 20 Hz render tick, so level updates line up with
/// the existing frame loop for free.
final class AudioInputService {
    /// 16 kHz mono is plenty for both speech and cue tones up to ~7.2 kHz, and
    /// keeps the Goertzel bins cheap.
    static let sampleRate: Double = 16_000
    /// 800 frames @ 16 kHz = 50 ms.
    static let blockFrames = 800

    struct Input: Identifiable, Hashable, Sendable {
        /// CoreAudio device UID — stable across unplug/replug, unlike the
        /// numeric AudioDeviceID, which is why it's what we persist.
        var id: String
        var name: String
        var deviceID: AudioDeviceID
        var channels: Int
        var sampleRate: Double

        var detail: String {
            "\(channels) ch · \(Int(sampleRate)) Hz"
        }
    }

    // MARK: Enumeration

    /// Every device that actually has input channels, in CoreAudio's order.
    static func inputs() -> [Input] {
        deviceIDs().compactMap { id in
            let channels = inputChannelCount(id)
            guard channels > 0 else { return nil }
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal) else { return nil }
            let name = stringProperty(id, kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal) ?? "Unknown input"
            guard !isPrivateAggregate(id, name: name) else { return nil }
            return Input(id: uid, name: name, deviceID: id,
                         channels: channels, sampleRate: nominalSampleRate(id))
        }
    }

    /// The moment an `AVAudioEngine` binds to a device, CoreAudio publishes a
    /// process-private aggregate named `CADefaultDeviceAggregate-<pid>-<n>`
    /// that wraps it. It's this app looking at itself — listing it would offer
    /// the user a "device" that vanishes when they stop listening.
    private static func isPrivateAggregate(_ device: AudioDeviceID, name: String) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeAggregate else { return false }
        if name.hasPrefix("CADefaultDeviceAggregate") { return true }
        // A user-built aggregate (Audio MIDI Setup) is public and stays; only
        // the ones flagged private by their owner are hidden.
        var compositionAddr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var composition: CFDictionary? = nil
        var compositionSize = UInt32(MemoryLayout<CFDictionary?>.size)
        let status = withUnsafeMutablePointer(to: &composition) {
            AudioObjectGetPropertyData(device, &compositionAddr, 0, nil, &compositionSize, $0)
        }
        guard status == noErr, let dict = composition as? [String: Any] else { return false }
        return (dict[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue ?? false
    }

    /// Resolve a persisted choice. Prefers the UID (survives replug); falls back
    /// to a case-insensitive name match the way tink-agent does, so a device
    /// that came back with a new UID is still found.
    static func resolve(uid: String?, name: String?) -> Input? {
        let available = inputs()
        if let uid, let hit = available.first(where: { $0.id == uid }) { return hit }
        if let name, !name.isEmpty {
            let needle = name.lowercased()
            if let hit = available.first(where: { $0.name.lowercased().contains(needle) }) { return hit }
        }
        return nil
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, buffer) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalSampleRate(_ device: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    static func stringProperty(_ device: AudioDeviceID,
                               _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    // MARK: Hot-plug

    /// Fires whenever the set of audio devices changes. CoreAudio pushes this,
    /// so unlike the keyboard's HID path there's no backoff polling to write.
    var onDevicesChanged: (() -> Void)?

    private var deviceListListener: AudioObjectPropertyListenerBlock?

    func startWatchingDevices() {
        guard deviceListListener == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDevicesChanged?()
        }
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block) == noErr else { return }
        deviceListListener = block
    }

    func stopWatchingDevices() {
        guard let block = deviceListListener else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        deviceListListener = nil
    }

    // MARK: Capture

    /// One 800-sample / 50 ms block of 16 kHz mono, delivered on the audio
    /// thread. Keep whatever runs here fast — detection is fine, transcription
    /// is not.
    var onBlock: (([Float], Float, Float) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pending: [Float] = []
    private(set) var isRunning = false
    private(set) var currentInput: Input?

    enum AudioError: Error, LocalizedError {
        case noAudioUnit
        case deviceBindFailed(OSStatus)
        case unsupportedFormat
        case converterFailed

        var errorDescription: String? {
            switch self {
            case .noAudioUnit: "the input node has no audio unit"
            case .deviceBindFailed(let code): "could not bind to that input (\(String(format: "0x%08X", code)))"
            case .unsupportedFormat: "that input reported a format we can't read"
            case .converterFailed: "could not build a 16 kHz mono converter for that input"
            }
        }
    }

    /// Bind to `input` and start capturing. The AUHAL device must be set before
    /// the input format is read — the node reports the *previous* device's
    /// format otherwise, and the converter would be built for the wrong rate.
    func start(on input: Input) throws {
        stop()

        let node = engine.inputNode
        guard let unit = node.audioUnit else { throw AudioError.noAudioUnit }
        var deviceID = input.deviceID
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw AudioError.deviceBindFailed(status) }

        let inputFormat = node.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.unsupportedFormat
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.sampleRate,
                                         channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw AudioError.converterFailed
        }
        self.converter = converter

        node.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.ingest(buffer, to: target)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        currentInput = input
    }

    func stop() {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        isRunning = false
        currentInput = nil
        converter = nil
        pending.removeAll(keepingCapacity: true)
    }

    /// Downmix + resample to 16 kHz mono, then emit whole 50 ms blocks. A
    /// partial block is carried over rather than padded — padding would inject
    /// silence into the middle of a tone burst and dent its purity.
    private func ingest(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0,
              let samples = out.floatChannelData?[0] else { return }

        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))

        while pending.count >= Self.blockFrames {
            let block = Array(pending.prefix(Self.blockFrames))
            pending.removeFirst(Self.blockFrames)
            var sumSquares: Float = 0
            var peak: Float = 0
            for sample in block {
                sumSquares += sample * sample
                peak = max(peak, abs(sample))
            }
            let rms = (sumSquares / Float(Self.blockFrames)).squareRoot()
            onBlock?(block, rms, peak)
        }
    }

    deinit {
        stopWatchingDevices()
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}
