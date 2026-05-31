# Cross-Platform Mesh Compatibility Layer

Design for a service-agnostic interface that separates the BLE/transport driver from the
protocol engine, enabling the SafeGuardian/bitchat mesh protocol to run on Linux, macOS,
Android, and embedded targets with only Layer 0 changing per platform.

---

## Layer 0 — Radio Adapter (platform-specific)

The only surface that changes between CoreBluetooth, BlueZ, and Android BLE.

```
constants:
    SERVICE_UUID  = "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C"  // mainnet
    CHAR_UUID     = "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D"
    MAX_LINKS     = 6
    RSSI_FLOOR    = -90      // dBm; below this we do not connect

struct Link:
    id: bytes[16]            // opaque handle (BLE peripheral UUID or equivalent)
    mtu: int
    role: Central | Peripheral

interface RadioAdapter:
    start_advertising(service: UUID, characteristic: UUID)
    stop_advertising()
    start_scanning(service: UUID)
    stop_scanning()
    connect(candidate: Candidate) -> Link
    disconnect(link: Link)
    send(link: Link, data: bytes) -> bool   // false = queue full

    on_link_up:    (Link) -> void
    on_link_down:  (Link) -> void
    on_receive:    (Link, bytes) -> void

    get_mtu(link: Link) -> int

    struct Candidate:
        link_id: bytes[16]
        rssi: int
        connectable: bool
        discovered_at: time
```

Platform translation table:

    iOS/macOS  ->  CBCentralManager + CBPeripheralManager
    Linux      ->  bluer (Rust) or BlueZ D-Bus GATT
    Android    ->  BluetoothGatt + BluetoothGattServer
    ESP32/C    ->  NimBLE or Espressif GATT API

---

## Layer 1 — Frame Codec (pure, no platform dependency)

```
struct Packet:
    version:      u8          // 1 or 2
    type:         u8          // MessageType below
    ttl:          u8
    timestamp:    u64_be      // milliseconds since epoch
    flags:        u8
    payload_len:  u16_be      // v1; u32_be for v2
    sender_id:    bytes[8]    // truncated SHA256 of noise static public key
    recipient_id: bytes[8]?   // present iff flags.HAS_RECIPIENT
    route_count:  u8?         // present iff flags.HAS_ROUTE (v2 only)
    route_hops:   bytes[8*n]?
    orig_size:    u16_be?     // present iff flags.IS_COMPRESSED
    payload:      bytes[payload_len - (2 if IS_COMPRESSED else 0)]
    signature:    bytes[64]?  // Ed25519; present iff flags.HAS_SIGNATURE

enum MessageType:
    ANNOUNCE        = 0x01
    MESSAGE         = 0x02
    LEAVE           = 0x03
    NOISE_HANDSHAKE = 0x10
    NOISE_ENCRYPTED = 0x11
    FRAGMENT        = 0x20
    REQUEST_SYNC    = 0x21
    FILE_TRANSFER   = 0x22

struct Flags:
    HAS_RECIPIENT = 0x01
    HAS_SIGNATURE = 0x02
    IS_COMPRESSED = 0x04
    HAS_ROUTE     = 0x08
    IS_RSR        = 0x10

function encode(packet: Packet, pad: bool) -> bytes:
    buf = []
    buf.append(packet.version, packet.type, packet.ttl)
    buf.append_u64_be(packet.timestamp)
    buf.append(build_flags(packet))
    compressed_payload, orig_size = maybe_compress(packet.payload)
    buf.append_u16_be(len(compressed_payload) + (2 if orig_size else 0))
    buf.append(packet.sender_id.pad_or_trim_to(8))
    if packet.recipient_id: buf.append(packet.recipient_id.pad_or_trim_to(8))
    if packet.route: buf.append(len(packet.route)); buf.append_each(packet.route)
    if orig_size:    buf.append_u16_be(orig_size)
    buf.append(compressed_payload)
    if packet.signature: buf.append(packet.signature)
    if pad: return pkcs7_pad_to_block(buf)
    return buf

function decode(raw: bytes) -> Packet?:
    data = try_decode_core(raw)
    if data is None: data = try_decode_core(pkcs7_unpad(raw))
    return data

function try_decode_core(raw: bytes) -> Packet?:
    if len(raw) < 22: return None  // minimum: 14-byte header + 8 sender
    version = raw[0]
    if version not in (1, 2): return None
    type    = raw[1]
    ttl     = raw[2]
    timestamp = read_u64_be(raw, 3)
    flags   = raw[11]
    payload_len = read_u16_be(raw, 12)   // or u32 at offset 12..15 for v2
    offset  = 14 if version == 1 else 16
    sender_id   = raw[offset : offset+8]; offset += 8
    recipient_id = None
    if flags & HAS_RECIPIENT: recipient_id = raw[offset : offset+8]; offset += 8
    route = None
    if version == 2 and flags & HAS_ROUTE:
        n = raw[offset]; offset += 1
        route = [raw[offset + i*8 : offset + (i+1)*8] for i in range(n)]
        offset += n * 8
    payload_end = offset + payload_len
    if payload_end > len(raw): return None
    raw_payload = raw[offset : payload_end]
    if flags & IS_COMPRESSED:
        orig_size  = read_u16_be(raw_payload, 0)
        payload    = zlib_decompress(raw_payload[2:], expected_len=orig_size)
    else:
        payload = raw_payload
    offset = payload_end
    signature = None
    if flags & HAS_SIGNATURE:
        if offset + 64 > len(raw): return None
        signature = raw[offset : offset+64]
    return Packet(version, type, ttl, timestamp, flags, sender_id,
                  recipient_id, route, payload, signature)
```

