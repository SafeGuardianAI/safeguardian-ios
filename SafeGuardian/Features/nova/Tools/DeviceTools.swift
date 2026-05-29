import Darwin
import Foundation
import MLXLMCommon

extension AgentToolEntry {
    /// Returns the set of device tools. These are pure (no context needed for storage/memory)
    /// or use the proxy only for reading state (device_state).
    static func deviceTools() -> [AgentToolEntry] {
        [storageToolEntry(), memoryToolEntry(), deviceStateToolEntry()]
    }

    // MARK: - Storage

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

    private static func storageToolEntry() -> AgentToolEntry {
        make(
            name: "get_storage",
            description: "Returns device storage availability. Check this before recommending a model download.",
            parameters: []
        ) { _, _ in
            let available = availableStorageBytes()
            let total = totalStorageBytes()
            return #"{"available_gb":\#(String(format: "%.1f", Double(available)/1e9)),"total_gb":\#(String(format: "%.1f", Double(total)/1e9))}"#
        }
    }

    // MARK: - Memory

    static func availableMemoryBytes() -> Int {
        #if os(iOS)
        return Int(os_proc_available_memory())
        #else
        // macOS: use physical memory / 4 as a conservative available estimate
        return Int(ProcessInfo.processInfo.physicalMemory / 4)
        #endif
    }

    static func totalMemoryBytes() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory)
    }

    private static func memoryToolEntry() -> AgentToolEntry {
        make(
            name: "get_memory",
            description: "Returns device RAM availability. Check this before loading a large model.",
            parameters: []
        ) { _, _ in
            let available = availableMemoryBytes()
            let total = totalMemoryBytes()
            return #"{"available_gb":\#(String(format: "%.2f", Double(available)/1e9)),"total_gb":\#(String(format: "%.2f", Double(total)/1e9))}"#
        }
    }

    // MARK: - Device State

    private static func deviceStateToolEntry() -> AgentToolEntry {
        make(
            name: "get_device_state",
            description: "Returns current device state: battery, location confidence, connected peer count, and transport tier.",
            parameters: []
        ) { _, proxy in
            guard let tick = await proxy.tick() else {
                return #"{"error":"no state tick available"}"#
            }
            return #"{"battery_pct":\#(String(format: "%.0f", tick.batteryPct * 100)),"location_confidence":\#(String(format: "%.2f", tick.locationConfidence)),"peer_count":\#(tick.peerCount),"transport_tier":"\#(tick.transportTier.rawValue)"}"#
        }
    }
}
