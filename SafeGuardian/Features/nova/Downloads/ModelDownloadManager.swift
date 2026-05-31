import Foundation
import HuggingFace
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
        #if os(macOS)
        // The HuggingFace Swift library writes to ~/.cache/huggingface/hub on macOS,
        // following the XDG convention used by the Python HuggingFace toolchain.
        // Library/Caches is only correct for sandboxed iOS targets.
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        #else
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("huggingface/hub", isDirectory: true)
        #endif
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

    /// Fetches the real total file size for a model from the HuggingFace Hub API.
    /// Falls back to the pattern estimate if offline or the model has no size metadata.
    /// - Parameter modelID: HuggingFace model ID, e.g. "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
    func remoteSize(modelID: String) async -> Int64 {
        let parts = modelID.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return patternEstimate(modelID: modelID) }
        let repoID = Repo.ID(namespace: String(parts[0]), name: String(parts[1]))
        do {
            let model = try await HubClient.default.getModel(repoID, filesMetadata: true)
            let total = model.siblings?.compactMap { $0.size }.reduce(0, +) ?? 0
            return total > 0 ? Int64(total) : patternEstimate(modelID: modelID)
        } catch {
            return patternEstimate(modelID: modelID)
        }
    }

    /// Quick offline size estimate based on parameter count pattern in the model ID.
    /// Used as the fallback when the Hub API is unreachable.
    func patternEstimate(modelID: String) -> Int64 {
        let id = modelID.lowercased()
            .replacingOccurrences(of: "4bit", with: "")
            .replacingOccurrences(of: "8bit", with: "")
            .replacingOccurrences(of: "3bit", with: "")
            .replacingOccurrences(of: "2bit", with: "")
            .replacingOccurrences(of: "6bit", with: "")
        switch true {
        case id.contains("0.5b"):  return 350_000_000
        case id.contains("1.5b"):  return 950_000_000
        case id.contains("2b"):    return 1_300_000_000
        case id.contains("72b"):   return 45_000_000_000
        case id.contains("32b"):   return 20_000_000_000
        case id.contains("14b"):   return 9_000_000_000
        case id.contains("8b"):    return 5_000_000_000
        case id.contains("7b"):    return 4_500_000_000
        case id.contains("4b"):    return 2_500_000_000
        case id.contains("3b"):    return 1_900_000_000
        case id.contains("1b"):    return 700_000_000
        default:                   return 2_000_000_000
        }
    }

    /// Returns true if the device has enough storage for the model.
    /// Uses the pattern estimate (offline-safe) with a 1.2× safety margin.
    /// Call remoteSize(modelID:) first if you want the precise value.
    func hasStorageForDownload(modelID: String) -> Bool {
        let needed = Int64(Double(patternEstimate(modelID: modelID)) * 1.2)
        return DeviceMetrics.availableStorageBytes() >= needed
    }

    // MARK: - Model config

    /// Reads max_position_embeddings from the model's cached config.json.
    /// Returns nil if the model is not cached or the field is absent.
    func contextWindowSize(modelID: String) -> Int? {
        let modelDir = hubCacheDir.appendingPathComponent(Self.modelIDToDirectoryName(modelID))
        let snapshotsDir = modelDir.appendingPathComponent("snapshots")
        guard let hashes = try? FileManager.default.contentsOfDirectory(
            at: snapshotsDir, includingPropertiesForKeys: nil
        ), let snapshot = hashes.first else { return nil }
        let configURL = snapshot.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["max_position_embeddings"] as? Int
        else { return nil }
        return value
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

