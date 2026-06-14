//
//  WhisperContext.swift
//  WhisperInfra
//
//  RAII wrapper around whisper_context. Owns the opaque pointer and calls
//  whisper_free on deinit. All inference runs on a background queue so the
//  MainActor is never blocked.
//

import Foundation
import whisper_cpp

final class WhisperContext: @unchecked Sendable {
    private let ctx: OpaquePointer

    init?(modelURL: URL) {
        var cparams = whisper_context_default_params()
        cparams.use_gpu    = true
        cparams.flash_attn = false

        guard let context = modelURL.withUnsafeFileSystemRepresentation({ path -> OpaquePointer? in
            guard let p = path else { return nil }
            return whisper_init_from_file_with_params(p, cparams)
        }) else { return nil }
        self.ctx = context
    }

    deinit { whisper_free(ctx) }

    /// Synchronously transcribes 16 kHz mono PCM samples.
    /// Always call from a background Task — blocks until inference completes.
    func transcribeSync(samples: [Float]) -> [String] {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime   = false
        params.print_progress   = false
        params.print_timestamps = false
        params.no_context       = true
        params.single_segment   = false
        params.language         = ("en" as NSString).utf8String

        let result = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard result == 0 else { return [] }

        let count = whisper_full_n_segments(ctx)
        return (0..<count).compactMap { i in
            guard let raw = whisper_full_get_segment_text(ctx, i) else { return nil }
            return String(cString: raw).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }
}
