# MLX Swift Integration Gotchas

This document records non-obvious issues encountered during the Nova MLX integration. Each entry states the symptom, the root cause, and the fix so future developers don't repeat the same debugging path.

## MLXHuggingFace macros require two packages that mlx-swift-lm does not pull in itself

Symptom: build errors in macro-expanded files — `cannot find 'HubClient' in scope`, `cannot find type 'HuggingFace' in scope`, `cannot find 'Tokenizers' in scope`. These appear in generated files named `@__swiftmacro_...hubDownloader...` and `...huggingFaceTokenizerLoader...`, which makes them hard to trace back to the actual source.

Root cause: `#hubDownloader()` and `#huggingFaceTokenizerLoader()` are expression macros defined in `MLXHuggingFace`. The code they expand to directly references `HuggingFace.HubClient` (Hugging Face Hub API client) and `Tokenizers.AutoTokenizer` (tokenizer loader). These types come from two separate packages — `swift-huggingface` and `swift-transformers` — that are not declared as dependencies in `mlx-swift-lm`'s own `Package.swift`. The library assumes the consuming project provides them. The macro source file (`Libraries/MLXHuggingFace/Macros.swift`) has inline comments saying `import HuggingFace` and `import Tokenizers`, but these appear as code comments inside the macro output, not as compiler directives, so the Swift compiler does not enforce them until expansion time.

Fix: add `swift-huggingface` and `swift-transformers` as explicit SPM dependencies in the Xcode project, then add `import HuggingFace` and `import Tokenizers` to any file that calls those macros.

## swift-transformers product name is Transformers, not Tokenizers

Symptom: adding a product named `Tokenizers` to the Xcode project target fails with "Missing package product 'Tokenizers'".

Root cause: `Tokenizers` is a build target (module) within the `swift-transformers` package. The library product exposed for SPM consumption is named `Transformers` (it bundles the `Tokenizers`, `Generation`, and `Models` targets). The `Tokenizers` module becomes importable once the `Transformers` product is linked.

Fix: use `productName = Transformers` in `project.pbxproj`, not `Tokenizers`.

## Use ChatSession, not container.perform, for text generation

Symptom: `Capture of 'userInput' with non-Sendable type 'UserInput' in a '@Sendable' closure`.

Root cause: `UserInput` is not `Sendable` because it can hold `CIImage` and `AVAsset` values. `ModelContainer.perform` requires a `@Sendable` closure, so capturing `userInput` triggers a Swift concurrency error.

Fix: use `ChatSession.streamResponse(to:)` instead. `ChatSession` constructs `UserInput` internally using `SendableBox` to handle the Sendable requirement. It returns an `AsyncThrowingStream<String, Error>` that is straightforward to iterate. This API also maintains the conversation KV cache across turns, which is the correct behavior for a stateful chat session. Reserve `container.perform` for lower-level tasks like embeddings or custom generation loops.

## macOS deployment target must be 14.0

Symptom: `Compiling for macOS 13.0, but module 'MLX' has a minimum deployment target of macOS 14` on every file that imports an MLX module. `@Observable` produces a separate availability error because it also requires macOS 14.

Fix: set `MACOSX_DEPLOYMENT_TARGET = 14.0` in `Configs/Release.xcconfig`. Both errors resolve together.

## SafeGuardianMessage.content must be var for streaming

Symptom: `left side of mutating operator isn't mutable: 'content' is a 'let' constant` when attempting `response.content += token` inside the token callback.

Root cause: `SafeGuardianMessage.content` was originally declared `let`. Because `SafeGuardianMessage` is a `final class`, a stored reference remains valid throughout streaming, but a `let` property on a class still cannot be mutated after initialization.

Fix: change `public let content: String` to `public var content: String` in `localPackages/BitFoundation/Sources/BitFoundation/SafeGuardianMessage.swift`. This does not affect Codable encoding or wire protocol behavior. The `deliveryStatus` property was already `var` for the same reason (post-send mutation).

## privateChats is keyed by PeerID, not String

Symptom: `cannot convert value of type 'String' to expected argument type 'PeerID'` when accessing `privateChats["nova-local"]`.

Root cause: `privateChats` on `ChatViewModel` is declared `[PeerID: [SafeGuardianMessage]]`. `PeerID` is a struct in `BitFoundation`, not a typealias for `String`.

Fix: use `PeerID(str: "nova-local")` to construct the key. `PeerID` has a public `init(str:)` convenience initializer that accepts any `StringProtocol` and normalizes it to lowercase. Declare the constant as `static let novaPeerID = PeerID(str: "nova-local")` and reference `Self.novaPeerID` throughout the extension. Remember to `import BitFoundation` in the extension file.

## Qwen3 chain-of-thought causes RAM exhaustion and no visible output

Symptom: memory spikes to several gigabytes within seconds of a prompt, CPU pegs to 100%, and the UI shows `[thinking...]` for the entire duration with no visible tokens, eventually displaying `[no response]`.

Root cause: Qwen3 models default to chain-of-thought mode, emitting thousands of `<think>...</think>` tokens before producing any visible output. The original per-token callback accumulated the full streamed string and reprocessed it from scratch on each token (O(n²) in token count), while a `Task { @MainActor in }` dispatch was spawned for every token. With 5,000 or more think tokens, this produces tens of millions of string operations and an equal number of task allocations before the model emits a single visible character. The `drainVisible` function correctly suppresses the think blocks, so the UI updates stayed on `[thinking...]` throughout.

Fix: append `\n/no_think` to every system prompt. This is the model-level instruction to skip chain-of-thought entirely, and it is the only correct solution — a token cap cannot substitute for it because a cap set low enough to prevent runaway generation is also low enough to truncate real responses. `NovaConfig.noThinkSuffix` holds this value and `NovaAgent` appends it to every system prompt it constructs. `GenerateParameters.maxTokens` is left at its default `nil` (uncapped) because the cap is model-dependent and unnecessary once think-mode is disabled.

## SourceKit false positives on MLX files

SourceKit consistently reports "no such module 'MLX'" and "Loading the standard library failed" on files that import MLX modules. These are spurious diagnostics caused by the xcframework and local package setup and do not represent real errors. The only reliable build signal is `xcodebuild ... build 2>&1 | grep "error:"`. Never act on SourceKit diagnostics alone when working with MLX.
