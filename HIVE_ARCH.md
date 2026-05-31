# SafeGuardian: Hybrid Multi-Tiered Mesh Architecture

This document specifies the technical architecture for the SafeGuardian Hybrid Mesh—a resilient, "True Mesh" network designed for total infrastructure failure. It bridges low-power local sensors (BLE) to global command (Satellite) using a unified Peer-to-Peer (P2P) substrate.

---

## 1. The Multi-Tier Model

SafeGuardian operates across four distinct tiers of hardware and transport, collectively forming a single logical network.

| Tier | Role | Device | Transport | Agent |
| :--- | :--- | :--- | :--- | :--- |
| **Local** | The "Cell" | Civilian Smartphone | BLE + **MPC / UWB** | **Nova** |
| **Tactical** | The "Bridge" | Rescuer Handheld | BLE + WiFi / P2P Radio | **Trek** |
| **Backhaul** | The "Link" | UAV / Drone | Satellite (Starlink) + WiFi | **Trek (Relay)** |
| **Strategic** | The "Overseer" | Remote Ops Center | Internet / Satellite | **Apex** |

---

## 2. Agent Hierarchical Purview

... (rest of section 2) ...

---

## 3. The Integraph (WorldGraph)

... (rest of section 3) ...

---

## 4. The Multi-Tier Transport Stack (The "Burst Tier")

To handle the "Bandwidth Bloat" of advanced P2P protocols, SafeGuardian implements an adaptive, tiered transport strategy.

### A. Tier 1: The Heartbeat (BLE)
*   **Protocol**: SafeGuardian Binary v2.
*   **Role**: Always-on discovery, Gossip heartbeats, and low-latency SOS messages.
*   **Constraint**: 15KB/s ceiling with 30ms inter-fragment pacing.

### B. Tier 2: Spatial Metadata (UWB / NearbyInteraction)
*   **Role**: Sub-10cm spatial ranging between U1/U2-equipped devices.
*   **Usage**: Replaces manual distance metadata in benchmarking. Enables **Spatial Routing**—the mesh automatically prioritizes physically closer peers for critical relay hops.
*   **Constraint**: Non-data-carrying; used purely for geometric mesh optimization.

### C. Tier 3: High-Bandwidth Burst (MPC / Wi-Fi Direct)
*   **Role**: On-demand high-speed link (Mbps) for voice notes, structural photos, or full Integraph database syncs.
*   **Logic**: Triggered by the `MessageRouter` when payload size exceeds threshold or an agent requests a "Burst Session."
*   **Implementation**: Slot-in `Transport` implementation using Apple's `MultipeerConnectivity` or `NWConnection` (P2P enabled).

---

## 5. Technical Implementation: libp2p Bridge

To achieve global reach over ad-hoc hops, SafeGuardian utilizes the `libp2p` protocol (specifically `py-libp2p` on Linux/Trek nodes).

### A. Protocol Translation (The Bridge)
Trek nodes act as protocol translators between the **SafeGuardian Binary v2 (BLE)** and **libp2p Stream (WebSockets/TCP)**.
*   **Encapsulation**: Raw mesh packets are wrapped in libp2p streams using the `mplex` or `yamux` multiplexers.
*   **Encryption Hand-off**: The Trek node terminates transport-level Noise encryption from the backhaul and forwards the payload into the mesh's own internal Noise-encrypted channels to save civilian battery.

### B. BLE Transport Intricacies (The "Hard" Part)
Implementing libp2p over BLE requires strict adherence to physical constraints:
1.  **30ms Pacing (The Shepherd Doctrine)**: To prevent iOS/Android Bluetooth buffer crashes, the bridge must enforce a **30ms delay** between binary fragments.
2.  **L2CAP CoC**: For high-performance streaming, Trek nodes use **L2CAP Connection-Oriented Channels**, providing a raw, credit-based stream that libp2p treats as an `asyncio` socket.
3.  **Circuit Relay v2**: Nova nodes use the libp2p Circuit Relay protocol to "hop" their streams through other civilians to reach a Trek exit-node.

### C. Multiaddr Addressing
Every node in the disaster zone is addressable via a unified `multiaddr`:
`/ip4/1.2.3.4/tcp/443/ws/p2p/TREK_ID/p2p-circuit/ble/NOVA_PEER_ID`

---

## 5. Visual Summary

### The "SOS" Lifecycle
1.  **Nova (Civilian)** → **Mesh Relay** (BLE) → **Trek Bridge** (BLE to WiFi) → **Drone** (WiFi to Sat) → **Apex (Global Command)**.

### The "Directive" Lifecycle
1.  **Apex (Strategic)** → **Drone** (Sat to WiFi) → **Trek Bridge** (WiFi to BLE) → **Nova Cluster** (Regional Broadcast).

---

## 6. Implementation Notes for `py-libp2p`

When deploying the bridge on a Trek node:
*   Use `GossipSub v1.1` with strict peer scoring to prevent mesh-spam.
*   Implement a custom `ITransport` that wraps the `bleak` L2CAP socket.
*   Map the SafeGuardian `PeerID` 1-to-1 with the libp2p `PeerID` to ensure identity persistence across transport hops.
