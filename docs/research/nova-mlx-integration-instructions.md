# Agent task: Add on-device Nova inference to SafeGuardian iOS

Working directory: /Users/m1a4xnetworkprobe./safeguardianai/safeguardian-ios

Do not read anything inside .build/. Do not edit Package.resolved — Xcode will regenerate it automatically. Read each file before editing it.

---
Step 1 — Edit SafeGuardian.xcodeproj/project.pbxproj

Read the file first. Then make exactly four string replacements using Edit, in this order.

Replacement 1 — add mlx-swift-lm to the project's packages list. Find this exact block: 

                      B8C407587481BBB190741C93 /* XCRemoteSwiftPackageReferenc */,
                      A6E3E56E2E77036A0032EA8A /* XCLocalSwiftPackageReference "localPackages/BitLogger" */,

Replace with:

                      CC1111111111111111111A01 /* XCRemoteSwiftPackageReferenc */,
                      B8C407587481BBB190741C93 /* XCRemoteSwiftPackageReferenc */,
                      A6E3E56E2E77036A0032EA8A /* XCLocalSwiftPackageReference "localPackages/BitLogger" */, 

Replacement 2 — add products to the iOS target. Find:

                      name = SafeGuardian_iOS;
                      packageProductDependencies = (
                              4EB6BA1B8464F1EA38F4E286 /* P256K */,
                              A6E3E56F2E77036A0032EA8A /* BitLogger */,
                              A6E3EA7E2E7706720032EA8A /* Tor */,
                              A6BCF9472F80953E001CF9B9 /* BitFoundation */,
                      );

Replace with:

                      name = SafeGuardian_iOS;
                      packageProductDependencies = (
                              4EB6BA1B8464F1EA38F4E286 /* P256K */,
                              A6E3E56F2E77036A0032EA8A /* BitLogger */,
                              A6E3EA7E2E7706720032EA8A /* Tor */,
                              A6BCF9472F80953E001CF9B9 /* BitFoundation */,
                              CC1111111111111111111A02 /* MLXLLM */,
                              CC1111111111111111111A03 /* MLXLMCommon */,
                              CC1111111111111111111A04 /* MLXHuggingFace */,
                      );

Replacement 3 — add products to the macOS target. Find:

                      name = SafeGuardian_macOS;
                      packageProductDependencies = (
                              B1D9136AA0083366353BFA2F /* P256K */,
                              A6E3E5712E7703760032EA8A /* BitLogger */,
                              A6E3EA802E7706A80032EA8A /* Tor */,
                              A6BCF9492F809550001CF9B9 /* BitFoundation */,
                      );

Replace with:

                      name = SafeGuardian_macOS;
                      packageProductDependencies = (
                              B1D9136AA0083366353BFA2F /* P256K */,
                              A6E3E5712E7703760032EA8A /* BitLogger */,
                              A6E3EA802E7706A80032EA8A /* Tor */,
                              A6BCF9492F809550001CF9B9 /* BitFoundation */,
                              CC1111111111111111111A05 /* MLXLLM */,
                              CC1111111111111111111A06 /* MLXLMCommon */,
                              CC1111111111111111111A07 /* MLXHuggingFace */,
                      );      
                      
Replacement 4 — register the package reference and all six products. Find:

/* End XCRemoteSwiftPackageReference section */

Replace with:

              CC1111111111111111111A01 /* XCRemoteSwiftPackageReference "mlx-s" */ = {             
                      isa = XCRemoteSwiftPackageReference;
                      repositoryURL = "https://github.com/ml-explore/mlx-swift-lm";
                      requirement = { 
                              kind = upToNextMajorVersion;
                              minimumVersion = 3.31.3;
                      };      
              };      
/* End XCRemoteSwiftPackageReference section */

And find:

/* End XCSwiftPackageProductDependency section */

Replace with:

              CC1111111111111111111A02 /* MLXLLM */ = {
                      isa = XCSwiftPackageProductDependency;
                      package = CC1111111111111111111A01 /* XCRemoteSwiftPackageReference "mlx-swift-lm" */;
                      productName = MLXLLM;
              };
              CC1111111111111111111A03 /* MLXLMCommon */ = {
                      isa = XCSwiftPackageProductDependency;
                      package = CC1111111111111111111A01 /* XCRemoteSwiftPackageReference "mlx-swift-lm" */;  
                      productName = MLXLMCommon;
              };
              CC1111111111111111111A04 /* MLXHuggingFace */ = {
                      isa = XCSwiftPackageProductDependency;
                      package = CC1111111111111111111A01 /* XCRemoteSwiftPackageReference "mlx-swift-lm" */;
                      productName = MLXHuggingFace;
              };
              CC1111111111111111111A05 /* MLXLLM */ = {
                      isa = XCSwiftPackageProductDependency;
                      package = CC1111111111111111111A01 /* XCRemoteSwiftPackageReference "mlx-swift-lm" */;
                      productName = MLXLLM;
              };
              CC1111111111111111111A06 /* MLXLMCommon */ = {
                      isa = XCSwiftPackageProductDependency;
                      package = CC1111111111111111111A01 /* XCRemoteSwiftPackageReference "mlx-swift-lm" */;    
                      productName = MLXLMCommon;
              };
              CC1111111111111111111A07 /* MLXHuggingFace */ = {
                      isa = XCSwiftPackageProductDependency;
                      package = CC1111111111111111111A01 /* XCRemoteSwiftPackageReference "mlx-swift-lm" */;    
                      productName = MLXHuggingFace;
              };
/* End XCSwiftPackageProductDependency section */
              
