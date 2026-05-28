# Nova Agent UI Bug Analysis — Resolved

All eight issues documented here have been fixed. This file is retained as a record of root causes and the reasoning behind each fix.

Cross-referenced against: clean bitchat upstream at `/Users/m1a4xnetworkprobe./Applications/bitchat` and SafeGuardian source.

---

## HIGH — Nova responses appear in public feed [FIXED]

`ChatViewModel+AgentContext.swift` — `addResponse()` now conditionally appends: when `privatePeerID` is non-nil, the message goes only into `privateChats[peerID]`; when nil, it goes into `messages[]`. The unconditional append to `messages[]` was removed.

---

## HIGH — Streaming updates never render [FIXED]

`MessageRowView.swift` — `MessageDisplayItem` previously compared `lhs.message.content == rhs.message.content` where both sides held the same class reference, so they always read the same live property and the comparison was always true. Fixed by adding `contentSnapshot: String` and `deliveryStatusSnapshot: DeliveryStatus?` fields that capture values at `MessageDisplayItem` creation time. `.equatable()` now correctly detects content changes between render cycles.

The original analysis misidentified the bug as missing content in the equality check. The actual problem was that comparing a live class property against itself through the same reference is always equal regardless of what that property contains.

---

## HIGH — Formatting cache locks in stale content [FIXED]

`SafeGuardianMessage.swift` — `content` now has `didSet { _cachedFormattedText.removeAll() }`. Every mutation (streaming token) invalidates the cache, forcing `formatMessageAsText` to re-render from current content on the next call.

---

## HIGH — Status messages appear in public feed [FIXED]

`AgentContext` protocol (`AgentProcessor.swift`) gained `addAgentLocalMessage(_:to:)`, implemented in `ChatViewModel+AgentContext.swift`. It creates a `sender: "local"` message and appends it directly to `privateChats[peerID]`, bypassing the `selectedPrivateChatPeer` lookup that caused `addLocalMessage` to fall through to the public feed. `NovaAgent` now calls `addAgentLocalMessage` instead of `addLocalMessage`.

`startPrivateChat(with: agent.peerID)` is called before `agent.handle()` in the dispatch loop. This does not affect message routing — `addAgentLocalMessage` initializes `privateChats[peerID]` itself if needed. The ordering matters for navigation: the UI sheet opens to the correct DM before the first response appears.

---

## MEDIUM — No UI entry point to the Nova thread [FIXED]

`ContentView.swift` — added an agents section to the sidebar that iterates `viewModel.agents` and shows a row for each agent whose `privateChats[agent.peerID]` is non-empty. Tapping calls `viewModel.startPrivateChat(with: agent.peerID)`. Adding a second agent requires no UI changes.

---

## MEDIUM — Nova DM header shows "unknown" [FIXED]

`ContentView.swift` — `makePrivateHeaderContext` now checks `viewModel.agents` first before falling through to the peer/mesh/identity resolution chain. When the private peer ID matches an agent, `agent.displayName` is returned immediately.

---

## MEDIUM — User turns styled as system messages [FIXED]

`ChatViewModel.swift` — agent user turns are now stored with `sender: nickname` instead of `sender: "local"`. `MessageFormattingEngine` hits the self-message path and renders them with the correct orange alignment. `sender: "local"` is reserved for device-generated status output.

---

## LOW/MEDIUM — Tap-to-mention inserts invalid handles [FIXED]

`MessageListView.swift` — the tap handler now checks `viewModel.agents.contains(where: { $0.peerID.id == message.sender || $0.displayName == message.sender })` and skips mention insertion when true. This catches Nova response messages (sender `"Nova"`, matched by `displayName`) and defensively handles any stale messages with `sender: "nova-local"` (matched by `peerID.id`). User turns in agent DMs have `sender: nickname` — neither condition matches, so tapping them inserts `@nickname`, which is the user's own handle and is harmless.

---

## Additional issue found during verification — Follow-up messages silently dropped [FIXED]

Not in the original list. When the user was already in an agent DM and typed a follow-up without the trigger prefix, `sendMessage` fell through the agent routing loop (since `shouldHandle` returned false) and reached `sendPrivateMessage(content, to: selectedPeer)`, which attempted to send the message over BLE to the synthetic peer. The message was dropped.

`ChatViewModel.swift` — the agent routing loop now also checks `selectedPrivateChatPeer == agent.peerID`. When this is true the message is routed to the agent without requiring the trigger prefix, enabling natural multi-turn conversation.

---

## Summary

| # | Severity | Root cause | Fix location |
|---|----------|-----------|--------------|
| 1 | HIGH | addResponse unconditional append | ChatViewModel+AgentContext.swift |
| 2 | HIGH | MessageDisplayItem compared live property to itself | MessageRowView.swift — contentSnapshot |
| 3 | HIGH | Format cache not invalidated on content mutation | SafeGuardianMessage.swift — content didSet |
| 4 | HIGH | addLocalMessage routed status to public feed | NovaAgent.swift + ChatViewModel+AgentContext.swift — addAgentLocalMessage |
| 5 | MEDIUM | No sidebar entry for synthetic agents | ContentView.swift — agents section |
| 6 | MEDIUM | Header resolution skipped agent peers | ContentView.swift — makePrivateHeaderContext |
| 7 | MEDIUM | User prompts stored as sender "local" | ChatViewModel.swift — sender: nickname |
| 8 | LOW | Tap-to-mention fired on agent messages | MessageListView.swift — isAgentMessage guard |
| 9 | MEDIUM | Follow-up without prefix fell through to BLE | ChatViewModel.swift — inAgentDM check |
