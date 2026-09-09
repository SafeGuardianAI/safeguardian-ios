// ToolSettingsStore.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// Persists which of Nova's tools the user has disabled. Absence from the
/// stored set means enabled — a fresh install has every tool on, and a tool
/// added later in AgentToolRegistry+AllTools.swift is enabled by default
/// without needing a migration step.
@Observable @MainActor
final class ToolSettingsStore {
    static let shared = ToolSettingsStore()

    private static let disabledKey = "nova.disabledToolNames"

    private(set) var disabledNames: Set<String> {
        didSet { UserDefaults.standard.set(Array(disabledNames), forKey: Self.disabledKey) }
    }

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? []
        disabledNames = Set(stored)
    }

    func isEnabled(_ toolName: String) -> Bool {
        !disabledNames.contains(toolName)
    }

    func setEnabled(_ toolName: String, _ enabled: Bool) {
        if enabled {
            disabledNames.remove(toolName)
        } else {
            disabledNames.insert(toolName)
        }
    }
}

/// Human-readable catalog for the settings UI. Excludes task_complete, which
/// is the model's own stop-signal mechanism and not user-disableable.
enum ToolCatalog {
    struct Entry {
        let name: String
        let displayName: String
        let summary: String
    }

    static let all: [Entry] = [
        Entry(name: "get_device_state", displayName: "Device State", summary: "Battery, geolocation, peer count"),
        Entry(name: "get_full_status", displayName: "Full Status", summary: "Combined device and mesh status"),
        Entry(name: "get_storage", displayName: "Storage", summary: "Free disk space on this device"),
        Entry(name: "get_memory", displayName: "Memory", summary: "Free RAM on this device"),
        Entry(name: "get_mesh_load", displayName: "Mesh Load", summary: "Current mesh packet rate"),
        Entry(name: "set_tick_interval", displayName: "Set Tick Interval", summary: "Change how often this device broadcasts state"),
        Entry(name: "set_message_ttl", displayName: "Set Message TTL", summary: "Change mesh message hop limit"),
        Entry(name: "list_peers", displayName: "List Peers", summary: "Read currently connected mesh peers"),
        Entry(name: "send_agent_message", displayName: "Send Agent Message", summary: "Message another agent on the mesh"),
        Entry(name: "broadcast_to_agents", displayName: "Broadcast to Agents", summary: "Send a message to every agent on the mesh"),
        Entry(name: "request_peer_location", displayName: "Request Peer Location", summary: "Ask a peer to share their location"),
        Entry(name: "request_mesh_topology", displayName: "Request Mesh Topology", summary: "Ask a peer for their view of the mesh"),
        Entry(name: "claim_incident", displayName: "Claim Incident", summary: "Mark an incident as being handled by this agent"),
        Entry(name: "release_incident", displayName: "Release Incident", summary: "Release a previously claimed incident"),
        Entry(name: "flood_alert", displayName: "Flood Alert", summary: "Broadcast an urgent alert to the whole mesh"),
        Entry(name: "publish_state_tick", displayName: "Publish State Tick", summary: "Push this device's current state tick now"),
        Entry(name: "open_peer_session", displayName: "Open Peer Session", summary: "Start a coordination session with a peer"),
        Entry(name: "peer_session_request", displayName: "Peer Session Request", summary: "Respond to a peer coordination session"),
        Entry(name: "close_peer_session", displayName: "Close Peer Session", summary: "End an active peer coordination session"),
        Entry(name: "sdr_scan", displayName: "SDR Scan", summary: "Scan the radio spectrum via a mesh SDR node"),
        Entry(name: "sdr_tune", displayName: "SDR Tune", summary: "Tune a mesh SDR node to a frequency"),
        Entry(name: "sdr_monitor", displayName: "SDR Monitor", summary: "Continuously monitor a frequency via a mesh SDR node"),
        Entry(name: "sdr_cancel", displayName: "SDR Cancel", summary: "Cancel an active SDR operation")
    ]
}
