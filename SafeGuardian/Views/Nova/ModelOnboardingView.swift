import SwiftUI

/// First-run sheet offering to download the on-device AI model before Nova is
/// first used, so the ~1 GB fetch happens deliberately (ideally on WiFi) rather
/// than as a surprise mid-conversation. Declining is always safe: Nova downloads
/// the model on demand exactly as before.
struct ModelOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mlx = MLXInferenceService.shared

    @State private var sizeBytes: Int64
    @State private var progress: Double = 0
    @State private var phase: Phase = .offer
    @State private var errorMessage: String?

    private enum Phase {
        case offer
        case downloading
        case done
    }

    init() {
        _sizeBytes = State(initialValue: ModelDownloadManager.shared
            .patternEstimate(modelID: MLXInferenceService.shared.activeModelID))
    }

    private var hasStorage: Bool {
        ModelDownloadManager.shared.hasStorageForDownload(modelID: mlx.activeModelID)
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
                .padding(.top, 32)

            Text("Nova works offline")
                .font(.title2.weight(.semibold))

            Text("Nova answers on this device using a local AI model (\(modelShortName), about \(sizeText)). Download it now so Nova is ready the first time you need it, even without a connection.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else if !hasStorage {
                Text("Not enough free storage for the model right now. You can download it later from Nova.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            switch phase {
            case .offer:
                Button(action: startDownload) {
                    Text("Download Now")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasStorage)
                .padding(.horizontal, 24)

                Button("Not Now") { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)

            case .downloading:
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .padding(.horizontal, 24)
                    Text(progress > 0 ? "Downloading \(Int(progress * 100))%" : "Starting download")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Continue in Background") { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)

            case .done:
                Label("Model ready", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .padding(.bottom, 32)
            }
        }
        .task { sizeBytes = await ModelDownloadManager.shared.remoteSize(modelID: mlx.activeModelID) }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }

    private var modelShortName: String {
        mlx.activeModelID.split(separator: "/").last.map(String.init) ?? mlx.activeModelID
    }

    private func startDownload() {
        phase = .downloading
        errorMessage = nil
        Task {
            do {
                try await mlx.prefetchActiveModel { p in progress = p }
                phase = .done
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            } catch {
                phase = .offer
                errorMessage = "Download failed: \(error.localizedDescription)"
            }
        }
    }
}
