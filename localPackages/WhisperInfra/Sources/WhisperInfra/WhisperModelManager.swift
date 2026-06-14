//
//  WhisperModelManager.swift
//  WhisperInfra
//
//  Downloads, caches, and selects whisper.cpp model files from HuggingFace.
//  Model selection is device-aware: available RAM and storage are measured at
//  runtime so the coordinator can pick the largest model the device can sustain
//  at interactive latency. A benchmark hook lets callers measure tokens-per-second
//  after loading and feed the result back to influence future selection.
//
//  Storage: <AppSupport>/Whisper/<filename>
//  Source:  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/<filename>
//
//  Model architecture note: whisper.cpp supports multiple quantization levels
//  (Q4_0, Q5_1, Q8_0, F16) and encoder variants (standard, CoreML). All share
//  the same ModelDescriptor type; switching architectures means changing the
//  filename and redownloading — no code changes required.
//

import Foundation

@MainActor
public final class WhisperModelManager: ObservableObject {

    public static let shared = WhisperModelManager()
    private init() {}

    @Published public private(set) var downloadProgress: Double = 0
    @Published public private(set) var isDownloading = false
    @Published public private(set) var benchmarkResult: BenchmarkResult?

    // MARK: - Model descriptors

    public struct ModelDescriptor: Sendable, Identifiable, Hashable {
        public let id: String          // used as the cache filename
        public let displayName: String
        public let approximateMB: Int
        public let remoteFilename: String

        public static let tinyEN    = ModelDescriptor(id: "ggml-tiny.en",    displayName: "Tiny (English)",  approximateMB: 39,  remoteFilename: "ggml-tiny.en.bin")
        public static let baseEN    = ModelDescriptor(id: "ggml-base.en",    displayName: "Base (English)",  approximateMB: 74,  remoteFilename: "ggml-base.en.bin")
        public static let smallEN   = ModelDescriptor(id: "ggml-small.en",   displayName: "Small (English)", approximateMB: 244, remoteFilename: "ggml-small.en.bin")
        public static let mediumEN  = ModelDescriptor(id: "ggml-medium.en",  displayName: "Medium (English)",approximateMB: 769, remoteFilename: "ggml-medium.en.bin")

        // Q4_0-quantized variants — smaller footprint, slightly lower accuracy.
        public static let tinyENQ4  = ModelDescriptor(id: "ggml-tiny.en-q4_0",  displayName: "Tiny Q4 (English)",  approximateMB: 26, remoteFilename: "ggml-tiny.en-q4_0.bin")
        public static let baseENQ4  = ModelDescriptor(id: "ggml-base.en-q4_0",  displayName: "Base Q4 (English)",  approximateMB: 42, remoteFilename: "ggml-base.en-q4_0.bin")
        public static let smallENQ4 = ModelDescriptor(id: "ggml-small.en-q4_0", displayName: "Small Q4 (English)", approximateMB: 142,remoteFilename: "ggml-small.en-q4_0.bin")

        public static let all: [ModelDescriptor] = [tinyEN, baseEN, smallEN, mediumEN, tinyENQ4, baseENQ4, smallENQ4]
    }

    // MARK: - Benchmark result

    public struct BenchmarkResult: Sendable {
        public let modelID: String
        public let tokensPerSecond: Double
        public let transcriptionMs: Double
        public let audioSeconds: Double
        public let realTimeFactor: Double  // transcriptionMs / (audioSeconds * 1000), < 1.0 is real-time capable
    }

    // MARK: - Device-aware model recommendation

    /// Returns the most capable model that fits within the device's available
    /// physical memory and free storage, targeting real-time transcription latency.
    public func recommendedModel() -> ModelDescriptor {
        let freeStorageMB = availableStorageMB()
        let physicalRAMMB = physicalMemoryMB()

        // Medium needs ~1.5 GB RAM headroom; Small ~400 MB; Base ~150 MB; Tiny ~80 MB.
        if physicalRAMMB >= 6000 && freeStorageMB >= 900 { return .mediumEN }
        if physicalRAMMB >= 4000 && freeStorageMB >= 300 { return .smallEN }
        if physicalRAMMB >= 2000 && freeStorageMB >= 100 { return .baseEN }
        return .tinyEN
    }

    // MARK: - Download / cache

    public func localURL(for model: ModelDescriptor) -> URL? {
        let url = cacheDirectory.appendingPathComponent(model.remoteFilename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func isDownloaded(_ model: ModelDescriptor) -> Bool { localURL(for: model) != nil }

    public func download(_ model: ModelDescriptor) async throws {
        if isDownloaded(model) { return }
        let remoteURL = baseURL.appendingPathComponent(model.remoteFilename)
        let destURL = cacheDirectory.appendingPathComponent(model.remoteFilename)

        isDownloading = true
        downloadProgress = 0
        defer { isDownloading = false; downloadProgress = 0 }

        let delegate = ProgressDelegate { [weak self] p in
            Task { @MainActor [weak self] in self?.downloadProgress = p }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (tmpURL, _) = try await session.download(from: remoteURL)
        try FileManager.default.moveItem(at: tmpURL, to: destURL)
    }

    public func delete(_ model: ModelDescriptor) throws {
        guard let url = localURL(for: model) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Benchmark recording

    /// Records a benchmark result after the coordinator measures transcription speed.
    /// Callers can use this to swap models if realTimeFactor > 1 (too slow for live use).
    public func recordBenchmark(_ result: BenchmarkResult) {
        benchmarkResult = result
    }

    // MARK: - Private

    private let baseURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/")!

    private var cacheDirectory: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisper")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func availableStorageMB() -> Int {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let free = attrs[.systemFreeSize] as? Int64
        else { return 0 }
        return Int(free / (1024 * 1024))
    }

    private func physicalMemoryMB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
    }
}

// MARK: - URLSession progress delegate

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let callback: @Sendable (Double) -> Void
    init(_ callback: @escaping @Sendable (Double) -> Void) { self.callback = callback }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        callback(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}
