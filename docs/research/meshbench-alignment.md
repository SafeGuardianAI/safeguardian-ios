# MeshBench Technical Alignment Notes

_2026-05-28 — surveyed SafeGuardianAI/meshbench HEAD_

## What It Is

MeshBench is a browser-based simulator for disaster-response mesh networks. It runs entirely in-browser as a static React application with no backend. It is not a live protocol stack — it does not exchange packets with real devices. Integration with SafeGuardian is data-level: the app produces a device profile and query traces in the shapes MeshBench expects, and the simulator uses those to model fleet performance analytically.

The simulator combines: real device performance data from Pal AI (30+ phones/tablets/SBCs), model accuracy and throughput from Nexa AI, PHY-layer radio physics (Friis + log-distance, SINR, PER curves, per-material RF attenuation), energy modeling (joules per TX/RX frame), 3D terrain-aware line-of-sight with OSM building import, and five scripted disaster timelines. A chat panel with 70+ tool functions allows Claude to monitor and control the simulation. BehaviorSpace-style factorial sweeps are run via Web Workers.

---

## Device Profile Object

Each device in the `DEVICES` catalog has these fields:

```
name:         string        e.g. "iPhone 16 Pro"
platform:     string        "iOS" | "Android" | "Linux" | "Embedded"
chip:         string        e.g. "A18 Pro"
tier:         string        "flagship" | "mid" | "low" | "edge" | "relay"
ram_gb:       number        e.g. 8
cores:        number        e.g. 6
battery_mah:  number        e.g. 3582; 0 for AC-powered edge devices
perf:         object        keys: "tiny" | "small" | "mid" | "large"
              each value:   [prefill_tok_per_s, decode_tok_per_s]  (two-element array)
              e.g. tiny:    [4223, 193]
drain:        number        baseline CPU drain multiplier e.g. 0.08
```

Not all devices have all perf buckets. The Pal AI JSON entry for iPhone 16 Pro in `benchmarks/pal_devices.json`:

```json
"iPhone 16 Pro": {
  "platform": "iOS",
  "cores": 6,
  "ram_gb": 8,
  "perf": {
    "tiny":  { "prefill": 4223.2, "decode": 193.3 },
    "small": { "prefill": 98.1,   "decode": 29.1  },
    "mid":   { "prefill": 198.7,  "decode": 18.3  },
    "large": { "prefill": 69,     "decode": 7.3   }
  }
}
```

SafeGuardian runs Qwen3-0.6B which falls in the "tiny" bucket. The Pal AI entry says iPhone 16 Pro does 4223 tok/s prefill and 193 tok/s decode for tiny models.

---

## Agent State Object

Each simulated agent (= one device node in the mesh) carries:

```
id:                  number       unique integer
name:                string       e.g. "MED-01"
device:              string       key into DEVICES
deviceLabel:         string       human name
platform:            string
tier:                string
persona:             string       "coordinator"|"medic"|"medevac"|"victim"|"sensor"|"drone"|"relay"
personaLabel:        string
personaColor:        string       hex e.g. "#d4a13e"
models:              string[]     model keys hosted, e.g. ["llama3.1-8b", "emb-bge"]
hostedDetail:        {model, quant}[]
x, y:                number       canvas pixel coordinates
battery:             number       0..100 percent
queue:               Query[]      pending jobs
processing:          null | {queryId, modelNeeded, quant, timeStarted}
processDuration:     number       ms
ttftMs:              number       time-to-first-token measured
tokensProcessed:     number
responded:           number       completed query count
dropped:             number       failed query count
accuracySum,
accuracyCount:       number       for running mean
selected,busy,
offline:             boolean
convo:               Message[]    recent turns for replay
streamTokens:        string[]
streamIndex:         number
mobility:            { model: "static"|"walk"|"vehicle"|"drone",
                       v_mps: number, vx: number, vy: number,
                       target_x: number, target_y: number,
                       pause_until: number }
pinned:              boolean
linkOverride:        string|null  e.g. "halow" to force radio tech
placementZM:         number       altitude in metres (elevated relays)
energy_tx_j:         number       cumulative joules TX
energy_listen_j:     number       cumulative joules RX/idle
tx_count, rx_count:  number
```

---

## Query Object

Application-layer request routed across the mesh:

