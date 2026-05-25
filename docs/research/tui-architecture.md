# SafeGuardian Terminal User Interface (TUI) — Architecture & Implementation

_2026-05-24_

## Core Philosophy: The Agnostic CLI Surface

The SafeGuardian command-line interface is not a separate application, nor is it a bespoke collection of hardcoded terminal commands. It is designed as an **Agnostic Surface Layer** that runs directly inside the compiled macOS native binary.

To achieve zero-maintenance parity with the GUI, the TUI must adhere to these rules:

1. **Native Parity**: The CLI is invoked via a hidden flag (e.g., `--tui`) passed to the main `SafeGuardian.app` binary. This bypasses SwiftUI but boots the exact same memory space, MLX services, BLE delegates, and Keychain access as the GUI. No separate Xcode target is used.
2. **Dumb Input Pipe**: The TUI does not parse commands. Every line typed into standard input is passed blindly to `ChatViewModel.sendMessage(_:)`. All parsing (Nova routing, Trek tools, IRC commands) is handled by the core `CommandProcessor`.
3. **Reactive Output Pipe**: The TUI does not hook specific functions to print output. Instead, it uses the `Combine` framework to subscribe to the same `@Published` state properties that drive the SwiftUI views (e.g., `$messages`, `$availableChannels`, `$state`). When core state changes, the TUI simply serializes and prints it.
4. **Text-First Fallbacks**: Any GUI button click that lacks a text equivalent (like opening an image picker) must be refactored into a core `/command` (e.g., `/attach <path>`). The TUI never implements unique business logic.

## Implementation Checklist

This checklist is ordered from easiest/most foundational to most complex.

### Phase 1: The Native Swift Foundation
- [ ] **Clean Up Legacy CLI**: Delete the temporary `NovaCLI` target and `nova.py` script. Remove them from the `project.pbxproj` and `Justfile`.
- [ ] **Headless Bootloader**: Modify `SafeGuardianApp.swift` to intercept the `--tui` argument. If present, divert the launch sequence to a new `SafeGuardianTUI.run()` function and `exit(0)`, preventing SwiftUI from attempting to render windows.
- [ ] **Daemon Lifecycle**: Ensure `NetworkActivationService`, `GeohashPresenceService`, and `TorManager` are explicitly started in the headless bootloader, identical to the `.onAppear` block in the GUI.

### Phase 2: Basic I/O Wiring
- [ ] **Standard Output**: Create a custom `TextOutputStream` that safely handles terminal formatting and prevents overlapping writes during asynchronous network events.
- [ ] **The Read Loop**: Implement an asynchronous `while let line = readLine()` loop on a background thread that passes input strings directly to the initialized `ChatViewModel.sendMessage()`.
- [ ] **CLI Alias**: Update the `Justfile` to compile the macOS app and create a permanent symlink/alias (e.g., `safeguardian`) pointing to the internal app executable with the `--tui` flag.

### Phase 3: Reactive State Subscriptions
- [ ] **Message Stream**: Create a Combine subscriber on `ChatViewModel.$messages`. Write a diffing function that detects new messages, formats them via `formatMessageAsText()`, and prints them to the terminal.
- [ ] **Infrastructure Status**: Create Combine subscribers for `TorManager.shared.$state` and `LocationChannelManager.shared.$availableChannels`. Map these state changes to simple terminal status prints (e.g., `[System: Bootstrapping Tor 45%]`).
- [ ] **Nova Streaming Hooks**: Ensure the existing `objectWillChange.send()` pattern used by Nova's token streaming triggers terminal updates correctly without flooding the screen with duplicate text blocks.

### Phase 4: Text-First Feature Parity
- [ ] **Command Audit**: Audit GUI-only interactions (e.g., identity verification, media attachment, session resets).
- [ ] **Registry Expansion**: Add core `/commands` to `CommandProcessor` for any missing GUI actions so the TUI can trigger them seamlessly.