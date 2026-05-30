# BLE Transport Benchmarking in SafeGuardian

## Motivation

Bluetooth Low Energy mesh networks of the kind SafeGuardian operates on have not been characterized in the literature in the configuration that actually matters for disaster communications: a GATT-based multi-hop relay with per-fragment pacing, Noise Protocol session-layer encryption, and iOS CoreBluetooth as the radio driver. Published BLE throughput figures are almost always measured against a raw characteristic write loop without any of these layers in place, which makes them useless for reasoning about the capacity available to a real application. The pacing constraint alone — a deliberate 30 ms inter-fragment delay introduced to prevent buffer overflow on the iOS BLE scheduler — bounds the achievable throughput at roughly 15.6 KB/s for directed transfers regardless of what the radio hardware can theoretically sustain. Whether the actual achieved rate approaches that ceiling, and how it degrades with distance, concurrent peers, and thermal state, is an empirical question that requires measuring the full stack rather than the radio in isolation.

The benchmarking system described here is built into the application itself rather than implemented as an external test harness. This is intentional. An external sniffer or synthetic load generator cannot reproduce the iOS scheduling behavior, the Noise handshake overhead, the fragment reassembly contention, or the duty-cycle interaction that appear in production. All measurements are made on the real code path with real devices so that the results reflect what users actually experience.

## Architecture

The system is composed of four types: `RadioSnapshot`, `BenchmarkRecord` (which defines `BenchSession`, `BenchTrial`, and `BenchSummary`), `BenchmarkExporter`, and `BenchmarkCoordinator`. Each lives in its own file under `SafeGuardian/Services/Bench/`. The entry point for users is `BenchCommand`, registered in `CommandProcessor` alongside other slash commands.

`BenchmarkCoordinator` is a `@MainActor` singleton that holds the active session state and routes the in-band protocol messages described below. It receives messages from `ChatViewModel.didReceiveMessage` via a prefix intercept — the same pattern used by the bench protocol itself — and resumes Swift concurrency continuations when acknowledgements arrive. The coordinator is configured with a `Transport` reference on first invocation of `/bench` and retains it for the duration of the session.

`BenchmarkExporter` appends newline-delimited JSON records to a dated file in the application's Documents directory. The file is created on first write and appended atomically using `FileHandle`. Each session produces one file named `bench_YYYY-MM-DD_HHmmss.jsonl` that can be retrieved via Files app, AirDrop, or the iOS document share sheet. The `.jsonl` format is chosen over a single JSON array because it allows incremental analysis of in-progress sessions and survives process termination without truncating partial data.

## The In-Band Protocol

Measurements are coordinated between two devices using private BLE messages prefixed with the string `SGBench/1 `. This prefix is intercepted in `ChatViewModel.didReceiveMessage` before the message reaches the normal private chat handler, so bench traffic is silent to the user — it does not appear in any DM thread. The protocol borrows the same interception pattern used by the bench coordinator's sibling `BenchmarkCoordinator.receive(_:)`.

Three message verbs are defined. A `PING` carries the session identifier, a sender-side nanosecond timestamp from `DispatchTime.now().uptimeNanoseconds`, and a trial index. The receiving device answers with a `PONG` that echoes those fields plus its own receive timestamp and a compact encoding of its `RadioSnapshot` — hardware model, OS version, negotiated MTU, RSSI, battery percentage, and thermal state. A `PONG` arriving back at the originating device resolves the pending `CheckedContinuation<BenchTrial, Error>` stored in the active session and produces a complete `BenchTrial` record. An `XACK` serves the same role for file-transfer-based throughput trials, where the receiver acknowledges receipt of a complete file transfer payload rather than a single message. The elapsed time between `PING` dispatch and `PONG` receipt gives the round-trip latency; dividing by two yields an approximate one-way latency under the assumption of symmetric propagation, which is noted as a methodological limitation.