---

## Layer 2 — Fragment Engine (pure)

```
FRAG_HEADER_OVERHEAD = 13 + 8 + 8

struct FragmentKey:
    sender_id:   bytes[8]
    fragment_id: u64

struct FragmentBuffer:
    pieces:     map[int, bytes]
    total:      int
    msg_type:   u8
    arrived_at: time

function fragment_and_send(engine, packet: Packet, link: Link, max_chunk: int?):
    chunk_size = max(64, (max_chunk ?? link.mtu) - FRAG_HEADER_OVERHEAD)
    raw = encode(packet, pad=false)
    if len(raw) <= link.mtu:
        engine.adapter.send(link, encode(packet, pad=padPolicy(packet.type)))
        return
    frag_id = generate_u64_id()
    total   = ceil(len(raw) / chunk_size)
    for i, chunk in enumerate(split(raw, chunk_size)):
        frag_payload = encode_fragment(fragment_id=frag_id, index=i,
                                       total=total, original_type=packet.type, data=chunk)
        frag_packet = Packet(type=FRAGMENT, ttl=min(packet.ttl, TTL_FRAG_CAP),
                             sender_id=engine.my_peer_id, payload=frag_payload)
        engine.adapter.send(link, encode(frag_packet, pad=false))
        sleep_jitter(FRAG_DELAY_MS_MIN, FRAG_DELAY_MS_MAX)

function on_fragment_received(engine, frag: Packet, from_link: Link) -> Packet?:
    key = FragmentKey(frag.sender_id, fragment_id(frag))
    index, total, msg_type, data = decode_fragment_payload(frag.payload)
    buf = buffers.get_or_create(key, FragmentBuffer(total, msg_type))
    buf.pieces[index] = data
    if len(buf.pieces) == total:
        buffers.remove(key)
        return decode(concat([buf.pieces[i] for i in range(total)]))
    return None

function evict_stale_fragments(now: time):
    for key, buf in buffers.items():
        if now - buf.arrived_at > 30: buffers.remove(key)
```

---

## Layer 3 — Mesh Routing Engine (pure)

