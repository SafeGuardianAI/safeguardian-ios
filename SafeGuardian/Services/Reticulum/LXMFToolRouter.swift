import BitFoundation
import Foundation

// Implements the LXMF tool_call / tool_response wire protocol used by Python agents.
// Wire format (matches agents/shared/tool_router.py):
//   outbound title:  "tool_call:{request_id}:{tool_name}"
//   outbound body:   {"sender": "<dest_hash_hex>", "args": {...}}
//   inbound title:   "tool_response:{request_id}"
//   inbound body:    {"result": "<json_string>"}
//
// sendDirected is set by ReticulumTransport and wraps the LXMF payload in a
// directed ReticulumDataPacket before handing it to the BLE layer.
final class LXMFToolRouter: @unchecked Sendable {
    private let identity: ReticulumIdentity
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<String, Error>] = [:]

    var sendDirected: ((_ destHash: Data, _ lxmfPayload: Data) -> Void)?

    init(identity: ReticulumIdentity) {
        self.identity = identity
    }

    func callTool(destHash: Data, toolName: String, args: [String: Any]) async throws -> String {
        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let title = "tool_call:\(requestID):\(toolName)"
        let senderHex = identity.destinationHash.hexEncodedString()
        let bodyObj: [String: Any] = ["sender": senderHex, "args": args]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyObj)
        let lxmf = try LXMFMessage.build(from: identity, to: destHash, content: bodyData, title: title)
        let lxmfPayload = lxmf.encode()

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pending[requestID] = cont
            lock.unlock()

            sendDirected?(destHash, lxmfPayload)

            Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self.lock.lock()
                let still = self.pending.removeValue(forKey: requestID) != nil
                self.lock.unlock()
                if still {
                    cont.resume(throwing: LXMFToolError.timeout(tool: toolName))
                }
            }
        }
    }

    func handleResponse(title: String, content: Data) {
        // title = "tool_response:{request_id}"
        let parts = title.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let requestID = String(parts[1])

        lock.lock()
        let cont = pending.removeValue(forKey: requestID)
        lock.unlock()

        guard let cont else { return }

        guard let json = try? JSONSerialization.jsonObject(with: content) as? [String: Any],
              let result = json["result"] as? String else {
            cont.resume(throwing: LXMFToolError.malformedResponse)
            return
        }
        cont.resume(returning: result)
    }
}

enum LXMFToolError: Error {
    case timeout(tool: String)
    case malformedResponse
    case noAgent(type: String)
}