The full message syntax for each verb is as follows. A `PING` looks like `SGBench/1 PING sid=<uuid> t=<nanos> idx=<n>`. A `PONG` looks like `SGBench/1 PONG sid=<uuid> t=<sender_nanos> rt=<receiver_nanos> idx=<n> hw=<model> os=<version> mtu=<int> rssi=<int|nil> batt=<int> therm=<state>`. An `XACK` looks like `SGBench/1 XACK sid=<uuid> t=<receiver_nanos> idx=<n> frags=<int> bytes=<int> hw=<model> os=<version> mtu=<int> rssi=<int|nil> batt=<int> therm=<state>`. Spaces within field values are encoded as underscores; the protocol parser in `BenchmarkCoordinator.parseParams(_:)` splits on spaces and then on the first `=` per token.

## Device and Radio Metadata

`RadioSnapshot.capture(transport:forPeer:)` is called once at session start to characterize the local device and once implicitly via the remote device's `PONG` or `XACK` reply. The following fields are captured.

The hardware model identifier is read via `sysctlbyname("hw.machine", ...)` on iOS and `sysctlbyname("hw.model", ...)` on macOS. This returns the marketing model code — for example `iPhone17,3` for an iPhone 16 — rather than the human-readable name, which is appropriate for scientific records because it uniquely identifies the chip generation and radio hardware. The OS version string comes from `ProcessInfo.processInfo.operatingSystemVersionString`. Physical memory and CPU count come from `ProcessInfo.processInfo.physicalMemory` and `.processorCount`. Battery level uses `UIDevice.current.batteryLevel` after enabling monitoring, quantized to integer percentage. Thermal state is read from `ProcessInfo.processInfo.thermalState` and encoded as one of `nominal`, `fair`, `serious`, or `critical`; this field is significant because iOS throttles the BLE scheduler under thermal pressure in ways that are not otherwise visible to the application. App state encodes whether the app is in foreground, inactive, or background at the time of measurement, which affects BLE scan and advertising behavior.

The negotiated MTU per connected peer is read via `CBPeripheral.maximumWriteValueLength(for: .withoutResponse)`, accessed through the `Transport.negotiatedMTU(for:)` method added to the `Transport` protocol specifically for this system. This reflects the value actually negotiated during the connection setup rather than the configured maximum of 512 bytes in `TransportConfig.bleMaxMTU`, and it can differ across hardware generations and iOS versions. The last-seen RSSI for the target peer is stored in `PeripheralState.lastSeenRSSI` on `BLEService`, populated whenever the peer is observed during a BLE scan pass and exposed via `Transport.lastKnownRSSI(for:)`. Because CoreBluetooth does not provide a live RSSI callback for already-connected peripherals without an explicit `readRSSI()` call and asynchronous delegate response, the RSSI value in the snapshot reflects the signal strength at the most recent discovery event rather than at the moment of measurement. This limitation is noted in the schema via the `rssiDBm` field being optional — a nil value indicates no scan observation has occurred since the connection was established.

Two fields are deliberately absent from the snapshot because CoreBluetooth does not expose them: the BLE PHY mode (1M, 2M, or Coded) and the connection interval. On hardware that supports BLE 5.0 two-megabit PHY, the radio throughput ceiling roughly doubles, but iOS does not report which PHY is active through any public API. The connection interval, which the OS negotiates independently of the application and which directly affects the scheduling granularity of write operations, is similarly opaque. Apple's PacketLogger tool can observe both from HCI traces when a device is connected via USB, and those captures are the recommended complement to the in-app measurements for experiments where PHY and interval effects are under investigation.

## Schema

The JSON Lines output uses three record types distinguished by the `type` field. All keys are encoded in snake_case by the `JSONEncoder.keyEncodingStrategy = .convertToSnakeCase` setting on `BenchmarkExporter`.

A session record opens each file and captures static context:

```json
{
  "type": "session",
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "started_at": "2026-05-30T14:03:00Z",
  "app_version": "1.2.0",
  "build_number": "512",
  "local": { "hw_model": "iPhone17,3", "os_version": "iOS 26.3", ... },
  "remote_peer_id": "a3f9...",
  "remote_nickname": "bob",
  "payload_bytes": 10240,
  "trial_count": 100
}
```

A trial record is appended after each completed round-trip:

```json
{
  "type": "trial",
  "session_id": "550e8400...",
  "trial_index": 0,
  "payload_bytes": 10240,
  "fragment_count": 22,
  "elapsed_ms": 660,
  "throughput_k_bps": 15.5,
  "rssi_d_bm": -52,
  "battery_pct": 87,
  "thermal_state": "nominal",
  "send_ts_ns": 1748606580123456789,
  "complete_ts_ns": 1748606580783456789,
  "remote": { "hw_model": "Mac16,7", "os_version": "macOS 26.0", ... }
}
```