```
id:           string    random hex slug
text:         string    the prompt text
kind:         string    "triage"|"asr"|"route"|"broadcast"|"classify"|"summary"|"sync"
priority:     string    "low"|"mid"|"high"
needs:        string[]  pipeline: model keys in execution order
              e.g.      ["whisper-lg", "qwen2.5-3b"]
originId:     number    agent id that created the query
createdAt:    number    sim time ms
completedAt:  number    sim time ms
latencyMs:    number    completedAt - createdAt
accuracy:     number    0..100, minimum of all step accuracies
steps:        Step[]    each step:
                          atId:      number  (agent that ran this step)
                          model:     string
                          quant:     string
                          at:        number  (sim time ms when step started)
                          tokens:    string[]
                          accuracy:  number
hopTotal:     number    cumulative hops across all steps
```

The eight query types and their default model pipelines:

```
triage:     ["qwen2.5-3b", "emb-bge"]
asr:        ["whisper-lg"]
route:      ["llama3.1-8b"]
broadcast:  ["kokoro-tts", "emb-bge"]
classify:   ["emb-bge", "qwen2.5-3b"]
summary:    ["llama3.1-8b"]
tts:        ["kokoro-tts"]
sync:       ["emb-bge"]
```

SafeGuardian currently handles all `@nova` prompts through a single Qwen3-0.6B inference call with no intent classification and no multi-step pipelines.

---

## Packet Object

Network-layer datagram (one hop at a time):

```
id:           string    random slug
kind:         string    "query"|"response"|"gossip"
from, to:     number    agent ids at current hop
path:         number[]  full route [origin, hop1, ..., dest]
hopIndex:     number    position in path array
hopProgress:  number    0..1, normalized travel within current hop
hopDuration:  number    ms for this hop (from link physics)
hopStart:     number    sim time ms when this hop began
queryId:      string    which query this packet belongs to
modelNeeded:  string    model key required at destination
size:         number    payload kilobytes (default 8)
dead:         boolean   packet failed/dropped
```

---

## Edge/Link Object

One directional link between two agents:

```
from, to:          number
link:              string    "bluetooth"|"wifidirect"|"halow"|"lora"|"cellular"
dist_px, dist_m:   number
rssi:              number    dBm
noise_dbm:         number    thermal noise floor + Rx NF
snr:               number    dB
mcs:               null | {snr, rate_mbps, name}   (WiFi/HaLow only)
rate_mbps:         number
airtime_ms:        number    ms for a 1024-byte frame
per_quiet:         number    0..1 packet error rate (no interference)
decodable:         boolean
utilization:       number    0..1
congested:         boolean   util > 0.6 OR active >= 3
active:            number    packets in flight on this edge
obstacle_atten_db: number    cumulative RF attenuation from materials
obstructed:        boolean
```

The "bluetooth" key maps to BLE 5. SafeGuardian's transport should declare as "bluetooth" when it exports state.

---

## Routing Algorithm (Exact)

Path selection via `findPathWeighted()` (hop-bounded Dijkstra):

- Maximum hops: `params.maxHops` (default 7)
- Base cost per hop: 1.0
- Battery penalty if `batteryRoutingWeight > 0`: `battW * max(0, (100 - battery) / 100) * 0.5` added per agent traversed
- No cycles (each agent appears at most once in path)
- Selects the best host (lowest total cost) that caches the required model

---

## Link Physics (Exact)

For each packet hop, `startPacketHop()` does:

1. Log-distance path loss: `PL(d) = PL₀ + 10 * n_path * log10(d/d₀)` where `PL₀ = 20*log10(f_MHz) - 27.55`
2. RSSI at receiver: `rssi = tx_dbm - pathLoss - obstacle_atten_db`
3. Interference from concurrent same-tech transmissions: sum of interferer RSSI in linear domain
4. SINR: `signal_dbm - 10*log10(noise_lin + sum(interferers_lin))`
5. MCS selection (WiFi/HaLow): pick best entry where SNR >= threshold; none decodable = packet dies
6. BLE decodability: SINR must exceed PHY-variant floor (1M/2M/Coded S2/S8 each have different sensitivities)
7. LoRa: cliff at `LORA_SENS[SF].snr_min`; PER = `exp(-(SINR - snr_min) / 1.5)`
8. Stochastic loss: `rand() < PER * lossScale` kills packet
9. TX energy: `(phy.tx_mw / 1000) * (airtime_ms / 1000) * radioEnergyScale` joules
10. Battery depletion: `(J / (battery_mah * 13.32)) * 100` percent

Battery capacity formula: `battery_mah * 3.7V * 3.6 J/mAs = battery_mah * 13.32 joules`

Cold-start penalty on TTFT per tier: flagship 2.2×, mid 3.8×, low 5.5×, edge 6.0×

---

## Persona Shape

