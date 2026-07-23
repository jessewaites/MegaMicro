import AppKit
import Darwin
import Foundation

/// Safely prepares an editable Work Louder Input layer by copying the live
/// protected Codex layout in Input's own local database. Input remains
/// responsible for synchronizing that layout to the keyboard.
struct WorkLouderLayerManager {
    struct Layer: Identifiable, Equatable {
        let id: Int
        let name: String
        let color: String?
        let isCodexSource: Bool
    }

    struct Inspection: Equatable {
        let deviceName: String
        let deviceID: String
        let profileName: String
        let profileID: String
        let source: Layer
        let targets: [Layer]
    }

    struct CloneResult {
        let inspection: Inspection
        let target: Layer
        let fullBackupURL: URL
        let layoutBackupURL: URL
    }

    struct RestoreResult {
        let safetyBackupURL: URL
    }

    enum ManagerError: LocalizedError {
        case fileMissing
        case inputRunning
        case invalidJSON
        case devicesCollectionAmbiguous(Int)
        case codexDeviceAmbiguous(Int)
        case activeProfileMissing
        case sourceLayerAmbiguous(Int)
        case targetLayerMissing(Int)
        case targetIsSource
        case invalidLayer(String)
        case backupFailed
        case validationFailed(String)
        case replacementFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .fileMissing:
                "Work Louder Input's input_storage.json was not found. Open Input, connect the Codex Micro, let it finish retrieving the configuration, then fully quit Input."
            case .inputRunning:
                "Work Louder Input is still running. Use input → Quit input before inspecting or changing its database."
            case .invalidJSON:
                "Input's configuration is not valid JSON."
            case .devicesCollectionAmbiguous(let count):
                "Expected exactly one “devices” collection, but found \(count). Nothing was changed."
            case .codexDeviceAmbiguous(let count):
                "Expected exactly one Codex Micro device, but found \(count). Nothing was changed."
            case .activeProfileMissing:
                "The device's active profile could not be identified unambiguously. Nothing was changed."
            case .sourceLayerAmbiguous(let count):
                "Expected exactly one layer containing KV_OAI_AG00, but found \(count). Nothing was changed."
            case .targetLayerMissing(let id):
                "Layer \(id + 1) was not found in the same device profile. Nothing was changed."
            case .targetIsSource:
                "The protected Codex source layer cannot be overwritten."
            case .invalidLayer(let reason):
                "A layer has an unsupported structure (\(reason)). Nothing was changed."
            case .backupFailed:
                "The required backups could not be created and validated. Nothing was changed."
            case .validationFailed(let reason):
                "Safety validation failed: \(reason). Nothing was changed."
            case .replacementFailed(let code):
                "The atomic file replacement failed (errno \(code)). The original file and backups were preserved."
            }
        }
    }

    let storageURL: URL
    let backupDirectoryURL: URL

    init(
        storageURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/input/input_storage.json"),
        backupDirectoryURL: URL? = nil
    ) {
        self.storageURL = storageURL
        self.backupDirectoryURL = backupDirectoryURL
            ?? storageURL.deletingLastPathComponent().appendingPathComponent("MegaMicro Layer Backups")
    }

    static var isInputRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            let name = app.localizedName?.lowercased() ?? ""
            let bundle = app.bundleIdentifier?.lowercased() ?? ""
            return name == "input"
                || bundle.contains("worklouder") && (name.contains("input") || bundle.contains("input"))
        }
    }

    func inspect(requireInputQuit: Bool = true) throws -> Inspection {
        if requireInputQuit, Self.isInputRunning { throw ManagerError.inputRunning }
        let root = try loadRoot()
        return try locate(in: root).inspection
    }

    func cloneCodexLayout(to targetLayerID: Int, requireInputQuit: Bool = true) throws -> CloneResult {
        if requireInputQuit, Self.isInputRunning { throw ManagerError.inputRunning }
        let originalData = try loadData()
        let originalRoot = try parse(originalData)
        let located = try locate(in: originalRoot)
        guard targetLayerID != located.sourceLayerID else { throw ManagerError.targetIsSource }
        guard let target = located.inspection.targets.first(where: { $0.id == targetLayerID }) else {
            throw ManagerError.targetLayerMissing(targetLayerID)
        }

        let timestamp = Self.timestamp()
        try PrivateFileStore.ensureDirectory(backupDirectoryURL)
        let fullBackup = backupDirectoryURL.appendingPathComponent("input_storage-\(timestamp).json")
        let layoutBackup = backupDirectoryURL.appendingPathComponent(
            "layer-\(targetLayerID)-layout-\(timestamp).json")

        do {
            try PrivateFileStore.backup(storageURL, to: fullBackup)
            let targetLayout = try layout(in: originalRoot, at: located, layerID: targetLayerID)
            let layoutData = try JSONSerialization.data(
                withJSONObject: targetLayout, options: [.prettyPrinted, .sortedKeys])
            try PrivateFileStore.write(layoutData, to: layoutBackup)
            _ = try parse(Data(contentsOf: fullBackup))
            _ = try parse(Data(contentsOf: layoutBackup))
        } catch {
            throw ManagerError.backupFailed
        }

        let sourceLayout = try layout(
            in: originalRoot, at: located, layerID: located.sourceLayerID)
        let editedRoot = try replacingLayout(
            in: originalRoot, located: located, layerID: targetLayerID, with: sourceLayout)
        try validateEdit(original: originalRoot, edited: editedRoot,
                         located: located, targetLayerID: targetLayerID)
        try atomicWrite(root: editedRoot, preservingAttributesOf: storageURL)

        // Validate the bytes on disk, not merely the in-memory candidate.
        let writtenRoot = try loadRoot()
        try validateEdit(original: originalRoot, edited: writtenRoot,
                         located: located, targetLayerID: targetLayerID)
        return CloneResult(inspection: located.inspection, target: target,
                           fullBackupURL: fullBackup, layoutBackupURL: layoutBackup)
    }

    /// Roll back only the target layout, using the separate pre-change layout
    /// backup while preserving Input's newly synchronized metadata/checksums.
    func restoreLayout(
        to targetLayerID: Int, from layoutBackupURL: URL,
        requireInputQuit: Bool = true
    ) throws -> RestoreResult {
        if requireInputQuit, Self.isInputRunning { throw ManagerError.inputRunning }
        let currentData = try loadData()
        let currentRoot = try parse(currentData)
        let located = try locate(in: currentRoot)
        guard targetLayerID != located.sourceLayerID else { throw ManagerError.targetIsSource }
        let backupData = try Data(contentsOf: layoutBackupURL)
        guard let backedUpLayout = try? JSONSerialization.jsonObject(with: backupData) as? [String: Any]
        else { throw ManagerError.backupFailed }

        let timestamp = Self.timestamp()
        try PrivateFileStore.ensureDirectory(backupDirectoryURL)
        let safetyBackup = backupDirectoryURL
            .appendingPathComponent("pre-rollback-input_storage-\(timestamp).json")
        do {
            try PrivateFileStore.backup(storageURL, to: safetyBackup)
            _ = try parse(Data(contentsOf: safetyBackup))
        } catch {
            throw ManagerError.backupFailed
        }

        let restoredRoot = try replacingLayout(
            in: currentRoot, located: located, layerID: targetLayerID, with: backedUpLayout)
        try validateOnlyTargetChanged(
            original: currentRoot, edited: restoredRoot,
            located: located, targetLayerID: targetLayerID)
        try atomicWrite(root: restoredRoot, preservingAttributesOf: storageURL)
        let writtenRoot = try loadRoot()
        try validateOnlyTargetChanged(
            original: currentRoot, edited: writtenRoot,
            located: located, targetLayerID: targetLayerID)
        let writtenLayout = try layout(in: writtenRoot, at: located, layerID: targetLayerID)
        guard jsonEqual(writtenLayout, backedUpLayout) else {
            throw ManagerError.validationFailed("the restored target does not match its layout backup")
        }
        return RestoreResult(safetyBackupURL: safetyBackup)
    }

    /// Read-back check after Input has synchronized the device.
    func verifyClone(targetLayerID: Int, requireInputQuit: Bool = true) throws -> Inspection {
        let inspection = try inspect(requireInputQuit: requireInputQuit)
        let root = try loadRoot()
        let located = try locate(in: root)
        let source = try layout(in: root, at: located, layerID: located.sourceLayerID)
        let target = try layout(in: root, at: located, layerID: targetLayerID)
        guard jsonEqual(source, target) else {
            throw ManagerError.validationFailed(
                "Layer \(targetLayerID + 1) does not match the live Codex layout after read-back")
        }
        return inspection
    }

    // MARK: - JSON selection

    private struct Located {
        let inspection: Inspection
        let collectionIndex: Int
        let deviceIndex: Int
        let profileIndex: Int
        let sourceLayerID: Int
    }

    private func loadData() throws -> Data {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            throw ManagerError.fileMissing
        }
        return try Data(contentsOf: storageURL)
    }

    private func loadRoot() throws -> [String: Any] {
        try parse(loadData())
    }

    private func parse(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManagerError.invalidJSON
        }
        return root
    }

    private func locate(in root: [String: Any]) throws -> Located {
        guard let collections = root["collections"] as? [[String: Any]] else {
            throw ManagerError.devicesCollectionAmbiguous(0)
        }
        let collectionMatches = collections.indices.filter {
            collections[$0]["name"] as? String == "devices"
        }
        guard collectionMatches.count == 1 else {
            throw ManagerError.devicesCollectionAmbiguous(collectionMatches.count)
        }
        let collectionIndex = collectionMatches[0]
        guard let devices = collections[collectionIndex]["data"] as? [[String: Any]] else {
            throw ManagerError.codexDeviceAmbiguous(0)
        }
        let deviceMatches = devices.indices.filter {
            (($0 < devices.count ? devices[$0]["device"] : nil) as? [String: Any])?["deviceType"] as? String
                == "codex_micro"
        }
        guard deviceMatches.count == 1 else {
            throw ManagerError.codexDeviceAmbiguous(deviceMatches.count)
        }
        let deviceIndex = deviceMatches[0]
        let entry = devices[deviceIndex]
        guard let device = entry["device"] as? [String: Any] else {
            throw ManagerError.codexDeviceAmbiguous(0)
        }
        let profiles = (device["profiles"] as? [[String: Any]])
            ?? (entry["profiles"] as? [[String: Any]])
        let activeProfileID = stringID(device["activeProfileId"] ?? entry["activeProfileId"])
        guard let profiles, let activeProfileID else { throw ManagerError.activeProfileMissing }
        let profileMatches = profiles.indices.filter {
            stringID(profiles[$0]["id"]) == activeProfileID
        }
        guard profileMatches.count == 1 else { throw ManagerError.activeProfileMissing }
        let profileIndex = profileMatches[0]
        guard let layers = profiles[profileIndex]["layers"] as? [[String: Any]] else {
            throw ManagerError.invalidLayer("missing layers array")
        }

        let markerMatches = layers.filter { layer in
            guard let layout = layer["layout"] as? [String: Any],
                  let keymap = layout["keymap"] as? [Any] else { return false }
            return flattenStrings(keymap).contains("KV_OAI_AG00")
        }
        // A previously cloned target also contains AG00. Layer id 0 is the
        // protected source on the supported schema and remains authoritative
        // for read-back. On a nonstandard schema, require a unique marker.
        let canonicalMatches = markerMatches.filter { intID($0["id"]) == 0 }
        let sourceMatches: [[String: Any]]
        if canonicalMatches.count == 1 {
            sourceMatches = canonicalMatches
        } else {
            sourceMatches = markerMatches
        }
        guard sourceMatches.count == 1 else {
            throw ManagerError.sourceLayerAmbiguous(sourceMatches.count)
        }
        let source = try layerSummary(sourceMatches[0], isSource: true)
        let allLayers = try layers.map { try layerSummary($0, isSource: false) }
        let targets = allLayers.filter { $0.id != source.id }.sorted { $0.id < $1.id }

        let inspection = Inspection(
            deviceName: (device["name"] as? String) ?? (entry["name"] as? String) ?? "Codex Micro",
            deviceID: stringID(device["id"] ?? entry["id"]) ?? "unknown",
            profileName: (profiles[profileIndex]["name"] as? String) ?? "Active Profile",
            profileID: activeProfileID,
            source: source,
            targets: targets)
        return Located(inspection: inspection, collectionIndex: collectionIndex,
                       deviceIndex: deviceIndex, profileIndex: profileIndex,
                       sourceLayerID: source.id)
    }

    private func layerSummary(_ layer: [String: Any], isSource: Bool) throws -> Layer {
        guard let id = intID(layer["id"]) else { throw ManagerError.invalidLayer("missing numeric id") }
        guard layer["layout"] is [String: Any] else {
            throw ManagerError.invalidLayer("layer \(id) has no layout object")
        }
        return Layer(id: id, name: layer["name"] as? String ?? "Layer \(id + 1)",
                     color: layer["color"] as? String, isCodexSource: isSource)
    }

    private func profiles(in root: [String: Any], at located: Located) throws -> [[String: Any]] {
        guard let collections = root["collections"] as? [[String: Any]],
              let devices = collections[located.collectionIndex]["data"] as? [[String: Any]],
              let device = devices[located.deviceIndex]["device"] as? [String: Any] else {
            throw ManagerError.validationFailed("selected device path changed")
        }
        guard let result = (device["profiles"] as? [[String: Any]])
            ?? (devices[located.deviceIndex]["profiles"] as? [[String: Any]]) else {
            throw ManagerError.validationFailed("selected profile path changed")
        }
        return result
    }

    private func layout(in root: [String: Any], at located: Located, layerID: Int) throws -> [String: Any] {
        let profiles = try profiles(in: root, at: located)
        guard let layers = profiles[located.profileIndex]["layers"] as? [[String: Any]],
              let layer = layers.first(where: { intID($0["id"]) == layerID }),
              let layout = layer["layout"] as? [String: Any] else {
            throw ManagerError.targetLayerMissing(layerID)
        }
        return layout
    }

    private func replacingLayout(
        in root: [String: Any], located: Located, layerID: Int, with newLayout: [String: Any]
    ) throws -> [String: Any] {
        var edited = root
        guard var collections = edited["collections"] as? [[String: Any]],
              var devices = collections[located.collectionIndex]["data"] as? [[String: Any]] else {
            throw ManagerError.validationFailed("devices path changed")
        }
        var entry = devices[located.deviceIndex]
        var device = entry["device"] as? [String: Any]
        var profiles = try profiles(in: root, at: located)
        var profile = profiles[located.profileIndex]
        guard var layers = profile["layers"] as? [[String: Any]],
              let targetIndex = layers.firstIndex(where: { intID($0["id"]) == layerID }) else {
            throw ManagerError.targetLayerMissing(layerID)
        }
        layers[targetIndex]["layout"] = newLayout
        profile["layers"] = layers
        profiles[located.profileIndex] = profile

        if device?["profiles"] != nil {
            device?["profiles"] = profiles
            entry["device"] = device
        } else {
            entry["profiles"] = profiles
        }
        devices[located.deviceIndex] = entry
        collections[located.collectionIndex]["data"] = devices
        edited["collections"] = collections
        return edited
    }

    private func validateEdit(
        original: [String: Any], edited: [String: Any],
        located: Located, targetLayerID: Int
    ) throws {
        let sourceBefore = try layout(in: original, at: located, layerID: located.sourceLayerID)
        let sourceAfter = try layout(in: edited, at: located, layerID: located.sourceLayerID)
        let targetAfter = try layout(in: edited, at: located, layerID: targetLayerID)
        guard jsonEqual(sourceBefore, sourceAfter) else {
            throw ManagerError.validationFailed("the protected source layer changed")
        }
        guard jsonEqual(sourceBefore, targetAfter) else {
            throw ManagerError.validationFailed("the target layout does not equal the source layout")
        }
        try validateOnlyTargetChanged(
            original: original, edited: edited,
            located: located, targetLayerID: targetLayerID)
    }

    private func validateOnlyTargetChanged(
        original: [String: Any], edited: [String: Any],
        located: Located, targetLayerID: Int
    ) throws {
        let originalWithoutTarget = try replacingLayoutWithSentinel(
            in: original, located: located, layerID: targetLayerID)
        let editedWithoutTarget = try replacingLayoutWithSentinel(
            in: edited, located: located, layerID: targetLayerID)
        guard jsonEqual(originalWithoutTarget, editedWithoutTarget) else {
            throw ManagerError.validationFailed("a value outside the target layout changed")
        }
    }

    private func replacingLayoutWithSentinel(
        in root: [String: Any], located: Located, layerID: Int
    ) throws -> [String: Any] {
        var copy = root
        guard var collections = copy["collections"] as? [[String: Any]],
              var devices = collections[located.collectionIndex]["data"] as? [[String: Any]] else {
            throw ManagerError.validationFailed("devices path changed")
        }
        var entry = devices[located.deviceIndex]
        var device = entry["device"] as? [String: Any]
        var profiles = try profiles(in: root, at: located)
        var profile = profiles[located.profileIndex]
        guard var layers = profile["layers"] as? [[String: Any]],
              let layerIndex = layers.firstIndex(where: { intID($0["id"]) == layerID }) else {
            throw ManagerError.targetLayerMissing(layerID)
        }
        layers[layerIndex]["layout"] = "__MEGAMICRO_TARGET_LAYOUT__"
        profile["layers"] = layers
        profiles[located.profileIndex] = profile
        if device?["profiles"] != nil {
            device?["profiles"] = profiles
            entry["device"] = device
        } else {
            entry["profiles"] = profiles
        }
        devices[located.deviceIndex] = entry
        collections[located.collectionIndex]["data"] = devices
        copy["collections"] = collections
        return copy
    }

    // MARK: - Atomic replacement

    private func atomicWrite(root: [String: Any], preservingAttributesOf originalURL: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        _ = try parse(data)
        let attributes = try FileManager.default.attributesOfItem(atPath: originalURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        let tempURL = originalURL.deletingLastPathComponent()
            .appendingPathComponent(".input_storage.megamicro-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try data.write(to: tempURL)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempURL.path)
        _ = try parse(Data(contentsOf: tempURL))
        guard rename(tempURL.path, originalURL.path) == 0 else {
            throw ManagerError.replacementFailed(errno)
        }
    }

    private func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        (lhs as AnyObject).isEqual(rhs)
    }

    private func stringID(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func intID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func flattenStrings(_ value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.flatMap(flattenStrings) }
        if let object = value as? [String: Any] { return object.values.flatMap(flattenStrings) }
        return []
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}
