# SafeGuardian iOS — Feature Development Guide

This document describes the concrete mechanics of adding new behaviors to the SafeGuardian iOS app. It is organized around the three most common extension points: chat commands, local-only UI feedback, and new services that attach to the view model. Each section walks through a real example drawn from existing code so the pattern can be followed without guesswork.

---

## Mental model: how the app is layered

The app follows a straightforward MVVM structure. `ChatViewModel` is the single coordinator between the UI and all backend services. Views observe `ChatViewModel` via `@EnvironmentObject` and call methods on it. `ChatViewModel` delegates to specialized services (`BLEService`, `CommandProcessor`, `NostrRelayManager`, etc.) and publishes state changes back up via `@Published` properties.

The rule for where to put new code is: if it has network or crypto side effects, it belongs in a `Service`. If it is pure state transformation or routing logic, it belongs in `ChatViewModel` or a `ChatViewModel` extension. If it is rendering logic, it belongs in a `View` or `MessageFormattingEngine`. Do not reach down from a view directly into a service.

---

## Adding a debug-only command

Debug commands follow the same `Command` protocol as production commands but are gated `#if DEBUG` throughout and registered in `CommandProcessor` under a `#if DEBUG` block. They do not appear in `CommandInfo` autocomplete because autocomplete is end-user facing. The file lives in `Services/Commands/` alongside production commands.

```swift
#if DEBUG
@MainActor
struct MyDevCommand: Command {
    let names = ["/mydev"]
    let usage = "/mydev [subcommand]"

    func execute(args: String, context: CommandContext) -> CommandResult {
        context.provider?.addLocalMessage("dev output")
        return .handled
    }
}
#endif
```

Register in `CommandProcessor` by appending inside the `#if DEBUG` block at the bottom of the `commands` closure. No other file changes are needed. See `LogCommand.swift` as the canonical example.

---

## Adding a chat command

A command is a slash-prefixed string the user types in the chat input (e.g. `/gps`, `/block alice`). Commands are processed by `CommandProcessor` and their output appears as messages in the timeline. Adding one requires touching four files in a fixed order.

### Step 1 — declare the command in `CommandInfo.swift`

`CommandInfo` is the enum that drives autocomplete suggestions. Add a new case. If your command takes an argument, set `placeholder` to a short string describing it (e.g. `"[p]"`, `"<nickname>"`). If it has no argument, return `nil`. Add the case to the `all(isGeoPublic:isGeoDM:)` return value; if the command only makes sense on certain channel types, gate it there like `.favorite` and `.unfavorite` are.

```swift
case gps

var placeholder: String? {
    switch self {
    case .gps: return "[p]"
    // ...
    }
}

var description: String {
    switch self {
    case .gps: String(localized: "content.commands.gps")
    // ...
    }
}
```

### Step 2 — add the localization key in `Localizable.xcstrings`

The `description` property must resolve to a localized string. Add a new key between existing `content.commands.*` entries (they are alphabetical). For a new command that has not been translated yet, provide only English with `"extractionState": "manual"`. The full block looks like:

```json
"content.commands.gps" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "show location; p to share publicly"
      }
    }
  }
}
```

Xcode will flag missing translations automatically. Do not invent translations for languages you do not speak.

### Step 3 — add a handler in `CommandProcessor.swift`

`CommandProcessor.process(_:)` is a `switch` over the command string. Add a case and call a private handler:

```swift
case "/gps":
    return handleGPS(args)
```

Write the handler as a private method. It receives `args` (everything after the command name, trimmed) and returns a `CommandResult`. The three result cases are `.success(message:)` (inject a system message), `.error(message:)` (inject an error system message), and `.handled` (no message injected — the handler already took care of it directly via `contextProvider`).

If your handler needs to read app state or call app methods, use `contextProvider` (a `CommandContextProvider` reference). The protocol is defined at the top of `CommandProcessor.swift`. If you need something not already on that protocol, add it there and implement it in `ChatViewModel`. The GPS command needed `addLocalMessage` and `promptGPSShare` — those were added to the protocol and implemented in `ChatViewModel`.

