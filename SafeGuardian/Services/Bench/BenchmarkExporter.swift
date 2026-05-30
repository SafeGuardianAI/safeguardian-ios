import Foundation

/// Writes benchmark records as newline-delimited JSON to a dated file in the app's
/// Documents directory. Each call to append is synchronous and safe to call from MainActor.
final class BenchmarkExporter {
    private let fileURL: URL
    private let encoder: JSONEncoder

    init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = formatter.string(from: Date())
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("bench_\(stamp).jsonl")
        encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    var exportURL: URL { fileURL }

    func append<T: Encodable>(_ record: T) {
        guard let data = try? encoder.encode(record),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: fileURL, atomically: false, encoding: .utf8)
        }
    }
}
