import SafeGuardianMesh
import Foundation

/// Location sharing over the Reticulum mesh: /shareloc offers this device's
/// position to a peer (consent-gated on their side), /unshareloc revokes,
/// /shares prints the current grant table and latest received positions.
@MainActor
struct LocationShareCommand: Command {
    enum Mode { case request, revoke, status }

    let names: [String]
    let usage: String
    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .request: names = ["/shareloc"];   usage = "/shareloc <nickname or hash>"
        case .revoke:  names = ["/unshareloc"]; usage = "/unshareloc <nickname or hash>"
        case .status:  names = ["/shares"];     usage = "/shares"
        }
    }

    func execute(args: String, context: CommandContext) -> CommandResult {
        guard let service = (context.transport as? MultiTransportManager)?.reticulumTransport?.locationShare else {
            return .error(message: "reticulum transport is not active")
        }
        switch mode {
        case .status: return status(service)
        case .request, .revoke: break
        }

        guard let hex = resolveDestHash(args, context: context) else {
            return .error(message: "usage: \(usage) — peer must be a reticulum mesh peer")
        }
        let name = service.nicknameFor?(hex) ?? String(hex.prefix(8))

        switch mode {
        case .request:
            switch service.permissionState {
            case .denied:
                SystemSettings.location.open()
                return .error(message: "location permission denied — opening Settings")
            case .restricted:
                return .error(message: "location access is blocked by a device policy")
            case .notDetermined, .authorized:
                break
            }
            service.requestShare(to: hex)
            return .success(message: "location share offered to \(name) — awaiting their consent")
        case .revoke:
            service.revokeShare(to: hex)
            service.stopReceiving(from: hex)
            return .success(message: "location sharing with \(name) ended")
        case .status:
            return .handled
        }
    }

    private func resolveDestHash(_ args: String, context: CommandContext) -> String? {
        let raw = args.trimmed
        guard !raw.isEmpty else { return nil }
        let name = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        if let peerID = context.provider?.getPeerIDForNickname(name),
           Data(hexString: peerID.id)?.count == 16 {
            return peerID.id
        }
        // Fall back to a raw 16-byte destination hash.
        if let data = Data(hexString: name), data.count == 16 {
            return name.lowercased()
        }
        return nil
    }

    private func status(_ service: LocationShareService) -> CommandResult {
        let store = service.store
        var lines: [String] = []
        for hex in store.sharingWith.sorted() {
            lines.append("sharing with \(service.nicknameFor?(hex) ?? String(hex.prefix(8)))")
        }
        for hex in store.requested.sorted() {
            lines.append("offer pending: \(service.nicknameFor?(hex) ?? String(hex.prefix(8)))")
        }
        for hex in store.receivingFrom.sorted() {
            let name = service.nicknameFor?(hex) ?? String(hex.prefix(8))
            if let pos = store.positions[hex] {
                let age = Int(Date().timeIntervalSince(pos.received))
                lines.append(String(
                    format: "receiving from %@: %.5f, %.5f (±%.0fm, %ds ago)",
                    name, pos.payload.lat, pos.payload.lon, pos.payload.acc, age
                ))
            } else {
                lines.append("receiving from \(name): no position yet")
            }
        }
        return .success(message: lines.isEmpty ? "no active location shares" : lines.joined(separator: "\n"))
    }
}