If your handler needs to reach an iOS framework (e.g. `CoreLocation`), add the import at the top of `CommandProcessor.swift`. The file does not transitively import UIKit or SwiftUI, so framework imports must be explicit.

### Step 4 — implement `CommandContextProvider` methods in `ChatViewModel`

If you added methods to `CommandContextProvider` in the previous step, implement them in `ChatViewModel.swift` or an appropriate extension under `ViewModels/Extensions/`. The pattern for routing output depends on context:

- Network action (send to mesh): call `sendPublicRaw(_:)` or `sendPrivateMessage(_:to:)`
- Local system event: call `addSystemMessage(_:)` or `addPublicSystemMessage(_:)` depending on whether it should persist across channel switches
- Device-private output: call `addLocalMessage(_:)` — see the local message section below
- Private chat action: mirror the pattern in `addLocalPrivateSystemMessage(_:to:)`

---

## Local-only messages

Some command output should never leave the device — GPS coordinates shown to the user before they choose to share, status feedback from commands. These use `sender: "local"` in `SafeGuardianMessage` and are injected via `addLocalMessage(_:)`. `MessageFormattingEngine` renders `sender == "local"` in teal italic — distinct from the gray italic of `sender == "system"`. The color convention is: orange = your own sent messages, gray = system/network events, teal = device-private.

Local messages are ephemeral. They are appended directly to `messages` and do not go through the `PublicTimelineStore`, so they disappear when the user switches channels. This is intentional — they are not part of the mesh timeline.

Agent status messages (loading state, errors) use a different method, `addAgentLocalMessage(_:to:)`, which routes the `sender: "local"` message into a specific agent's private chat thread rather than the main feed. Use this instead of `addLocalMessage` whenever the feedback belongs to an agent interaction.

---

## Adding an agent

Agents are on-device or cloud-connected processors that intercept trigger-prefixed messages (e.g. `@nova`) and respond via a synthetic private chat thread. The system is intentionally generic: adding an agent means conforming to two protocols and registering the instance. No routing code, sidebar code, or header-resolution code needs to change.

The two protocols are in `SafeGuardian/Protocols/AgentProcessor.swift`.

`AgentProcessor` has a single required property: `conversationConfig: AgentConversationConfig`. All identity fields — `agentID`, `displayName`, `peerID`, `triggerPrefix` — are derived from it as default protocol implementations. Conforming types only need to supply a `conversationConfig`; the `handle(prompt:image:context:threadPeerID:replyTo:replyID:)` method is a protocol default that routes directly through `AgentConversationEngine.shared.handle(...)`. Conformers do not override `handle`.

- `conversationConfig.agentID` — unique lowercase key (e.g. `"nova"`).
- `conversationConfig.displayName` — shown in the sidebar and DM header (e.g. `"Nova"`).
- `conversationConfig.triggerPrefix` — the string the user types to address this agent (e.g. `"@nova"`).
- `conversationConfig.peerID` — the synthetic peer ID for this agent's DM thread. Must not collide with real BLE peer IDs.
- `shouldHandle(_ message: String) -> Bool` — returns true when the message is addressed to this agent.
- `handle(prompt:image:context:threadPeerID:replyTo:replyID:)` — default implementation; routes through `AgentConversationEngine.shared`, which calls gates, invokes the model provider, strips thinking blocks, and delivers the response via `context.addResponse` and `context.notifyChange`.

`AgentContext` is the restricted view of `ChatViewModel` exposed to agents. It provides `nickname`, `privateChats`, `deviceTick`, `selectedGeohash`, `addLocalMessage`, `addAgentLocalMessage`, `addResponse`, and `notifyChange`. Agents must not hold a direct reference to `ChatViewModel`.

To register an agent, add it to the `agents` array in `ChatViewModel.swift`:

```swift
let agents: [any AgentProcessor] = [Agent.nova, YourNewAgent()]
```

The `sendMessage` routing loop iterates `agents` and calls `shouldHandle` on each. It also intercepts follow-up messages sent while the user is already inside an agent's DM thread (without the trigger prefix), so multi-turn conversations work without requiring the user to re-type the prefix every turn.

