import Foundation
import MLXLMCommon

/// Manages the on-device HuggingFace model cache.
///
/// Models are downloaded by MLXInferenceService on first use. This manager
/// provides cache introspection, storage pre-flight checks, and eviction.
/// It does not initiate downloads directly — trigger those through MLXInferenceService.selectModel.
///
/// Cache location (sandboxed): Library/Caches/huggingface/hub/models--{org}--{name}/
@MainActor
final class ModelDownloadManager {
    static let shared = ModelDownloadManager()

    private let hubCacheDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("huggingface/hub", isDirectory: true)
    }()

    private init() {}

    // MARK: - Cache discovery

    /// HuggingFace model IDs currently cached on disk.
    func cachedModelIDs() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: hubCacheDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents
            .filter { $0.lastPathComponent.hasPrefix("models--") }
            .map { Self.directoryNameToModelID($0.lastPathComponent) }
    }

    /// Total bytes consumed by a cached model's directory, or nil if not cached.
    func cachedSize(modelID: String) -> Int64? {
        let dir = hubCacheDir.appendingPathComponent(Self.modelIDToDirectoryName(modelID))
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return directorySize(dir)
    }

    // MARK: - Eviction

    /// Removes a model from the HuggingFace cache. MLXModelLoader state is NOT cleared here —
    /// call MLXInferenceService.dropSession() first if the model is currently loaded.
    func evict(modelID: String) throws {
        let dir = hubCacheDir.appendingPathComponent(Self.modelIDToDirectoryName(modelID))
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    // MARK: - Storage pre-flight

    /// Estimated download size in bytes for a model based on its ID.
    /// Uses a size table — accurate enough for pre-flight checks, not for billing.
    func estimatedDownloadSize(modelID: String) -> Int64 {
        let id = modelID.lowercased()
        switch true {
        case id.contains("0.5b"):  return 350_000_000
        case id.contains("1.5b"):  return 950_000_000
        case id.contains("3b"):    return 1_900_000_000
        case id.contains("4b"):    return 2_500_000_000
        case id.contains("7b"):    return 4_500_000_000
        case id.contains("8b"):    return 5_000_000_000
        case id.contains("14b"):   return 9_000_000_000
        case id.contains("32b"):   return 20_000_000_000
        default:                   return 2_000_000_000
        }
    }

    /// Returns true if the device has enough storage to download the model.
    /// Uses a 1.2× safety margin over the estimated size.
    func hasStorageForDownload(modelID: String) -> Bool {
        let needed = Int64(Double(estimatedDownloadSize(modelID: modelID)) * 1.2)
        return DeviceToolEntry.availableStorageBytes() >= needed
    }

    // MARK: - Helpers

    private static func modelIDToDirectoryName(_ modelID: String) -> String {
        "models--" + modelID.replacingOccurrences(of: "/", with: "--")
    }

    private static func directoryNameToModelID(_ name: String) -> String {
        name.replacingOccurrences(of: "models--", with: "")
            .replacingOccurrences(of: "--", with: "/")
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return enumerator.compactMap { item -> Int64? in
            guard let fileURL = item as? URL,
                  let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else { return nil }
            return Int64(size)
        }.reduce(0, +)
    }
}

// Expose the storage check used by ModelDownloadManager to DeviceTools without
// duplicating the implementation. DeviceTools already defines this as a static method.
private typealias DeviceToolEntry = AgentToolEntry