```
label:          string    e.g. "Coordinator"
short:          string    3-char prefix e.g. "CMD"
color:          string    hex
deviceFilter:   string[]  allowed tier keys e.g. ["flagship"]
models:         string[]  preferred hosted models
noModels:       boolean   optional; relay nodes host nothing
linkOverride:   string    optional; e.g. "bluetooth" for relay
mobility:       string    "static"|"walk"|"vehicle"|"drone"
batteryStart:   [min,max] initial battery % range
```

---

## Disaster Scenario/Event Shape

```
label:    string
initial:  { obstaclePreset, personaMix, mobility }
events:   [
  {
    t:        number   sim seconds when event fires
    type:     string   "spike_queries"|"aftershock"|"disable_agents"|
                       "drain_batteries"|"switch_obstacles"|
                       "set_mobility"|"add_obstacle"
    count:    number   for spike_queries, aftershock, disable_agents
    amount:   number   for drain_batteries (% to reduce)
    priority: string   for spike_queries
    preset:   string   for switch_obstacles
    model:    string   for set_mobility
    rect:     {x,y,w,h,material,label}  for add_obstacle
    label:    string   human log message
  }
]
```

---

## PHY Layer Constants (per tech)

```
f_mhz:     carrier frequency
tx_dbm:    transmit power (EIRP)
bw_hz:     channel bandwidth
nf_db:     receiver noise figure
n_path:    log-distance exponent (2.7..3.5)
mac:       "dcf"|"tdma"|"aloha"|"ofdma"
tx_mw,
rx_mw,
idle_mw:   power draw in mW
```

BLE additionally carries: `ble_phy` ("1M"|"2M"|"CODED_S2"|"CODED_S8"), `ble_rate_mbps`, `ble_sens_dbm`, `ble_range_mult`.

---

## Nexa Model Catalog Entry

A representative entry from `benchmarks/nexa_models.json`:

```json
"gemma-2-9b-instruct": {
  "provider": "google",
  "quants": [
    {
      "name":     "q4_K_M",
      "prefill":  554134.8,
      "decode":   27.9,
      "ifeval":   72.3,
      "ram_gb":   7.1,
      "size_gb":  3.6
    }
  ]
}
```

Each model lists 14–15 quantization variants with: prefill tok/s, decode tok/s, IFEval accuracy, RAM footprint, and on-disk size.

---

## MCP Tool Interface (Key Tools)

These are the tool definitions Claude uses to control the live sim. They also define the semantic contract for any future SafeGuardian → MeshBench bridge.

`inject_query` parameters: `text` (string, optional), `priority` ("low"|"mid"|"high"), `needs` (string[])

`add_agent` parameters: `x, y` (canvas pixels), `persona` (one of the 7 persona keys), `device` (DEVICES key), `battery` (0..100), `linkOverride` (radio tech key)

`run_experiment` parameters: `factors` (object: factor keys → values or arrays), `measures` (string[]: metric keys), `durationS` (1..120), `repetitions` (1..10)

`get_state` returns: headline throughput, latency, accuracy, coverage, drop rate, energy, sim time, live agent count, topology

`analyze_mesh` returns: list of isolated nodes, low-battery agents, congested links, trend indicators

---

## Alignment Gaps for SafeGuardian

These are the concrete things SafeGuardian needs to produce or implement for full MeshBench interop:

A device profile export with fields matching the DEVICES shape above: platform, chip, tier, ram_gb, battery_mah, and the perf buckets (tiny/small/mid/large). iPhone 16 Pro entries are already in `pal_devices.json` so the app just needs to declare which device it is.

A query trace log per Nova interaction: kind (one of the 8 categories above), model used, quant level, token count, latency ms, hop count, accuracy proxy. The kind field requires intent classification, which SafeGuardian does not yet do — all prompts are routed as opaque text.

Battery state reporting: battery_mah (hardcode per device model), current percent (already in NovaStateTick.batteryPct), and optionally drain rate. The NovaStateTick struct already captures batteryPct and peerCount which map directly to agent fields.

Radio tech declaration: SafeGuardian must declare "bluetooth" (not "ble_coded") as its link type when exporting state. The `TransportTier.ble_coded` raw value in NovaStateTick.swift would need to be mapped to "bluetooth" at export time.

Battery-aware relay weighting: the simulator shows η² = 0.43 correlation between battery routing weight and fleet survival. SafeGuardian's relay candidate selection does not currently consider battery level of intermediate nodes.

The minimum viable output for one SafeGuardian device to appear as a correctly-modeled agent in a MeshBench scenario is: `{ device: "iphone-16-pro", platform: "iOS", tier: "flagship", ram_gb: 8, battery_mah: 3582, battery: <current_pct>, models: ["qwen3-0.6b"], link: "bluetooth", x: <canvas_x>, y: <canvas_y> }`.