Agent response messages use `sender: displayName`, not `sender: "local"`. The DM header and sidebar resolve the display name through `viewModel.agents`, so the name shown to the user always matches `displayName` on the protocol.

### Model capabilities

If your agent uses an LLM that supports thinking mode (chain-of-thought), register it in `NovaConfig.capabilities(for:)` in `SafeGuardian/Features/nova/NovaConfig.swift`. The `ModelCapabilities` struct carries four fields: `hasThinkingMode: Bool`, `noThinkSuffix: String?`, `supportsToolCalling: Bool`, and `supportsVision: Bool`. Prompt decoration is handled by `AgentPromptInput.decorated(modelID:)`, which appends the suppression suffix when present. For models where thinking cannot be suppressed via message text (e.g. DeepSeek-R1), set `noThinkSuffix: nil` and rely on the `<think>…</think>` drain in `AgentConversationEngine` to strip chain-of-thought blocks from the output.

---

## Timeline persistence and state

A common source of confusion for new developers is why their messages disappear when switching channels. The app uses a "projection" model for the UI:

- `ChatViewModel.messages` is the **visible projection**. It is what the SwiftUI `ForEach` actually iterates over.
- `PublicTimelineStore` is the **source of truth for public channels** (.mesh and .location). It maintains separate buffers for each channel ID.
- `ChatViewModel.privateChats` is the **source of truth for DMs**. It is a dictionary keyed by peer ID.

When the user switches channels, `refreshVisibleMessages(from:)` is called. It pulls the correct buffer from the source of truth and overwrites the `messages` array. If you append a message directly to `messages`, it exists only in the projection and will be lost on the next refresh.

### Choosing an injection method

The method you use to add a message determines its persistence and visibility:

1. **`addLocalMessage(_:)`**: Use this for ephemeral feedback (e.g., "/help" output, confirmation prompts). It appends only to the projection. It will be lost on channel switch.
2. **`addPublicSystemMessage(_:)`**: Use this for system events that should persist in the current public channel's history (e.g., "Connected to mesh"). It appends to the `PublicTimelineStore` and then triggers `refreshVisibleMessages()`, which overwrites the visible projection with the updated store content.
3. **`timelineStore.append(_:for:)`**: Used by background services when a network message arrives. This updates the source of truth; if the targeted channel is the `activeChannel`, the projection is updated via the delegate flow.
4. **`addLocalPrivateSystemMessage(_:to:)`**: Use this for system events in a DM thread. It appends to `privateChats` and calls `objectWillChange.send()`, allowing SwiftUI to reactively update the view if that peer is currently selected.

---

## Message rendering end-to-end

Message rendering flows through several layers of abstraction before reaching the screen:

1. **`SafeGuardianMessage`**: The unified model for all message types (mesh, nostr, system, local).
2. **`MessageListView`**: The primary container. It iterates over `viewModel.messages` and determines which high-level view to use.
3. **`TextMessageView`**: Handles all text-based content. It uses `viewModel.formatMessageAsText` to apply colors and styles based on the sender type. It also handles link extraction (Cashu, Lightning) and long-message truncation.
4. **`MediaMessageView`**: Handles images and voice notes. It manages the download/reveal state machine and coordinates with `BlockRevealImageView` or `VoiceNoteView`.

If you are adding a new visual element to messages (like a new chip or icon), you likely need to modify `TextMessageView.swift` or `MessageFormattingEngine.swift`.

---

## Inline confirmation flows

Some commands need user confirmation before taking a network action. Rather than a SwiftUI alert (which is appropriate for destructive system-level actions), commands that fit the IRC aesthetic use an inline y/n prompt that appears as a local message.

The pattern is a `Bool` flag on `ChatViewModel` that intercepts the next `sendMessage` call:

```swift
// ChatViewModel.swift
private var pendingGPSShareConfirmation = false

func promptGPSShare() {
    pendingGPSShareConfirmation = true
    addLocalMessage("share your location publicly? type y to confirm or n to cancel")
}
```

At the top of `sendMessage`, before the command check and before the public/private routing:

```swift
if pendingGPSShareConfirmation {
    handleGPSShareConfirmation(trimmed)
    return
}
```

