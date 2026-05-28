# Nova Agent UI Bug Analysis

Cross-referenced against: clean bitchat upstream at `/Users/m1a4xnetworkprobe./Applications/bitchat` and SafeGuardian source. All findings are sourced to specific file and line.

---

## HIGH — Nova responses appear in public feed

`ChatViewModel+AgentContext.swift:15` — `addResponse()` always appends to `messages[]` unconditionally, even when a `privatePeerID` is provided. `ContentView` passes `messages` to `MessageListView` when no private peer is selected (`getMessages(for: nil)` returns `messages` directly). Result: every Nova response surfaces in the main public chat feed alongside real mesh messages.

Upstream bitchat has no agents; system messages use `addSystemMessage()` which correctly targets `messages[]` for network-scoped events only.

---

## HIGH — Streaming updates never render

`MessageRowView.swift:15-19` — `MessageDisplayItem.Equatable` checks `lhs.id == rhs.id && lhs.message === rhs.message && lhs.message.deliveryStatus == rhs.message.deliveryStatus`. It uses object identity (`===`), not content comparison. `MessageListView.swift:63` applies `.equatable()`, which tells SwiftUI to skip the redraw when Equatable returns true. `NovaAgent.swift:41+` mutates `response.content` in place during streaming without replacing the object reference. Because identity never changes, SwiftUI considers the row unchanged and never redraws. The user sees `[thinking...]` permanently.

---

## HIGH — Formatting cache locks in stale content

`SafeGuardianMessage.swift:38` — the per-message formatted-text cache is keyed only by `"\(isDark)-\(isSelf)"`. `MessageFormattingEngine.swift:111` checks this cache before doing any formatting work. The first format call populates the cache with `[thinking...]`; subsequent streaming mutations to `content` never invalidate it because the cache key does not include message identity or a content hash. Upstream bitchat has the same cache structure but messages are immutable once inserted, so the cache is always valid there.

---

## HIGH — Status messages appear in public feed

`NovaAgent.swift:21,28` calls `context.addLocalMessage()` during model loading. `ChatViewModel.swift:1384-1393` — `addLocalMessage()` routes to `privateChats[selectedPrivateChatPeer]` if one is selected, otherwise to `messages[]`. `ChatViewModel.swift:1010-1019` — the `@nova` dispatch path never calls `startPrivateChat(with:)`, so `selectedPrivateChatPeer` is nil at the moment the status fires. Result: "nova · loading..." appears in the public mesh feed.

---

## MEDIUM — No UI entry point to the Nova thread

`MeshPeerList.swift:23` populates from `viewModel.allPeers`, which is driven by the BLE mesh service. `nova-local` is a synthetic `PeerID` never added to `allPeers`. `ContentView.swift:528-543` — the people sheet only shows geo or mesh peers. No code anywhere calls `startPrivateChat(with: agent.peerID)`. The Nova conversation exists in `privateChats[nova-local]` but is inaccessible from the UI.

---

## MEDIUM — Nova DM header shows "unknown"

`ContentView.swift:737-785` (`makePrivateHeaderContext`) resolves a display name through: GeoDM check → `peer?.displayName` → `meshService.peerNickname()` → FavoritesPersistenceService → identityManager → fallback "unknown". `nova-local` matches none of these paths and falls through to the string "unknown".

---

## MEDIUM — User turns styled as system messages

`ChatViewModel.swift:1016` stores the user's `@nova` prompt as `SafeGuardianMessage(sender: "local", ...)`. `MessageFormattingEngine.swift:121-122` routes `sender == "local"` to `formatLocalMessage()`, which renders teal italic with asterisk wrapping — the style intended for device-generated output (GPS coordinates, status). Per CLAUDE.md, `sender: "local"` is for device-private feedback, not user input. Upstream bitchat uses the user's actual nickname for all user-authored messages.

---

## LOW/MEDIUM — Tap-to-mention inserts invalid handles

`MessageListView.swift:84-88` — tap handler does `messageText = "@\(message.sender) "`. Nova response messages have `sender == "nova-local"`, producing `@nova-local `. User turns have `sender == "local"`, producing `@local `. Neither is a valid mesh handle.

---

## Summary

| # | Severity | Root cause file | Effect |
|---|----------|----------------|--------|
| 1 | HIGH | ChatViewModel+AgentContext.swift:15 | Nova replies in public feed |
| 2 | HIGH | MessageRowView.swift:15-19 | Streaming never redraws |
| 3 | HIGH | SafeGuardianMessage.swift:38 | Cache locks to [thinking...] |
| 4 | HIGH | ChatViewModel.swift:1384-1393 | Status messages in public feed |
| 5 | MEDIUM | MeshPeerList.swift:23 | No way to open Nova thread |
| 6 | MEDIUM | ContentView.swift:737-785 | Header shows "unknown" |
| 7 | MEDIUM | MessageFormattingEngine.swift:121 | User prompts styled as system text |
| 8 | LOW | MessageListView.swift:86 | Bad @mention on tap |
