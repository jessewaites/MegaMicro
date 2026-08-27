import AppKit
import AVFoundation
import ApplicationServices
import IOKit.hid

/// Checks and requests the TCC permissions MegaMicro needs:
/// - Accessibility: create a consuming CGEventTap + post keystrokes
/// - Input Monitoring: listen-only fallback monitor (and raw HID input later)
/// - Microphone: capture from the FX-MIC's audio input
enum PermissionsService {
    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt (once per app signature) if not yet granted.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Ask, then report. `completion` can land on any thread — callers hop to
    /// the main actor themselves. Always call this *before* opening a capture
    /// device: an unpermissioned engine starts happily and delivers silence,
    /// which reads as broken hardware rather than a missing permission.
    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { completion($0) }
        default:
            // Denied or restricted: the system prompt won't show again, so the
            // only way forward is Privacy & Security.
            completion(false)
        }
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