---
Step 2 — Create SafeGuardian/Features/nova/MLXInferenceService.swift

Write this file exactly:

import Foundation   
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon

struct NovaMessage {
    enum Role { case user, assistant, system }
    let role: Role
    let content: String
}

@Observable @MainActor
final class MLXInferenceService {
    static let shared = MLXInferenceService()
    private init() {}

    private(set) var isLoading = false
    private(set) var downloadProgress: Double = 0

    private let modelConfig = LLMRegistry.qwen3_0_6b_4bit
    private var container: ModelContainer?
    private var activeTask: Task<Void, Never>?

    func generate(
        messages: [NovaMessage],
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {   
        activeTask?.cancel()
        activeTask = Task {
            do {
                if container == nil {
                    isLoading = true
                    downloadProgress = 0
                    Memory.cacheLimit = 20 * 1024 * 1024
                    let downloader = #hubDownloader()
                    let loader = #huggingFaceTokenizerLoader()
                    container = try await LLMModelFactory.shared.loadContainer(
                        from: downloader,
                        using: loader,
                        configuration: modelConfig
                    ) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.downloadProgress = progress.fractionCompleted
                        }
                    }
                    isLoading = false
                }
                guard let container, !Task.isCancelled else { return }
                let chat = messages.map { m -> Chat.Message in
                    let role: Chat.Message.Role = switch m.role {
                    case .user: .user
                    case .assistant: .assistant
                    case .system: .system
                    }
                    return Chat.Message(role: role, content: m.content)
                }
                let userInput = UserInput(chat: chat)
                try await container.perform { (ctx: ModelContext) in
                    let lmInput = try await ctx.processor.prepare(input: userInput)
                    let stream = try MLXLMCommon.generate(
                        input: lmInput,
                        parameters: GenerateParameters(temperature: 0.7),
                        context: ctx
                    )
                    for await generation in stream {
                        if let token = generation.output.first {
                            onToken(token)
                        }
                        if Task.isCancelled { break }
                    }   
                }       
            } catch {
                // errors surface as incomplete responses; ChatViewModel handles display
            }   
            await MainActor.run { onComplete() }
        }   
    }       
        
    func cancel() {
        activeTask?.cancel()
    }
}

---
Step 3 — Create SafeGuardian/ViewModels/Extensions/ChatViewModel+Nova.swift

Write this file exactly:

import Foundation   

extension ChatViewModel {
    static let novaPeerID: String = "nova-local"

    @MainActor
    func routeToNova(_ prompt: String) {
        let service = MLXInferenceService.shared

        if service.isLoading {
            addLocalMessage("nova is loading the model, please wait…")
            return
        } 

        // Build context from previous Nova DM messages (capped at 20 turns)
        var history: [NovaMessage] = [
            NovaMessage(
                role: .system,
                content: "You are Nova, a concise on-device AI assistant embedded in SafeGuardian, a disaster-response mesh communication app. Keep responses brief."   
            )
        ]
        let prior = (privateChats[Self.novaPeerID] ?? []).suffix(20)
        for msg in prior {
            let role: NovaMessage.Role = msg.sender == Self.novaPeerID ? .assistant : .user
            history.append(NovaMessage(role: role, content: msg.content))
        }
        history.append(NovaMessage(role: .user, content: prompt))

        // Record the user turn in the Nova thread
        let userMsg = SafeGuardianMessage(
            sender: "local", content: prompt, timestamp: Date(), isRelay: false)
        if privateChats[Self.novaPeerID] == nil { privateChats[Self.novaPeerID] = [] }
        privateChats[Self.novaPeerID]?.append(userMsg)
        let response = SafeGuardianMessage(
            sender: "local", content: "", timestamp: Date(), isRelay: false)
        privateChats[Self.novaPeerID]?.append(response)
            
        // Show response in the current visible timeline (ephemeral)
        messages.append(response)
        objectWillChange.send()
        
        service.generate(messages: history) { [weak response, weak self] token in
            guard let response, let self else { return }
            response.content += token
            self.objectWillChange.send() 
        } onComplete: { [weak self] in
            self?.objectWillChange.send()
        }
    }
}

---
Step 4 — Edit SafeGuardian/ViewModels/ChatViewModel.swift

Read the file. Find this exact block at around line 1001:

        // Resolve pending inline confirmations before normal routing
        if pendingGPSShareConfirmation {
            handleGPSShareConfirmation(trimmed)
            return
        }   
            
        // Check for commands
        if content.hasPrefix("/") {
        
Replace with:

        // Resolve pending inline confirmations before normal routing
        if pendingGPSShareConfirmation {
            handleGPSShareConfirmation(trimmed)
            return
        }   
            
        // Route @nova mentions to on-device inference; never sent to the mesh
        if trimmed.lowercased().hasPrefix("@nova") {
            let prompt = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if prompt.isEmpty {
                addLocalMessage("usage: @nova <message>")
            } else {
                routeToNova(prompt)
            } 
            return
        }

        // Check for commands
        if content.hasPrefix("/") {

---
Step 5 — Verify

Run both builds and confirm zero errors:

xcodebuild -project SafeGuardian.xcodeproj -scheme SafeGuardian_iOS -destination "generic/platform=iOS" -configuration Debug CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=V9KH637N7P -allowProvisioningUpdates build 2>&1 | grep "error:"

xcodebuild -project SafeGuardian.xcodeproj -scheme "SafeGuardian_macOS" -destination "platform=macOS" -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep "error:"

Both must produce no output. Report the result — do not report success based on anything other than these two commands.