```
DEDUP_WINDOW       = 2048
TTL_DEFAULT        = 7
TTL_FRAG_CAP       = 5
FANOUT_K_THRESHOLD = 4

struct PeerInfo:
    peer_id:            bytes[8]
    nickname:           string
    noise_public_key:   bytes[32]?
    signing_public_key: bytes[32]?
    connected:          bool
    last_seen:          time

struct MeshEngine:
    adapter:          RadioAdapter
    noise:            NoiseEngine
    my_peer_id:       bytes[8]
    my_nickname:      string
    peers:            map[bytes[8], PeerInfo]
    link_to_peer:     map[bytes[16], bytes[8]]
    peer_to_link:     map[bytes[8], bytes[16]]
    links:            map[bytes[16], Link]
    seen_messages:    LRU<string>
    ingress:          map[string, bytes[16]]
    fragments:        FragmentEngine
    pending_directed: map[bytes[8], map[string, (Packet, time)]]
    event_sink:       EventSink

function on_receive(engine, link: Link, raw: bytes):
    packet = decode(raw)
    if packet is None: return
    dedup_key = hex(packet.sender_id) + str(packet.timestamp) + str(packet.type)
    if dedup_key in engine.seen_messages: return
    engine.seen_messages.insert(dedup_key)
    engine.ingress[dedup_key] = link.id
    if packet.type == FRAGMENT:
        reassembled = engine.fragments.on_fragment_received(packet, link)
        if reassembled is None: return
        packet = reassembled
    sender_id = bytes8(packet.sender_id)
    match packet.type:
        ANNOUNCE        -> handle_announce(engine, packet, sender_id, link)
        MESSAGE         -> handle_message(engine, packet, sender_id)
        LEAVE           -> handle_leave(engine, packet, sender_id)
        NOISE_HANDSHAKE -> engine.noise.handle_handshake(engine, packet, sender_id)
        NOISE_ENCRYPTED -> handle_noise_encrypted(engine, packet, sender_id)
        FILE_TRANSFER   -> handle_file(engine, packet, sender_id)
        REQUEST_SYNC    -> handle_sync_request(engine, packet, sender_id, link)
    if packet.ttl > 1:
        fanout(engine, Packet(packet, ttl=packet.ttl - 1), exclude_link=link.id)

function send_broadcast(engine, type: u8, payload: bytes) -> string:
    packet = Packet(version=1, type=type, ttl=TTL_DEFAULT, timestamp=now_ms(),
                    sender_id=engine.my_peer_id, payload=payload)
    if type in (MESSAGE, ANNOUNCE):
        packet = engine.noise.sign(packet)
    dedup_key = hex(packet.sender_id) + str(packet.timestamp) + str(packet.type)
    engine.seen_messages.insert(dedup_key)
    fanout(engine, packet, exclude_link=None)
    return new_uuid()

function send_private(engine, content: bytes, to_peer: bytes[8]) -> string:
    if not engine.noise.has_session(to_peer):
        engine.noise.initiate_handshake(engine, to_peer)
        engine.noise.enqueue_after_handshake(to_peer, content)
        return new_uuid()
    ciphertext = engine.noise.encrypt(content, for_peer=to_peer)
    packet = Packet(type=NOISE_ENCRYPTED, ttl=TTL_DEFAULT, timestamp=now_ms(),
                    sender_id=engine.my_peer_id, recipient_id=to_peer, payload=ciphertext)
    fanout(engine, packet, exclude_link=None)
    return new_uuid()

function fanout(engine, packet: Packet, exclude_link: bytes[16]?):
    all_link_ids = engine.links.keys()
    if exclude_link: all_link_ids = all_link_ids - {exclude_link}
    if packet.recipient_id is not None:
        target_link = engine.peer_to_link.get(packet.recipient_id)
        if target_link:
            send_on_link(engine, target_link, packet)
        else:
            for lid in all_link_ids: send_on_link(engine, lid, packet)
        return
    k = fanout_k(len(all_link_ids))
    subset = deterministic_subset(all_link_ids, k, seed=dedup_key(packet))
    for lid in subset: send_on_link(engine, lid, packet)

function send_on_link(engine, link_id: bytes[16], packet: Packet):
    link = engine.links[link_id]
    data = encode(packet, pad=padPolicy(packet.type))
    if len(data) > link.mtu:
        engine.fragments.fragment_and_send(engine, packet, link)
    else:
        engine.adapter.send(link, data)

function fanout_k(n: int) -> int:
    if n <= FANOUT_K_THRESHOLD: return n
    return max(2, ceil(sqrt(n)))

function deterministic_subset(ids: list, k: int, seed: string) -> set:
    rng = seeded_rng(sha256(seed))
    shuffled = fisher_yates(ids, rng)
    return set(shuffled[:k])
```

---

## Layer 4 — Noise Session Engine (pure)

Protocol: `Noise_XX_25519_ChaChaPoly_SHA256`. Three-message XX handshake. Transport
ciphers use ChaCha20-Poly1305 with a 4-byte big-endian nonce prepended to every frame
for receiver-side sliding-window replay protection.

