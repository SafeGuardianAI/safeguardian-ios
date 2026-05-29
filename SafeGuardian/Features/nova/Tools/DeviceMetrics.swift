import Darwin
import Foundation

/// Pure platform measurement functions. No context or tool infrastructure needed.
/// Used by individual tool files and by ModelDownloadManager.
enum DeviceMetrics {
    static func availableStorageBytes() -> Int64 {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return 0 }
        return available
    }

    static func totalStorageBytes() -> Int64 {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]),
              let total = values.volumeTotalCapacity else { return 0 }
        return Int64(total)
    }

    static func availableMemoryBytes() -> Int {
        #if os(iOS)
        return Int(os_proc_available_memory())
        #else
        return Int(ProcessInfo.processInfo.physicalMemory / 4)
        #endif
    }

    static func totalMemoryBytes() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory)
    }
}
