import Foundation

/// Hardware diagnostics for the day the keyboard arrives. Answers, in order:
/// 1. What HID interfaces does the device expose? (Is there a 0xFF60/0x61
///    raw interface at all — i.e. is the Codex Micro VIA-capable?)
/// 2. Does it answer the VIA protocol-version handshake?
/// 3. Does a test color write actually change the LEDs?
/// The report is copyable text; if step 1 or 2 fails, it becomes the input
/// for reverse-engineering via a Windows Wireshark/USBPcap capture of the
/// Work Louder Input app.
@MainActor
final class ProbeService {
    struct Report {
        var lines: [String] = []
        var foundRawInterface = false
        var viaProtocolVersion: Int?

        var text: String { lines.joined(separator: "\n") }
    }

    func run(testWrite: Bool) async -> Report {
        var report = Report()
        func log(_ line: String) { report.lines.append(line) }

        log("MegaMicro hardware probe — \(Date().formatted())")
        log("")

        // Step 0: the current-generation hardware (Codex Micro / Creator
        // Micro 2) — an ESP32 board speaking the v.oai JSON-RPC protocol.
        let modern = HIDTransport.enumerateInterfaces(vendorID: VOAI.vendorID)
            .filter { VOAI.allPIDs.contains($0.productID) }
        if !modern.isEmpty {
            for iface in modern {
                let name = VOAI.productName(forPID: iface.productID) ?? "Work Louder device"
                log("✓ Found \(name) (PID \(String(format: "0x%04X", iface.productID)), usage page \(String(format: "0x%04X", iface.usagePage))).")
            }
            log("This keyboard speaks the new-generation protocol MegaMicro supports.")
            log("")
            log("Per-key lighting needs two things beyond a matching device:")
            log("• Firmware new enough to answer these calls — v0.1.40 does not.")
            log("  Update with the Work Louder Input app if lighting stays dark.")
            log("• The six agent keys bound to KV_OAI_AG00…AG05 on the ACTIVE layer.")
            log("  MegaMicro writes those bindings when it connects. They stop")
            log("  sending keystrokes and report to MegaMicro instead.")
            log("")
            log("Nothing here proves the keyboard answers — the probe only reads")
            log("what the USB layer advertises. The firmware returns “ok” to")
            log("lighting calls even when it cannot light anything, so the real")
            log("test is visual.")
            log("→ Use “Connect Keyboard (Go Live)” below, then watch the keys.")
            report.foundRawInterface = true
            return report
        }

        // Step 1: fall back to the original Creator Micro 1 (QMK/VIA).
        let interfaces = HIDTransport.enumerateInterfaces(vendorID: HIDTransport.workLouderVendorID)
        if interfaces.isEmpty {
            log("No Work Louder keyboard found (checked both the current 0x303A family and the original 0x574C family).")
            log("→ Plug the keyboard in via USB-C (not Bluetooth) and re-run.")
            log("→ If it is plugged in, enumerating ALL vendors:")
            let all = HIDTransport.enumerateInterfaces(vendorID: nil)
                .filter { $0.product.localizedCaseInsensitiveContains("micro") ||
                          $0.product.localizedCaseInsensitiveContains("work") ||
                          $0.product.localizedCaseInsensitiveContains("codex") }
            if all.isEmpty {
                log("   (nothing with 'micro'/'work'/'codex' in its product name either)")
            }
            for iface in all {
                log("   \(format(iface))")
            }
            return report
        }

        log("Work Louder interfaces (VID 0x574C):")
        for iface in interfaces {
            log("  \(format(iface))")
        }
        report.foundRawInterface = interfaces.contains {
            $0.usagePage == HIDTransport.rawUsagePage && $0.usage == HIDTransport.rawUsage
        }
        log("")
        log(report.foundRawInterface
            ? "✓ Raw QMK/VIA interface (usage page 0xFF60, usage 0x61) present."
            : "✗ No 0xFF60/0x61 raw interface — firmware is likely NOT VIA. Next step: USB capture of the Input app on Windows (Wireshark + USBPcap) while changing LED colors.")
        guard report.foundRawInterface else { return report }

        // Step 2: VIA handshake.
        let transport = HIDTransport()
        var responseBytes: [UInt8]?
        transport.onInputReport = { bytes in
            if bytes.first == VIAHIDDevice.Command.getProtocolVersion {
                responseBytes = bytes
            }
        }
        do {
            try transport.open(vendorID: HIDTransport.workLouderVendorID, productID: nil)
            try transport.write([VIAHIDDevice.Command.getProtocolVersion])
            try? await Task.sleep(for: .milliseconds(300))
            if let bytes = responseBytes, bytes.count >= 3 {
                let version = Int(bytes[1]) << 8 | Int(bytes[2])
                report.viaProtocolVersion = version
                log("✓ VIA handshake ok — protocol version \(version).")
            } else {
                log("✗ No handshake response within 300 ms. Interface exists but VIA may be disabled; try closing the Work Louder Input app / VIA web tabs first.")
            }

            // Step 3: visible test write.
            if testWrite, report.viaProtocolVersion != nil {
                for channel in [VIAHIDDevice.Channel.rgbMatrix, VIAHIDDevice.Channel.rgblight] {
                    try transport.write([VIAHIDDevice.Command.customSetValue, channel, VIAHIDDevice.Value.effect, VIAHIDDevice.effectSolid])
                    try transport.write([VIAHIDDevice.Command.customSetValue, channel, VIAHIDDevice.Value.color, 0, 255])
                    try transport.write([VIAHIDDevice.Command.customSetValue, channel, VIAHIDDevice.Value.brightness, 150])
                }
                log("→ Sent solid RED at full brightness. Is the board red? Then the whole pipeline works.")
            }
        } catch {
            log("✗ Open/write failed: \(error.localizedDescription)")
        }
        transport.close()
        return report
    }

    private func format(_ iface: HIDTransport.InterfaceInfo) -> String {
        String(format: "PID 0x%04X  usagePage 0x%04X  usage 0x%02X  %@  [%@]",
               iface.productID, iface.usagePage, iface.usage, iface.transport, iface.product)
    }
}