The confirmation handler clears the flag on both y and n. On invalid input it re-injects the prompt without clearing the flag:

```swift
private func handleGPSShareConfirmation(_ input: String) {
    switch input.lowercased() {
    case "y":
        pendingGPSShareConfirmation = false
        // take the action
    case "n":
        pendingGPSShareConfirmation = false
        addLocalMessage("cancelled")
    default:
        addLocalMessage("type y to confirm or n to cancel")
    }
}
```

If you add another confirmation flow, follow this exact structure. Name the flag `pending<FeatureName>Confirmation` and place the intercept check at the top of `sendMessage` alongside the existing GPS check.

---

## Testing with MockBLEService

The app uses an in-memory networking harness for integration testing. This allows you to verify complex multi-node behaviors without touching production Bluetooth code.

- **File:** `SafeGuardianTests/Mocks/MockBLEService.swift`
- **Setup:** Call `MockBLEService.resetTestBus()` in your `setUp()` method.
- **Topology:** Create multiple `MockBLEService` instances and link them using `svc.simulateConnectedPeer("PEER_ID")`.
- **Observation:** Hook into `messageDeliveryHandler` to assert that messages reached their destination.

For details on simulating broadcast flooding, TTL behavior, and Noise rehandshakes, see **`SafeGuardianTests/README.md`**.

---

## Extending Nova behaviors

The Nova subsystem has two orthogonal extension surfaces: the device-state tick and the inference layer.

The tick (`NovaStateTick`) carries the ambient context injected as a prefix on every user message — battery level, geolocation, peer count. To add a new field: add it to `NovaStateTick.swift`, update `NovaBroadcaster.buildTick(batteryPct:)` to populate it, and update `AgentPromptInput.decorated(modelID:)` to include it in the injected prefix string. Ticks are built locally by `NovaBroadcaster` and stored in `latestTick` for tool and context use; avoid putting high-bandwidth data in them.

The inference layer is `MLXInferenceService` → `MLXInferenceCoordinator` → `MLXSessionPool`. The coordinator manages a single active generation task and a session cache keyed by model ID and system-prompt hash. Switching the active model (`MLXInferenceService.selectModel`) invalidates the session cache and the loader state machine, ensuring the next generation downloads and loads the new model cleanly.

To change how prompts are constructed without breaking session caching, modify `AgentPromptInput.decorated(modelID:)`. Device state is prepended as a bracketed prefix on the user message rather than injected into the system prompt, which keeps the session key (a hash of the stable system prompt) stable across state changes.

`NovaConfig` is the single source of truth for default model ID, temperature, timeout, idle release interval, the stable system prompt, and the model capability registry. Changes to the stable system prompt invalidate all cached sessions on the next generation call.

---

## Modularity and File Splitting

SafeGuardian enforces a strict **150-line limit** for all source files. When a view or service exceeds this limit, it must be split into smaller, focused files using Swift extensions.

### Best Practices for Splitting
1. **Access Control**: Swift's `private` and `fileprivate` modifiers are file-scoped. When moving code to a new file (e.g., `MessageListView+Scroll.swift`), you must remove these modifiers from shared symbols to give them `internal` (module-wide) visibility.
2. **Canonical Extensions**: If you are extending a shared type (like `ChannelID`), place that extension in the home file of the type (e.g., `LocationChannel.swift`) rather than at the bottom of a view file. This ensures the extension is discoverable and available to all components.
3. **Focused Extensions**: Group related logic into logical extensions (e.g., `+Scroll`, `+URL`, `+Handlers`) rather than arbitrary splits.
4. **Verification**: Always run `just build` or `xcodebuild` immediately after splitting files to catch visibility errors early.

---

## Adding a new service

When a feature requires a system permission (location, microphone, camera) and that permission is not granted, the response must distinguish between the three possible failure states and act on each one, not just describe the problem as text.

The three states and their correct responses are:

`.notDetermined` — the system has not asked yet. Call the appropriate request method immediately (e.g. `LocationStateManager.shared.enableLocationChannels()` which calls `requestWhenInUseAuthorization()`). Show a message telling the user to accept the incoming system dialog, then re-run the command. Do not tell the user to go somewhere to enable something; bring the prompt to them.

