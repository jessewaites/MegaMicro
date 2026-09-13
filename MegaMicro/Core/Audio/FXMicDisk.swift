import Foundation

/// What MegaMicro writes to the mic's own 1 MB disk ("FX MIC DISK", mounted
/// when the USB-C cable is in and the mic is on), and how to take it back.
///
/// Two optional tweaks make the mic behave like a control surface instead of
/// an effects toy:
/// - `config.json` with four clean presets, so FX2 only changes MegaMicro's
///   page and never colours the voice.
/// - Silent `1.wav`–`4.wav`, so FX4 fires its mapping without honking.
///
/// Both are plain files; removing them restores the factory behaviour. The
/// mic reads them at boot, so after writing, eject the disk and let it
/// restart. Per the mic's readme, a config it can't start with is bypassed by
/// holding FX3 + FX4 while powering on.
enum FXMicDisk {
    static let sampleNames = ["1.wav", "2.wav", "3.wav", "4.wav"]
    static let configName = "config.json"

    /// The mounted disk, if any. The firmware's name has changed across
    /// releases; match loosely.
    static func mountedVolume() -> URL? {
        let keys: [URLResourceKey] = [.volumeNameKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                            options: [.skipHiddenVolumes]) ?? []
        return volumes.first { url in
            let name = ((try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "").lowercased()
            return name.contains("fx mic") || name.contains("fx-mic") || name.contains("tingdisk")
        }
    }

    /// Clean voice on all four effect pages. Each preset is just the SAMPLE
    /// stage FX4 triggers, with no handle or shake modulation. The clean page
    /// (position -1) has no preset and needs nothing.
    static var cleanPagesConfig: Data {
        let presets: [[String: Any]] = (0..<4).map { i in
            ["pos": i,
             "name": "PAGE \(i + 2)",
             "list": [["effect": "SAMPLE", "speed": 1.0, "pitch": 0.0, "level": 0.5]],
             "trigger": ["row": 0]]
        }
        let config: [String: Any] = [
            "name": "MegaMicro pages",
            "comment": "All four pages are clean voice, so FX2 only changes which MegaMicro page is active. Delete this file to get the factory effects back.",
            "presets": presets,
        ]
        return (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// 40 ms of 16-bit mono silence: a valid sample with nothing in it.
    static var silentSample: Data {
        let rate: UInt32 = 22_050
        let frames = 882
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(frames * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(byteCount)
        data.append(Data(count: Int(byteCount)))
        return data
    }

    enum Tweak: CaseIterable {
        case cleanPages, silentSamples

        var files: [String] {
            switch self {
            case .cleanPages: [FXMicDisk.configName]
            case .silentSamples: FXMicDisk.sampleNames
            }
        }
    }

    /// Whether the disk currently carries a tweak (any of its files present).
    static func isApplied(_ tweak: Tweak, on volume: URL) -> Bool {
        tweak.files.contains { FileManager.default.fileExists(atPath: volume.appendingPathComponent($0).path) }
    }

    static func apply(_ tweak: Tweak, on volume: URL) throws {
        switch tweak {
        case .cleanPages:
            try cleanPagesConfig.write(to: volume.appendingPathComponent(configName), options: .atomic)
        case .silentSamples:
            for name in sampleNames {
                try silentSample.write(to: volume.appendingPathComponent(name), options: .atomic)
            }
        }
        stripAppleDouble(on: volume)
    }

    static func remove(_ tweak: Tweak, on volume: URL) throws {
        for name in tweak.files {
            let url = volume.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// macOS drops `._name` metadata twins next to files on FAT volumes. The
    /// mic never asks for them; keep its tiny disk tidy.
    private static func stripAppleDouble(on volume: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: volume.path)) ?? []
        for name in names where name.hasPrefix("._") {
            try? FileManager.default.removeItem(at: volume.appendingPathComponent(name))
        }
    }
}
