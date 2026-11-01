import Foundation

/// Resolves identity for a write. Historical numeric IDs are permitted only for
/// restoring changes owned by this process or its still-current login session.
/// A resolved ID proves a recovery target, never successful output restoration.
enum DisplayRecoveryResolver {
    static func resolve(enabling: Bool, previousID: UInt32, expectedUUID: String,
                        verifiedUUIDDisplayID: UInt32?, knownUUIDs: [UInt32: String],
                        onlineIDs: Set<UInt32>, trustedInProcess: Bool,
                        rememberedOwned: Bool, savedScope: String?, currentScope: String?) -> UInt32? {
        if let id = verifiedUUIDDisplayID {
            guard id != 0, knownUUIDs[id] == nil || knownUUIDs[id] == expectedUUID else { return nil }
            return id
        }
        guard enabling, previousID != 0, !onlineIDs.contains(previousID),
              knownUUIDs[previousID] == nil || knownUUIDs[previousID] == expectedUUID else { return nil }
        let sameLogin = rememberedOwned && savedScope != nil && savedScope == currentScope
            && !(savedScope?.isEmpty ?? true)
        guard trustedInProcess || sameLogin else { return nil }
        return previousID
    }
}

enum DisplayRecoveryVerification {
    static func isConfirmed(active: Bool, mirrored: Bool, mirrorPrimaryActive: Bool, asleep: Bool) -> Bool {
        // Asleep preserves the policy's enabled state, but is not evidence that
        // a submitted re-enable has brought this display back into real output.
        active || (mirrored && mirrorPrimaryActive && !asleep)
    }

    static func presence(_ connections: [DisplayRecoveryPresence], stable: Bool) -> DisplayRecoveryPresence {
        guard stable, !connections.isEmpty else { return .unknown }
        if connections.contains(.connected) { return .connected }
        if connections.allSatisfy({ $0 == .disconnected }) { return .disconnected }
        return .unknown
    }
}
