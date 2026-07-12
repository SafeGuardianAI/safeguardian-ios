<img width="256" height="256" alt="icon_128x128@2x" src="https://github.com/user-attachments/assets/90133f83-b4f6-41c6-aab9-25d0859d2a47" />

## SafeGuardian iOS — Nova

A decentralized peer-to-peer messaging app with no accounts, no phone numbers, and no central servers, built as a fork of [permissionlesstech/bitchat](https://github.com/permissionlesstech/bitchat), rebranded and extended for the SafeGuardian platform. This app is one possible host for a Nova-tier mesh agent: the civilian-owner-bound, lowest-privilege tier in the SafeGuardian mesh protocol. Nova the tier is not defined by this app, by Swift, or by any specific inference runtime; it is defined by what the agent is bound to (the device owner) and what authority it holds on the mesh (observe and normalize, never issue or receive binding directives). See the monorepo root [CLAUDE.md](../../CLAUDE.md) for the full Nova/Trek/Apex tier ontology.

[safeguardian.ai](https://github.com/SafeGuardianAI)

## License

This project is released into the public domain. See the [LICENSE](LICENSE) file for details.

## Architecture: an agnostic mesh-agent design

Nova's identity cannot be tied to a device or an operating system; it is a cryptographic keypair, because a mesh has no central authority to vouch for who or what a participant is, and because that identity must survive a phone being replaced or a process restarting on an entirely different machine. A message cannot assume a live connection to its recipient; it is a self-contained, addressed, optionally encrypted envelope that can sit in a store on an intermediate node for an arbitrary length of time before being forwarded, because the physical links available in a mesh — Bluetooth LE, LoRa, Wi-Fi Direct, or an ordinary IP hop — are intermittent by nature rather than by failure.

An autonomous agent occupies its own address on the mesh, with its own inbox and its own conversational history, distinct from the address of the human or organization it belongs to, because two agents need to hold a thread with each other independent of whatever their owners' own clients are doing at that moment. That agent address is nonetheless subordinate to an owner identity rather than merely associated with it by convention: the agent's authority to act is delegated, not self-granted, and the delegation has to be provable by anyone who receives a message from it. The owner identity is a root keypair, held by the human. The agent identity is a second, independently generated keypair addressed by its own destination hash, which becomes meaningful to the rest of the mesh only once the owner signs an attestation over it: a small signed statement binding the agent's public key to the owner's public key, together with whatever scope of capability the owner is willing to extend. A peer receiving an envelope from an agent's destination hash verifies this attestation before deciding how much autonomy to extend to that conversation. The owner can re-issue or withdraw an attestation, and by extension retire or rotate an agent's keypair, without touching the owner's own identity, which matters once a device is compromised, wiped, or reprovisioned.

The component that decides what a received envelope means and what should be sent back sits behind an interface stable enough that the weights, the runtime, and the modality of input can all change without touching anything above that interface, since a capable on-device model takes image, audio, and location alongside text as ordinary input. Concretely in this app, that interface is `AnyLanguageModel` (see `localPackages/AnyLanguageModelKit`), an abstraction over MLX, a remote endpoint, or Apple Intelligence depending on device capability — that runtime choice is a property of the current host app, not of the Nova tier itself. No Core ML is used anywhere in this codebase.

One functional role covers proximate, no-infrastructure delivery: local peer discovery and store-and-forward exchange over Bluetooth LE with no server in the loop — this is the bitchat-originated BLE mesh, still the app's core transport. A second role covers addressed, delivery-confirmed messaging across many hops and many transport types, including propagation nodes that hold messages for a destination not currently reachable — this is Reticulum/LXMF, riding on the same BLE radio alongside the native bitchat protocol via `MultiTransportManager` (`shared/SafeGuardianMesh`), which also handles at-most-once delivery when a message arrives redundantly over both. A third role covers addressed, global-reach messaging when no local mesh peer is available — this is the Nostr integration (`ChatViewModel+Nostr.swift`), using geohash-based location channels over public relays as an internet fallback, independent of the BLE/Reticulum local mesh. The transport protocol bridging all physical tiers going forward is Reticulum — no other addressing fabric should be introduced.

## Repo structure

- `SafeGuardian/` — main app target (was `bitchat/` upstream)
- `SafeGuardianTests/` — test suite
- `SafeGuardianShareExtension/` — iOS share extension
- `localPackages/BitFoundation/` — shared protocol types: SafeGuardianMessage, SafeGuardianPacket, and related models
- `localPackages/BitLogger/` — SecureLogger wrapper around OSLog
- `localPackages/AnyLanguageModelKit/` — model-runtime abstraction (MLX / remote / Apple Intelligence)
- `localPackages/Arti/` — Tor integration via Rust/arti (pre-built xcframework)
- `Configs/` — xcconfig files; copy `Local.xcconfig.example` to `Local.xcconfig` for local builds
- `relays/` — Nostr relay CSV, updated weekly by CI from upstream
- `../../shared/SafeGuardianMesh/` — Reticulum/LXMF transport, `MultiTransportManager`, shared with trek-ios

## Git remotes

- `origin` → `SafeGuardianAI/safeguardian-ios` (our repo)
- `upstream` → `permissionlesstech/bitchat` (source fork, fetch-only)

To pull upstream changes: `git fetch upstream` then cherry-pick or merge specific commits. Do not push to upstream.

## Bundle identity

- Bundle ID: `chat.safeguardian`
- App Group: `group.chat.safeguardian`
- URL scheme: `safeguardian` (registered in Info.plist) — `safeguardian://user/` and `safeguardian://geohash/`
- Xcode team: `V9KH637N7P`

## Setup

### Option 1: Using Xcode

```bash
cd nova-ios
open SafeGuardian.xcodeproj
```

To run on a device there are a few steps to prepare the code:
- Clone the local configs: `cp Configs/Local.xcconfig.example Configs/Local.xcconfig`
- Set a unique `PRODUCT_BUNDLE_IDENTIFIER` in the newly created `Configs/Local.xcconfig`
- If you enable signing locally, add `DEVELOPMENT_TEAM = V9KH637N7P` to `Configs/Local.xcconfig`
- Keep `APP_GROUP_ID` aligned with the bundle identifier when enabling the share extension

Or directly:

```bash
xcodebuild \
  -project SafeGuardian.xcodeproj \
  -scheme SafeGuardian_iOS \
  -destination "generic/platform=iOS" \
  -configuration Debug \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=V9KH637N7P \
  -allowProvisioningUpdates \
  build
```

For device deployment, Developer Mode must be enabled on the target iPhone (Settings → Privacy & Security → Developer Mode).

### Option 2: Using `just`

```bash
brew install just
```

Want to try this on macOS: `just run` will set it up and run from source. Run `just clean` afterwards to restore things to original state for mobile app building and development. macOS builds require `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` because the Tor xcframework (`libarti_bitchat.a`) ships arm64 only — the Justfile `build` and `dev-run` recipes already include these flags.

## Intentionally preserved upstream strings

The following strings are from the wire protocol and must not be renamed, or interoperability with other bitchat mesh nodes breaks:

- `bitchat1:` — prefix for Nostr-embedded mesh packets
- `bitchat.nickname`, `bitchat.noiseIdentityKey`, `bitchat.messageRetentionKey` — UserDefaults keys persisted on device

The KeychainManager migration arrays listing `"chat.bitchat.*"` service names are also intentional — they enumerate legacy keychain namespaces to delete during an account reset.

## Type naming

All Bitchat-prefixed types have been renamed to SafeGuardian-prefixed equivalents:

| Old | New |
|-----|-----|
| BitchatApp | SafeGuardianApp |
| BitchatMessage | SafeGuardianMessage |
| BitchatPeer | SafeGuardianPeer |
| BitchatPacket | SafeGuardianPacket |
| BitchatFilePacket | SafeGuardianFilePacket |
| BitchatDelegate | SafeGuardianDelegate |

## Localization

- Base app resources live under `SafeGuardian/Localization/Base.lproj/`. Add new copy to `Localizable.strings` and plural rules to `Localizable.stringsdict`.
- Share extension strings are separate in `SafeGuardianShareExtension/Localization/Base.lproj/Localizable.strings`.
- Prefer keys that describe intent (`app_info.features.offline.title`) and reuse existing ones where possible.
- Run `xcodebuild -project SafeGuardian.xcodeproj -scheme "SafeGuardian (macOS)" -configuration Debug CODE_SIGNING_ALLOWED=NO build` to compile-check any localization updates.

## Diagnostics note

SourceKit frequently emits "Internal SourceKit error: Loading the standard library failed" on files after edits in this project due to the xcframework and local package setup. These are spurious IDE diagnostics. The only reliable build signal is `xcodebuild ... build 2>&1 | grep "error:"`. Always verify with an actual build before concluding code is broken.
