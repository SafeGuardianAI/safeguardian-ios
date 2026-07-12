import Foundation
import SafeGuardianMesh

// The tenant this device is provisioned into. A tenant id arrives at deployment
// time (operator entry in settings today; provisioning payload later) and every
// SGEnvelope this node emits carries its 4-byte hash so the platform can
// partition traffic per deployment. Unprovisioned devices emit the zero hash.
enum TenantIdentity {
    static let tenantIDKey = "sg.tenant.id"

    static var tenantID: String {
        UserDefaults.standard.string(forKey: tenantIDKey) ?? ""
    }

    static func setTenantID(_ id: String) {
        UserDefaults.standard.set(id.trimmingCharacters(in: .whitespacesAndNewlines),
                                  forKey: tenantIDKey)
    }

    static var tenantHash: Data {
        let id = tenantID
        guard !id.isEmpty else { return SGEnvelope.defaultTenantHash }
        return SGEnvelope.tenantHash(forTenantID: id)
    }
}
