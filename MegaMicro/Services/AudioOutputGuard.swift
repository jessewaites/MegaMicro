import CoreAudio
import Foundation

/// Keeps audio output where the user wants it when the mic gets plugged in.
///
/// macOS reassigns the default *output* to whatever was just connected. A USB
/// audio dongle exposes an output as well as an input, and the Mac's own 3.5 mm
/// jack is output-first — either way, plugging the FX-MIC in can silently move
/// system audio off the speakers. This watches the default output and puts it
/// back.
///
/// It never touches the default *input*: `AudioInputService` opens the mic by
/// device id, so the mic never needs to be the system microphone at all.
@MainActor
final class AudioOutputGuard {
    struct Output: Identifiable, Hashable, Sendable {
        var id: String          // CoreAudio device UID
        var name: String
        var deviceID: AudioDeviceID
    }

    /// Fired for each correction, so the user can see the guard working in the
    /// log rather than having to trust it.
    var onCorrection: ((_ from: String, _ to: String) -> Void)?
    /// Fired when the guard stands down after thrashing (see `correctionBudget`).
    var onGaveUp: ((_ reason: String) -> Void)?

    private(set) var isArmed = false
    /// UID of the output to hold. Nil means "whatever was default when armed".
    private(set) var preferredUID: String?

    /// A correction that gets immediately undone means something else is
    /// fighting us — another app, or a device that re-announces itself. Rather
    /// than trade writes forever, stand down and say so.
    private static let correctionBudget = 3
    private static let budgetWindow: TimeInterval = 5
    private var recentCorrections: [Date] = []

    private var listener: AudioObjectPropertyListenerBlock?

    /// Returned fresh each time rather than held as a `static var`: CoreAudio
    /// takes the address `inout`, and a shared mutable static can't be handed to
    /// it from `deinit` (which is nonisolated) as well as from the main actor.
    nonisolated private static func defaultOutputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: Enumeration

    static func outputs() -> [Output] {
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

        return ids.compactMap { id in
            guard outputChannelCount(id) > 0,
                  let uid = AudioInputService.stringProperty(
                    id, kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal) else { return nil }
            let name = AudioInputService.stringProperty(
                id, kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal) ?? "Unknown output"
            return Output(id: uid, name: name, deviceID: id)
        }
    }

    private static func outputChannelCount(_ device: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
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

    static func currentDefaultOutput() -> Output? {
        var addr = defaultOutputAddress()
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            0, nil, &size, &device) == noErr, device != 0 else { return nil }
        guard let uid = AudioInputService.stringProperty(
            device, kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal) else { return nil }
        let name = AudioInputService.stringProperty(
            device, kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal) ?? "Unknown output"
        return Output(id: uid, name: name, deviceID: device)
    }

    // MARK: Arming

    /// Start holding output on `uid`, or on whatever is default right now if
    /// nil. Safe to call repeatedly; only the preference changes.
    func arm(preferring uid: String?) {
        preferredUID = uid ?? Self.currentDefaultOutput()?.id
        recentCorrections.removeAll()
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultOutputChanged() }
        }
        var addr = Self.defaultOutputAddress()
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            DispatchQueue.main, block) == noErr else { return }
        listener = block
        isArmed = true
    }

    func disarm() {
        guard let block = listener else {
            isArmed = false
            return
        }
        var addr = Self.defaultOutputAddress()
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            DispatchQueue.main, block)
        listener = nil
        isArmed = false
        recentCorrections.removeAll()
    }

    /// Change what we're holding to, without re-arming.
    func setPreferred(_ uid: String?) {
        preferredUID = uid
        recentCorrections.removeAll()
    }

    // MARK: The correction

    private func defaultOutputChanged() {
        guard isArmed, let preferredUID else { return }
        guard let current = Self.currentDefaultOutput() else { return }
        guard current.id != preferredUID else {
            // Back where it belongs — whether we did that or the user did.
            recentCorrections.removeAll()
            return
        }
        guard let wanted = Self.outputs().first(where: { $0.id == preferredUID }) else {
            // The preferred device is gone (undocked, unplugged). Leaving macOS
            // where it landed is the right call — forcing output at a device
            // that isn't there would be worse than the reassignment.
            return
        }

        let now = Date()
        recentCorrections = recentCorrections.filter { now.timeIntervalSince($0) < Self.budgetWindow }
        guard recentCorrections.count < Self.correctionBudget else {
            disarm()
            onGaveUp?("output kept moving back to \(current.name) — guard stood down so it isn't fighting another app")
            return
        }
        recentCorrections.append(now)

        var addr = Self.defaultOutputAddress()
        var device = wanted.deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        guard status == noErr else {
            onGaveUp?("could not move output back to \(wanted.name) (\(String(format: "0x%08X", status)))")
            return
        }
        onCorrection?(current.name, wanted.name)
    }

    deinit {
        guard let block = listener else { return }
        var addr = Self.defaultOutputAddress()
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            DispatchQueue.main, block)
    }
}