```
PROTOCOL_NAME = "Noise_XX_25519_ChaChaPoly_SHA256"
REPLAY_WINDOW = 1024

struct CipherState:
    key:            bytes[32]?
    nonce:          u64
    highest_nonce:  u64
    window:         bytes[128]   // 1024-bit sliding window

struct SymmetricState:
    h:  bytes[32]
    ck: bytes[32]
    cs: CipherState

struct Session:
    send_cipher:   CipherState
    recv_cipher:   CipherState
    remote_static: bytes[32]

struct NoiseEngine:
    static_private:  bytes[32]
    static_public:   bytes[32]
    signing_private: bytes[64]
    signing_public:  bytes[32]
    sessions:    map[bytes[8], Session]
    handshakes:  map[bytes[8], HandshakeState]
    pending_after_handshake: map[bytes[8], list[bytes]]

function initiate_handshake(noise: NoiseEngine, engine: MeshEngine, peer_id: bytes[8]):
    hs = HandshakeState(role=Initiator, protocol=PROTOCOL_NAME,
                        local_static=noise.static_private)
    noise.handshakes[peer_id] = hs
    msg1 = hs.write_message(payload=b"")
    packet = Packet(type=NOISE_HANDSHAKE, sender_id=engine.my_peer_id,
                    recipient_id=peer_id, payload=msg1, ttl=TTL_DEFAULT)
    fanout(engine, packet, exclude_link=None)

function handle_handshake(noise: NoiseEngine, engine: MeshEngine, packet: Packet, sender: bytes[8]):
    hs = noise.handshakes.get(sender)
    if hs is None and is_initiator_message(packet.payload):
        hs = HandshakeState(role=Responder, protocol=PROTOCOL_NAME,
                            local_static=noise.static_private)
        noise.handshakes[sender] = hs
    hs.read_message(packet.payload)
    if hs.is_complete():
        send_cipher, recv_cipher, _ = hs.split()
        noise.sessions[sender] = Session(send_cipher, recv_cipher, hs.remote_static)
        noise.handshakes.remove(sender)
        flush_pending(noise, engine, sender)
    elif hs.needs_response():
        reply_msg = hs.write_message(payload=b"")
        reply = Packet(type=NOISE_HANDSHAKE, sender_id=engine.my_peer_id,
                       recipient_id=sender, payload=reply_msg, ttl=TTL_DEFAULT)
        fanout(engine, reply, exclude_link=None)

// Symmetric state operations
function mix_key(ss: SymmetricState, ikm: bytes):
    ck, temp_k = hkdf(ss.ck, ikm, n=2)
    ss.ck = ck; ss.cs.key = temp_k; ss.cs.nonce = 0

function mix_hash(ss: SymmetricState, data: bytes):
    ss.h = sha256(ss.h + data)

function split(ss: SymmetricState) -> (CipherState, CipherState):
    k1, k2 = hkdf(ss.ck, b"", n=2)
    return CipherState(k1), CipherState(k2)

// Transport encrypt
function encrypt(cs: CipherState, plaintext: bytes, aad: bytes = b"") -> bytes:
    assert cs.nonce <= 0xFFFF_FFFF
    nonce12 = b"\x00\x00\x00\x00" + u64_le(cs.nonce)
    ciphertext, tag = chacha20poly1305_seal(cs.key, nonce12, plaintext, aad)
    nonce4 = u32_be(cs.nonce)
    cs.nonce += 1
    return nonce4 + ciphertext + tag

// Transport decrypt
function decrypt(cs: CipherState, data: bytes, aad: bytes = b"") -> bytes:
    assert len(data) >= 4 + 16
    received_nonce = read_u32_be(data, 0)
    if not replay_window_check(cs, received_nonce): raise ReplayError
    ciphertext = data[4 : len(data)-16]
    tag        = data[len(data)-16 :]
    nonce12    = b"\x00\x00\x00\x00" + u64_le(received_nonce)
    plaintext  = chacha20poly1305_open(cs.key, nonce12, ciphertext, tag, aad)
    replay_window_mark(cs, received_nonce)
    return plaintext

// Sliding-window replay protection
function replay_window_check(cs: CipherState, n: u64) -> bool:
    if cs.highest_nonce >= REPLAY_WINDOW and n <= cs.highest_nonce - REPLAY_WINDOW:
        return false
    if n > cs.highest_nonce: return true
    offset = cs.highest_nonce - n
    return not bit_is_set(cs.window, offset)

function replay_window_mark(cs: CipherState, n: u64):
    if n > cs.highest_nonce:
        shift_window_right(cs.window, n - cs.highest_nonce)
        cs.highest_nonce = n
        set_bit(cs.window, 0)
    else:
        set_bit(cs.window, cs.highest_nonce - n)

// Ed25519 packet signing (public messages and announces)
function sign_packet(noise: NoiseEngine, packet: Packet) -> Packet:
    signing_data = encode(packet_without_sig(packet), pad=false)
    sig = ed25519_sign(noise.signing_private, signing_data)
    return Packet(packet, signature=sig)
```

