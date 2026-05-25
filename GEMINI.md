# SafeGuardian iOS - Project Instructions

## Architecture & State
- **Projection Model**: `ChatViewModel.messages` is a visible projection, not the source of truth.
- **Source of Truth**: The real state lives in `PublicTimelineStore` (for mesh/location channels) and `privateChats` (for DMs).
- **Message Injection Mechanics**:
    - `addPublicSystemMessage(_:)` appends to the store and calls `refreshVisibleMessages()`, which overwrites the visible projection wholesale.
    - `addLocalPrivateSystemMessage(_:to:)` appends to `privateChats` and relies on `objectWillChange.send()` for reactive UI updates.
    - `addLocalMessage(_:)` appends directly to the projection and is ephemeral (lost on channel switch).

## Core vs. Extension Preservation
- **OG Bitchat Core**: Do NOT refactor or split files that were part of the original "bitchat" core (e.g., `BLEService.swift`, `NoiseProtocol.swift`, `BinaryProtocol.swift`). These files are considered foundational and should remain unchanged except for critical bug fixes.
- **SafeGuardian Extensions**: The 150-line modularity rule and architectural refactors (like the Command Registry) apply ONLY to SafeGuardian-specific additions (e.g., Nova features, WorldGraph integration, QR verification, and newly created UI components).

## Conventions
- **Naming**: Always use `SafeGuardian` prefix for types (e.g., `SafeGuardianMessage`, `SafeGuardianPacket`) and file paths. Avoid legacy `Bitchat` or `bitchat` naming in new code or documentation.
- **Test Harness**: Use `MockBLEService` in `SafeGuardianTests/Mocks/` for integration testing. Always call `MockBLEService.resetTestBus()` in `setUp()`.
- **Refactoring & Modularity**: When splitting files to adhere to the 150-line limit:
    - Proactively promote `private` or `fileprivate` symbols used across files to `internal` (by removing the access modifier).
    - Move extensions to the home file of the type they extend (e.g., `ChannelID` extensions should live in `LocationChannel.swift`).
    - Always run a build immediately after splitting files to verify module-wide visibility.