`.denied` — the user previously declined and the system will not ask again. Open the Settings app directly using `SystemSettings.location.open()` (or `.bluetooth`, `.microphone` as appropriate). Show a brief message confirming you are opening Settings. The `SystemSettings` enum handles both iOS and macOS.

`.restricted` — a device policy (MDM, parental controls) is blocking the permission. No programmatic action is possible. Show a message that states this clearly and does not instruct the user to change a setting they cannot change.

The anti-pattern to avoid is showing a string that describes the problem without taking any action. A message saying "enable in Settings > Privacy > Location" requires the user to leave the app, navigate a menu path from memory, and return — when `SystemSettings.location.open()` would have done it in one step. Similarly, a message saying "turn on location channels first" when the state is `.notDetermined` never triggers the system dialog that would actually resolve the situation.

Any feature that gates on a permission should follow this three-branch pattern at the point of use. Do not propagate a generic "permission missing" error upward and handle it with a string in the caller; handle all three cases at the command handler or service layer where the permission state is already being inspected.

---

## Adding a new service

A service is a class that encapsulates a discrete concern — a transport, a persistence layer, a hardware interface. To attach a new service to the app:

1. Create the service class under `Services/`. Conform it to a protocol that defines its interface (look at `Transport.swift` for an example of how protocols decouple services from their callers).
2. Instantiate it in `ChatViewModel.init` alongside the other services.
3. Wire it as a property on `ChatViewModel` if the UI or command handlers need to reach it. If it is purely internal to other services, inject it directly into those services rather than routing through the view model.
4. If the service emits events asynchronously, publish state changes back to the view model via a delegate protocol or a Combine publisher. `SafeGuardianDelegate` is the existing pattern for BLE events.

Do not call service methods directly from views. Views call methods on `ChatViewModel`; `ChatViewModel` coordinates with services.

---

## Adding a new view

The app has one primary content area (`ContentView.swift`) and a set of sheet and modal presentations hung off it. The `MessageListView` renders the timeline and delegates individual message rendering to `TextMessageView` (text), `MediaMessageView` (images/voice), and `WaveformView` (audio playback UI).

For new features that surface in the timeline as a new message type, the minimum path is: add a new rendering branch in `MessageListView`'s `ForEach` body that switches on a property of `SafeGuardianMessage`, and write a new SwiftUI view in `Views/` for the rendering. If the new message type needs a new field on `SafeGuardianMessage`, that type lives in `localPackages/BitFoundation` and any change there affects wire compatibility — discuss before changing.

For new features that surface as a new panel, sheet, or settings section, follow the existing sheet pattern in `ContentView.swift`: a `@State var showingX = false` binding, a `.sheet(isPresented:)` modifier, and a view that takes `@EnvironmentObject var viewModel: ChatViewModel`.

The general rule is to prefer adding to existing flows over introducing new navigation paths. A new command that outputs to the chat timeline is always preferable to a new screen if the use case fits.

---

## Permissions

`Info.plist` already declares Bluetooth, camera, microphone, photo library, and location (when in use). If a new feature needs an additional permission, add the usage description key to `Info.plist` and request authorization at the point of first use (not at launch). `LocationStateManager.enableLocationChannels()` is a good model for how to handle the notDetermined/denied/authorized state machine around a permission request.

Do not add `NSLocationAlwaysUsageDescription` — the app intentionally uses `WhenInUse` only.

---

## Build verification

The SourceKit indexer in this project frequently shows "Internal SourceKit error: Loading the standard library failed" after file edits. These are spurious and do not indicate a compiler error. Always verify with an actual build:

```
xcodebuild \
  -project SafeGuardian.xcodeproj \
  -scheme SafeGuardian_iOS \
  -destination "generic/platform=iOS" \
  -configuration Debug \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=V9KH637N7P \
  -allowProvisioningUpdates \
  build 2>&1 | grep "error:"
```

No output from that grep means a clean build. Do not treat SourceKit diagnostics as ground truth.
