import Foundation

/// What MegaMicro writes to the mic's own 1 MB disk ("FX MIC DISK", mounted
/// when the USB-C cable is in and the mic is on), and how to take it back.
///
/// One tweak turns the mic into a control surface: `FXMicScript` as `main.py`
/// plus the four chirp samples it plays. Plain files; removing them restores
/// the factory behaviour. The mic reads them at boot, so after writing, eject
/// the disk and power-cycle the mic.
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

    enum Tweak: CaseIterable {
        /// `main.py` plus the four chirp samples it plays. Installing also
        /// removes `config.json`, because the firmware skips `1.wav`–`4.wav`
        /// when a config is present and would play the ROM horn instead.
        case controlScript

        var files: [String] {
            switch self {
            case .controlScript: [FXMicScript.fileName] + FXMicDisk.sampleNames
            }
        }
    }

    /// Whether the disk carries the script.
    static func isApplied(_ tweak: Tweak, on volume: URL) -> Bool {
        FileManager.default.fileExists(atPath: volume.appendingPathComponent(FXMicScript.fileName).path)
    }

    static func apply(_ tweak: Tweak, on volume: URL) throws {
        for (cue, name) in sampleNames.enumerated() {
            try CueTones.wavData(for: cue).write(to: volume.appendingPathComponent(name), options: .atomic)
        }
        try Data(FXMicScript.source.utf8).write(to: volume.appendingPathComponent(FXMicScript.fileName), options: .atomic)
        for stale in [configName, "boot.py"] {
            let url = volume.appendingPathComponent(stale)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
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