---

## Layer 5 — Application Layer (pure, thin)

```
struct AnnouncementPayload:
    nickname:           string
    noise_public_key:   bytes[32]
    signing_public_key: bytes[32]
    neighbors:          list[bytes[8]]
    agent_ids:          list[string]

enum NoisePayloadType: u8:
    PRIVATE_MESSAGE  = 0x01
    READ_RECEIPT     = 0x02
    DELIVERED        = 0x03
    VERIFY_CHALLENGE = 0x10
    VERIFY_RESPONSE  = 0x11

function handle_announce(engine, packet, sender_id, link):
    ap = decode_announcement(packet.payload)
    if not verify_signature(ap.signing_public_key, packet): return
    peer_id_derived = sha256(ap.noise_public_key)[:8]
    engine.peers[peer_id_derived] = PeerInfo(
        peer_id=peer_id_derived, nickname=ap.nickname,
        noise_public_key=ap.noise_public_key,
        signing_public_key=ap.signing_public_key,
        connected=true, last_seen=now()
    )
    engine.link_to_peer[link.id] = peer_id_derived
    engine.peer_to_link[peer_id_derived] = link.id
    engine.event_sink.emit(PeerConnected(peer_id_derived, ap.nickname))
    engine.topology.update_neighbors(sender_id, ap.neighbors)
    flush_directed_spool(engine, peer_id_derived)

function handle_noise_encrypted(engine, packet, sender_id):
    session = engine.noise.sessions.get(sender_id)
    if session is None: return
    plaintext = decrypt(session.recv_cipher, packet.payload)
    payload_type = plaintext[0]
    body = plaintext[1:]
    match payload_type:
        PRIVATE_MESSAGE  -> engine.event_sink.emit(PrivateMessage(sender_id, body.decode()))
        READ_RECEIPT     -> engine.event_sink.emit(ReadReceipt(sender_id, body.decode()))
        DELIVERED        -> engine.event_sink.emit(DeliveryAck(sender_id, body.decode()))
        VERIFY_CHALLENGE -> handle_verify_challenge(engine, sender_id, body)
        VERIFY_RESPONSE  -> handle_verify_response(engine, sender_id, body)
```

---

## Initialization

```
function create_node(adapter: RadioAdapter, keychain: Keychain) -> MeshEngine:
    static_priv, static_pub = keychain.load_or_generate_x25519_keypair()
    sign_priv, sign_pub     = keychain.load_or_generate_ed25519_keypair()
    my_peer_id              = sha256(static_pub)[:8]
    noise  = NoiseEngine(static_priv, static_pub, sign_priv, sign_pub)
    engine = MeshEngine(adapter, noise, my_peer_id)
    adapter.set_on_link_up(engine.on_link_up)
    adapter.set_on_link_down(engine.on_link_down)
    adapter.set_on_receive(engine.on_receive)
    adapter.start_advertising(SERVICE_UUID, CHAR_UUID)
    adapter.start_scanning(SERVICE_UUID)
    schedule_recurring(every=30s): send_broadcast(engine, ANNOUNCE, encode_announcement(engine))
    schedule_recurring(every=5s):  engine.fragments.evict_stale()
    schedule_recurring(every=5s):  engine.maintenance_tick()
    return engine
```

---

## Key constants from BLEService / TransportConfig

    DEFAULT_TTL           = 7
    TTL_FRAG_CAP          = 5
    DEFAULT_FRAGMENT_SIZE = 469     // ~512 MTU minus overhead
    MAX_IN_FLIGHT_ASSEMBLIES = 128
    HIGH_DEGREE_THRESHOLD = 6       // above this, adapt TTL / probabilistic relay
    MAX_CENTRAL_LINKS     = 6
    ANNOUNCE_MIN_INTERVAL = 1.0s
    MAINTENANCE_INTERVAL  = 5.0s
    DUTY_ON_DURATION      = 5.0s
    DUTY_OFF_DURATION     = 10.0s
    RSSI_FLOOR            = -90 dBm
    DIRECTED_SPOOL_WINDOW = see TransportConfig.bleDirectedSpoolWindowSeconds
