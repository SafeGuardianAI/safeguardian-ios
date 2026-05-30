import BitFoundation
import Darwin
import Foundation
#if os(iOS)
import UIKit
#endif

/// Point-in-time capture of device and radio state at the moment a bench trial begins.
/// Collected once per session for local device; received via PONG/XACK for remote device.
struct RadioSnapshot: Codable {
    let hwModel: String
    let osVersion: String
    let physicalMemoryGB: Double
    let cpuCount: Int
    let batteryPct: Int
    let thermalState: String
    let appState: String
    let negotiatedMTU: Int
    let fragmentSizeBytes: Int
    let fragmentSpacingMs: Int
    let rssiDBm: Int?
    let connectedPeerCount: Int

    static func capture(transport: (any Transport)?, forPeer peerID: PeerID? = nil) -> RadioSnapshot {
        RadioSnapshot(
            hwModel: hwModelString(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            cpuCount: ProcessInfo.processInfo.processorCount,
            batteryPct: DeviceMetrics.batteryPercent(),
            thermalState: thermalStateString(),
            appState: appStateString(),
            negotiatedMTU: peerID.flatMap { transport?.negotiatedMTU(for: $0) } ?? TransportConfig.bleDefaultFragmentSize + 43,
            fragmentSizeBytes: TransportConfig.bleDefaultFragmentSize,
            fragmentSpacingMs: TransportConfig.bleFragmentSpacingMs,
            rssiDBm: peerID.flatMap { transport?.lastKnownRSSI(for: $0) },
            connectedPeerCount: transport?.currentPeerSnapshots().filter(\.isConnected).count ?? 0
        )
    }

    private static func hwModelString() -> String {
        var size = 0
        #if os(iOS)
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &model, &size, nil, 0)
        #else
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        #endif
        return String(cString: model)
    }

    private static func thermalStateString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func appStateString() -> String {
        #if os(iOS)
        switch UIApplication.shared.applicationState {
        case .active:     return "foreground"
        case .inactive:   return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
        #else
        return "foreground"
        #endif
    }
}
