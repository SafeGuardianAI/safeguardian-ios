# Bitchat Provenance

This document records which Swift source files are SafeGuardian additions versus files that existed in the upstream permissionlesstech/bitchat fork at the point of the rebranding baseline commit (50cd9ed, 2026-05-24).

## SafeGuardian Additions (net-new files)

These files did not exist in bitchat. They are wholly SafeGuardian work.

### Nova agent and inference
- `SafeGuardian/Features/nova/NovaAgent.swift`
- `SafeGuardian/Features/nova/NovaConfig.swift`
- `SafeGuardian/Features/nova/NovaInferenceCoordinator.swift`
- `SafeGuardian/Features/nova/NovaSessionPool.swift`
- `SafeGuardian/Features/nova/MLXInferenceService.swift`
- `SafeGuardian/Features/nova/MLXModelLoader.swift`
- `SafeGuardian/Features/nova/NovaBroadcaster.swift`
- `SafeGuardian/Features/nova/NovaStateTick.swift`
- `SafeGuardian/Protocols/AgentProcessor.swift`
- `SafeGuardian/ViewModels/Extensions/ChatViewModel+AgentContext.swift`

### IPC / headless TUI host
- `SafeGuardian/main.swift`
- `SafeGuardian/SafeGuardianDaemonDelegate.swift`
- `SafeGuardian/SafeGuardianIPCHost.swift`
- `SafeGuardian/SafeGuardianIPCHost+Subscriptions.swift`

### Command system (refactored out of CommandProcessor into per-command files)
- `SafeGuardian/Services/Commands/Command.swift`
- `SafeGuardian/Services/Commands/BlockCommand.swift`
- `SafeGuardian/Services/Commands/ClearCommand.swift`
- `SafeGuardian/Services/Commands/EmoteCommand.swift`
- `SafeGuardian/Services/Commands/FavCommand.swift`
- `SafeGuardian/Services/Commands/GPSCommand.swift`
- `SafeGuardian/Services/Commands/MessageCommand.swift`
- `SafeGuardian/Services/Commands/UnblockCommand.swift`
- `SafeGuardian/Services/Commands/WhoCommand.swift`

### UI decomposition (split out of upstream monolithic views)
- `SafeGuardian/Views/MessageListView+Handlers.swift`
- `SafeGuardian/Views/MessageListView+Helpers.swift`
- `SafeGuardian/Views/MessageListView+Scroll.swift`
- `SafeGuardian/Views/MessageListView+URL.swift`
- `SafeGuardian/Views/MessageRowView.swift`

### Autocomplete model
- `SafeGuardian/Models/AutocompleteSuggestion.swift`

### Tests
- `SafeGuardianTests/NovaIntegrationTests.swift`

## Bitchat Origin (modified in place)

All other Swift files in `SafeGuardian/`, `SafeGuardianTests/`, and `localPackages/` existed in the upstream bitchat repo and have been modified to varying degrees — renamed symbols, bug fixes, feature extensions — but their provenance is upstream. The most heavily modified are `BLEService.swift`, `ChatViewModel.swift`, `ContentView.swift`, `CommandProcessor.swift`, and the Noise protocol stack.
