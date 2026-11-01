import Foundation

enum DisplayOutputPort: String, Codable, CaseIterable, Sendable {
    case hdmi, usbC
}

struct DisplayOutputModel: Codable, Hashable, Sendable {
    let vendor: UInt32
    let product: UInt32
}

/// The legacy controller's hardware arithmetic must not mistake a display owned
/// by an output restriction for one of its own manually disabled displays.
enum DisplayOutputModelCounts {
    static func excludingRestricted(_ owned: [DisplayOutputModel: Int],
                                    from attached: [DisplayOutputModel: Int]) -> [DisplayOutputModel: Int] {
        var available = attached
        for (model, count) in owned where count > 0 && model.vendor != 0 && model.product != 0 {
            guard let present = available[model] else { continue }
            available[model] = max(0, present - count)
        }
        return available
    }
}

struct DisplayOutputSnapshot: Equatable, Sendable {
    let id: UInt32
    let uuid: String
    let name: String
    let isBuiltin: Bool
    let isEnabled: Bool
    let port: DisplayOutputPort?
    let model: DisplayOutputModel?
    let recoveryScope: String?
    let isConfirmedEnabled: Bool?

    init(id: UInt32, uuid: String, name: String, isBuiltin: Bool,
         isEnabled: Bool, port: DisplayOutputPort?, model: DisplayOutputModel? = nil,
         recoveryScope: String? = nil, isConfirmedEnabled: Bool? = nil) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.isBuiltin = isBuiltin
        self.isEnabled = isEnabled
        self.port = port
        self.model = model
        self.recoveryScope = recoveryScope
        self.isConfirmedEnabled = isConfirmedEnabled
    }
}

enum DisplayRecoveryPresence: Equatable, Sendable {
    case connected, disconnected, unknown
}

protocol DisplayOutputBackend {
    func snapshot() throws -> [DisplayOutputSnapshot]
    func setEnabled(_ enabled: Bool, for display: DisplayOutputSnapshot) throws
    /// Seed recovery identities without making any hardware changes.
    func remember(_ displays: [DisplayOutputSnapshot])
    func recoveryPresence(for display: DisplayOutputSnapshot) throws -> DisplayRecoveryPresence
    func forgetRecovery(uuid: String)
}

extension DisplayOutputBackend {
    func remember(_ displays: [DisplayOutputSnapshot]) {}
    func recoveryPresence(for display: DisplayOutputSnapshot) throws -> DisplayRecoveryPresence { .unknown }
    func forgetRecovery(uuid: String) {}
}
