# MeshBench Alignment Notes

_2026-05-28 — surveyed SafeGuardianAI/meshbench at commit HEAD_

## What MeshBench Is

MeshBench is a browser-based simulation framework that evaluates how LLM-augmented agents running on heterogeneous field devices communicate and collaborate over wireless mesh networks under disaster conditions. It combines real device performance data (30+ phones, tablets, and SBCs from Pal AI benchmarks), real model inference speeds (Nexa AI quantization benchmarks), PHY-layer radio propagation (Friis + log-distance, SINR, PER curves, material attenuation), energy modeling, 3D terrain-aware line-of-sight obstruction with OSM building integration, and five scripted disaster timelines. The entire simulator runs in the browser as a static React application.

It is not a live protocol stack. It does not exchange packets with real devices at runtime. Integration with SafeGuardian iOS would be data-level: the app reports its model set, device spec, battery state, and query outcomes; the simulator uses that profile to predict fleet-level performance.

## Query Types MeshBench Defines

The simulator defines ten disaster-response query categories, each mapping to a specific model pipeline:

- triage — qwen2.5-3b + emb-bge (medical priority routing)
- asr — whisper-lg (radio transcription)
- route — llama3.1-8b (medevac and evacuation routing)
- broadcast — kokoro-tts + emb-bge (shelter vitals relay)
- classify — emb-bge + qwen2.5-3b (symptom matching)
- summary — llama3.1-8b (multi-report synthesis)
- tts — kokoro-tts (voice warnings)
- sync — emb-bge (schema sync between hubs)

SafeGuardian currently maps `@nova` prompts to a single Qwen3-0.6B-4bit model. Multi-step pipelines (ASR → triage → TTS) are not yet implemented. Aligning with MeshBench would require recognizing these eight categories by intent, then routing each step to the appropriate model host across the mesh.

## Model Catalog Gaps

MeshBench's reference catalog covers qwen2.5-{0.5b, 1.5b, 3b, 7b}, llama3.{1-8b, 2-3b}, gemma-2-{2b, 9b}, phi-3.5-mini, whisper-lg, sherpa-onnx, kokoro-tts, and emb-bge. SafeGuardian currently loads only Qwen3-0.6B-4bit via MLX. A full alignment would require:

- Audio pipeline: Whisper for ASR, kokoro-tts or equivalent for TTS
- Embedding model: bge-small or bge-base for semantic routing
- Larger LLMs: at least llama3.2-3b for summarization and routing tasks

Quantization levels that matter to MeshBench's scoring are q2_K, q4_K_M, q6_K, and fp16. The app should declare which level it runs so MeshBench can use the right Nexa accuracy numbers.

## Device Profile Fields MeshBench Uses

For accurate energy and performance simulation, MeshBench expects each agent to report: device model name, RAM (GB), battery capacity (mAh), current battery percent, idle power draw (mW), and per-radio TX power. For SafeGuardian iOS on iPhone 16 / iPhone 16 Pro, these are known constants that can be hardcoded or sourced from UIDevice + IOKit.

The simulator already has profiles for iPhone 16 Pro (7.5 GB RAM, q4_K_M compatible) and scores it against the Pal AI prefill/decode benchmarks.

## Radio Stack Expected

MeshBench models BLE 5 (40–360m, 1–2 Mbps, 25 mW), WiFi Direct (40m, 10–50 Mbps, 700 mW), HaLow 802.11ah (180m, 150 kbps–2 Mbps, 250 mW), LoRa (15+ km, 1–50 kbps, 85 mW), and cellular. SafeGuardian iOS uses BLE as its primary transport, which maps directly to MeshBench's BLE 5 PHY tier. The app should report RSSI per link when available so MeshBench can back-calculate path loss.

## Routing Protocol Alignment

MeshBench uses BFS by default and optionally battery-aware weighted Dijkstra (correlation η² = 0.43 between battery-routing weight and fleet survival at end of scenario). SafeGuardian's current BLE relay logic should be audited for whether it implements any battery-awareness; adding a battery-weight parameter to the relay selection algorithm would close this gap and is a simulation-justified improvement.

## Persona System

MeshBench agents carry personas (medic, coordinator, drone, relay, sensor, victim) that control mobility patterns, model preferences, and battery starting ranges. SafeGuardian has no equivalent concept yet. Adding a persona field to the peer representation would allow MeshBench scenario imports to assign roles to real field devices before deployment.

## Scenario Event Format

Timed events arrive as a list of `{ t, type, ... }` objects. Event types include spike_queries, aftershock (agent destruction), switch_obstacles, and drain_batteries. For live integration, SafeGuardian would need a thin scenario receiver that maps these events to mesh topology updates, query injections, and state changes. The format is straightforward JSON and the event loop is thin — this is low-complexity to implement on the app side.

## What Is Already Aligned

SafeGuardian's BLE mesh transport matches MeshBench's primary radio tier exactly. The per-message content addressing (geohash channels, multi-hop relay) is structurally compatible with MeshBench's hop-by-hop packet routing. The Nova on-device inference capability (Qwen3-0.6B via MLX) maps to MeshBench's smallest model tier. Battery reporting already exists in NovaStateTick.

## Recommended Near-Term Steps

The minimum viable alignment — enough to benchmark a real SafeGuardian fleet against a MeshBench simulation — requires four things: (1) a device profile export that declares device model, RAM, battery capacity, current percent, and active radios; (2) a query trace log that records intent category, model used, token count, latency, and hop count per Nova interaction; (3) intent classification on incoming `@nova` prompts so the app knows which of the eight query types it is handling; and (4) a battery weight parameter in the relay candidate selection. Everything else (multi-model pipelines, TTS, ASR) is medium-term work that follows from expanding the model catalog.

## Source Files of Interest in MeshBench

- `project/sim-data.js` — all device profiles, model definitions, persona specs, disaster scenarios, and benchmark data; this is the canonical reference for alignment constants
- `project/sim-engine.js` — full routing, energy, and PHY logic; read this when verifying that SafeGuardian's routing decisions will score correctly in the simulator
- `project/mcp-tools.js` — the 70+ tool schema definitions that Claude uses to control the sim; this is useful if SafeGuardian ever wants to embed a MeshBench client for pre-deployment planning
- `benchmarks/pal_devices.json` — per-device prefill/decode throughput; iPhone 16 Pro entry is the ground truth for Nova's expected tokens/s
- `benchmarks/nexa_models.json` — per-model-per-quant IFEval accuracy and output tokens/s