A summary record closes the file:

```json
{
  "type": "summary",
  "session_id": "550e8400...",
  "completed_trials": 100,
  "mean_throughput_k_bps": 15.2,
  "p50_throughput_k_bps": 15.6,
  "p95_throughput_k_bps": 14.1,
  "min_throughput_k_bps": 9.3,
  "max_throughput_k_bps": 15.8,
  "mean_elapsed_ms": 672.4,
  "export_path": "/var/mobile/.../Documents/bench_2026-05-30_140300.jsonl"
}
```

The `throughput_k_bps` field is computed as `payload_bytes / elapsed_ms`, which gives KB/s as a floating-point value where 1 KB = 1024 bytes. The summary statistics are computed over the full trial array sorted by throughput, with p50 taken at index `count / 2` and p95 at index `min(count * 0.95, count - 1)`.

## Invoking the System

The `/bench` command is registered in `CommandProcessor` and takes the following forms.

```
/bench                         — run against the peer in the currently open DM
/bench <nickname>              — specify a peer by nickname
/bench <nickname> kb=50        — override payload size (default 10 KB)
/bench <nickname> trials=20    — override trial count (default 100)
/bench listen                  — toggle passive echo mode on this device
```

When invoked with no peer argument while a private chat is open, `BenchCommand` reads `context.provider?.selectedPrivateChatPeer` and resolves the peer nickname via `context.transport?.peerNickname(peerID:)`. This is the expected usage in practice: open a DM with the peer you want to measure, then type `/bench`. The peer name autocomplete system is active for the `/bench` command because `CommandInfo.bench` is included in the nickname-completion group in `CommandInfo.placeholder`.

The receiving device does not need to take any action. `BenchmarkCoordinator.receive(_:)` is called from `ChatViewModel.didReceiveMessage` for any message with the `SGBench/1 ` prefix, and the coordinator echoes `PONG` messages autonomously. The `/bench listen` toggle exists for scenarios where the receiving device should enter listen mode before any session is initiated, but in practice the coordinator responds to incoming `PING` messages regardless of listen state as long as an active session is in progress on the originating device.

## Recommended Test Protocol

For measurements intended for publication, the following procedure controls the primary sources of variance. Both devices should be at stable battery charge above 20% to avoid iOS power-management interventions. Thermal state should be `nominal` at the start of each run, verified from the `thermal_state` field in the first trial record. The target payload sizes that reveal the most about the stack's behavior are 100 B, 400 B, 469 B, 1 KB, 10 KB, 100 KB, and 1 MB: the 469-byte size corresponds to `TransportConfig.bleDefaultFragmentSize` and marks the fragmentation boundary where pacing overhead first becomes the binding constraint rather than a per-message constant. The distance between devices should be noted manually in trial metadata since RSSI alone is an imprecise proxy for distance and does not capture orientation or obstruction effects. Trials at each configuration should be run three times with the app restarted between runs to prevent session cache effects from accumulating.

## Known Limitations

Clock skew between devices makes true one-way latency from `send_ts_ns` and `complete_ts_ns` unreliable when the two values come from different devices. The elapsed time `elapsed_ms` is always measured on the originating device from dispatch to acknowledgement receipt, which is a round-trip. Dividing by two is an approximation. For experiments where one-way latency is the primary variable, the `rt` field in the `PONG` message carries the receiver's nanosecond timestamp, and the delta `rt - t` (sender's dispatch time) gives a one-way estimate if the two devices' clocks are synchronized — which they will be approximately if both have NTP access, but not precisely enough for sub-millisecond analysis.

The fragment count in each trial record is computed from the payload size and configured fragment size rather than observed from the radio, because CoreBluetooth does not report fragment-level delivery events. Actual fragment count may differ if the negotiated MTU is smaller than the configured default, which the `negotiated_mtu` field in the session record will reveal.

RSSI is sampled at discovery time rather than during measurement. For distance-dependent experiments, RSSI should be treated as indicative rather than precise, and distance should be independently controlled and recorded.
