import Foundation
import IOKit.hid

/// Thin IOHIDManager wrapper: enumerates HID interfaces, opens one, writes
/// 32-byte output reports, and delivers input reports. All Work Louder /
/// QMK specifics live in VIAHIDDevice; this layer is generic.
final class HIDTransport {
    struct InterfaceInfo: Identifiable, Hashable, Sendable {
        var vendorID: Int
        var productID: Int
        var product: String
        var usagePage: Int
        var usage: Int
        var transport: String
        var id: String { "\(vendorID):\(productID):\(usagePage):\(usage):\(transport)" }
    }

    static let workLouderVendorID = 0x574C
    static let rawUsagePage = 0xFF60
    static let rawUsage = 0x61

    /// Report payload size — 32 for QMK/VIA, 64 for the v.oai firmware.
    let reportSize: Int
    /// When true, `write` treats byte 0 of the report as the HID report id
    /// (numbered-report devices like the Codex Micro's 0x06). When false the
    /// whole buffer is sent with report id 0 (VIA convention).
    let usesLeadingReportID: Bool

    init(reportSize: Int = 32, usesLeadingReportID: Bool = false) {
        self.reportSize = reportSize
        self.usesLeadingReportID = usesLeadingReportID
        self.inputBuffer = [UInt8](repeating: 0, count: max(reportSize, 64))
    }

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inputBuffer: [UInt8]

    var onInputReport: (([UInt8]) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    // MARK: Enumeration (diagnostics)

    /// List every HID interface for a vendor (or all vendors when nil).
    /// This is the probe's first question: "what does this device expose?"
    static func enumerateInterfaces(vendorID: Int?) -> [InterfaceInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        if let vendorID {
            IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID] as CFDictionary)
        } else {
            IOHIDManagerSetDeviceMatching(manager, nil)
        }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }

        func intProp(_ device: IOHIDDevice, _ key: String) -> Int {
            (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0
        }
        func stringProp(_ device: IOHIDDevice, _ key: String) -> String {
            (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? ""
        }

        return devices.map { device in
            InterfaceInfo(
                vendorID: intProp(device, kIOHIDVendorIDKey),
                productID: intProp(device, kIOHIDProductIDKey),
                product: stringProp(device, kIOHIDProductKey),
                usagePage: intProp(device, kIOHIDPrimaryUsagePageKey),
                usage: intProp(device, kIOHIDPrimaryUsageKey),
                transport: stringProp(device, kIOHIDTransportKey))
        }
        .sorted { ($0.productID, $0.usagePage) < ($1.productID, $1.usagePage) }
    }

    // MARK: Connection

    /// Open the raw (0xFF60/0x61) interface of the first matching device.
    func open(vendorID: Int, productID: Int?) throws {
        try open(vendorID: vendorID,
                 productIDs: productID.map { [$0] },
                 usagePage: Self.rawUsagePage,
                 usage: Self.rawUsage)
    }

    /// General matcher: any of `productIDs` (nil = any), optional usage
    /// page/usage constraints.
    func open(vendorID: Int, productIDs: [Int]?, usagePage: Int?, usage: Int?) throws {
        close()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = (productIDs ?? [0]).map { pid in
            var entry: [String: Any] = [kIOHIDVendorIDKey: vendorID]
            if productIDs != nil { entry[kIOHIDProductIDKey] = pid }
            if let usagePage { entry[kIOHIDDeviceUsagePageKey] = usagePage }
            if let usage { entry[kIOHIDDeviceUsageKey] = usage }
            return entry
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        // IMPORTANT: open shared, never `kIOHIDOptionsTypeSeizeDevice`. This is
        // the QMK raw-HID (0xFF60) pipe that VIA-based configurators (e.g. Work
        // Louder Input) also use to push layer edits. Seizing it would lock
        // those tools out and can wedge the board's host-side binding until a
        // replug/restart — the exact failure we auto-recover from elsewhere.
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw HIDError.managerOpenFailed(openResult)
        }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw HIDError.deviceNotFound
        }

        self.manager = manager
        self.device = device

        inputBuffer.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceRegisterInputReportCallback(
                device, buffer.baseAddress!, buffer.count,
                { context, _, _, _, _, report, reportLength in
                    guard let context else { return }
                    let transport = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
                    let bytes = [UInt8](UnsafeBufferPointer(start: report, count: reportLength))
                    transport.onInputReport?(bytes)
                },
                Unmanaged.passUnretained(self).toOpaque())
        }

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let transport = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
            transport.onConnectionChange?(false)
        }, Unmanaged.passUnretained(self).toOpaque())

        onConnectionChange?(true)
    }

    func close() {
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        device = nil
    }

    var isOpen: Bool { device != nil }

    // MARK: I/O

    /// Send one output report, padded to `reportSize`. With IOKit the report
    /// ID is a separate argument — for VIA (unnumbered reports) it's 0 and
    /// the whole buffer is data; for numbered-report firmware
    /// (`usesLeadingReportID`) byte 0 is peeled off as the id.
    static func prepareOutputReport(
        _ report: [UInt8],
        reportSize: Int,
        usesLeadingReportID: Bool
    ) -> (reportID: CFIndex, payload: [UInt8]) {
        var padded = report
        if padded.count < reportSize {
            padded.append(contentsOf: [UInt8](repeating: 0, count: reportSize - padded.count))
        }
        precondition(padded.count == reportSize, "raw HID reports are exactly \(reportSize) bytes")

        guard usesLeadingReportID, let first = padded.first else {
            return (0, padded)
        }
        // HIDAPI retains nonzero report IDs in the payload; BLE requires the same shape.
        return first == 0
            ? (0, Array(padded.dropFirst()))
            : (CFIndex(first), padded)
    }

    func write(_ report: [UInt8]) throws {
        guard let device else { throw HIDError.notOpen }
        let prepared = Self.prepareOutputReport(
            report,
            reportSize: reportSize,
            usesLeadingReportID: usesLeadingReportID)
        let result = prepared.payload.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                prepared.reportID,
                buffer.baseAddress!,
                buffer.count)
        }
        guard result == kIOReturnSuccess else {
            throw HIDError.writeFailed(result)
        }
    }

    enum HIDError: Error, LocalizedError {
        case managerOpenFailed(IOReturn)
        case deviceNotFound
        case notOpen
        case writeFailed(IOReturn)

        var errorDescription: String? {
            switch self {
            case .managerOpenFailed(let code): "IOHIDManagerOpen failed (\(String(format: "0x%08X", code))) — check Input Monitoring permission"
            case .deviceNotFound: "no matching raw HID interface found"
            case .notOpen: "device not open"
            case .writeFailed(let code): "HID write failed (\(String(format: "0x%08X", code)))"
            }
        }
    }
}
