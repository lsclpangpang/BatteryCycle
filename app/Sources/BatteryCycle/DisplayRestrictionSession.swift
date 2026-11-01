import Foundation

struct DisplayRestrictionSettings: Codable, Equatable {
    var hdmi = false
    var usbC = false

    subscript(_ port: DisplayOutputPort) -> Bool {
        get { port == .hdmi ? hdmi : usbC }
        set {
            if port == .hdmi { hdmi = newValue } else { usbC = newValue }
        }
    }

    var isActive: Bool { hdmi || usbC }
}

struct DisplayRestrictionRecord: Codable, Equatable {
    let id: UInt32
    let uuid: String
    let name: String
    let port: DisplayOutputPort
    let model: DisplayOutputModel?
    let recoveryScope: String?

    init(_ display: DisplayOutputSnapshot, port: DisplayOutputPort) {
        id = display.id
        uuid = display.uuid
        name = display.name
        self.port = port
        model = display.model
        recoveryScope = display.recoveryScope
    }

    var snapshot: DisplayOutputSnapshot {
        DisplayOutputSnapshot(id: id, uuid: uuid, name: name, isBuiltin: false, isEnabled: false,
                              port: port, model: model, recoveryScope: recoveryScope, isConfirmedEnabled: false)
    }
}

struct DisplayRestrictionState: Codable, Equatable {
    var settings = DisplayRestrictionSettings()
    var disabled: [DisplayRestrictionRecord] = []
}

protocol DisplayRestrictionStoring {
    func load() throws -> DisplayRestrictionState?
    func save(_ state: DisplayRestrictionState) throws
}

/// Owns only displays this session changed. The complete recovery journal is durable
/// before the first hardware mutation. A physical display's UUID is resolved anew on
/// every snapshot; a numeric display ID is never used as its persistent identity.
final class DisplayRestrictionSession {
    private let backend: any DisplayOutputBackend
    private let store: any DisplayRestrictionStoring
    private let uptime: () -> TimeInterval
    private let isUsable: (DisplayOutputSnapshot) -> Bool
    private var state = DisplayRestrictionState()
    private var loaded = false
    private var firstAttemptAt: [String: TimeInterval] = [:]
    private var lastAttemptAt: [String: TimeInterval] = [:]
    private var lastRestoreAt: [String: TimeInterval] = [:]

    var settings: DisplayRestrictionSettings { state.settings }
    var hasRecovery: Bool { !state.disabled.isEmpty }
    var needsReload: Bool { !loaded }
    var ownedModels: [DisplayOutputModel: Int] {
        guard loaded, !state.disabled.isEmpty, let topology = try? backend.snapshot() else { return [:] }
        var models: [DisplayOutputModel: Int] = [:]
        for record in state.disabled {
            let display = topology.first(where: { $0.uuid == record.uuid })
            if let display, confirmedEnabled(display) { continue }
            if display == nil, (try? backend.recoveryPresence(for: record.snapshot)) != .connected { continue }
            guard let model = display?.model ?? record.model, model.vendor != 0, model.product != 0 else { continue }
            models[model, default: 0] += 1
        }
        return models
    }

    init(backend: any DisplayOutputBackend, store: any DisplayRestrictionStoring,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         isUsable: @escaping (DisplayOutputSnapshot) -> Bool = { $0.isEnabled }) {
        self.backend = backend
        self.store = store
        self.uptime = uptime
        self.isUsable = isUsable
    }

    func start() throws {
        try load()
        try reconcile()
    }

    func setRestricted(_ port: DisplayOutputPort, _ restricted: Bool) throws {
        try load()
        var next = state
        next.settings[port] = restricted
        try commit(next)
        try reconcile()
    }

    /// May run while the advanced panel is hidden. Authentication guards changing
    /// intent; enforcing previously authorized, persisted intent needs no new prompt.
    func reconcile() throws {
        try load()
        var topology = try backend.snapshot()
        var errors: [String] = []

        for record in state.disabled {
            guard let current = topology.first(where: { $0.uuid == record.uuid }) else {
                guard !state.settings[record.port] else { continue }
                do {
                    if try backend.recoveryPresence(for: record.snapshot) == .disconnected { continue }
                    try restore(record, using: record.snapshot)
                } catch { errors.append(error.localizedDescription) }
                continue
            }
            if current.port == nil, state.settings.isActive {
                errors.append("无法确认「\(record.name)」当前连接的接口，暂未恢复输出")
                continue
            }
            let currentPort = current.port ?? record.port
            if state.settings[currentPort] {
                if !current.isEnabled {
                    firstAttemptAt[record.uuid] = nil
                    lastAttemptAt[record.uuid] = nil
                }
                continue
            }
            do { try restore(record, using: current) }
            catch { errors.append(error.localizedDescription) }
        }
        topology = try backend.snapshot()
        let candidates = topology.filter { display in
            !display.isBuiltin && display.isEnabled && display.port.map { state.settings[$0] } == true
        }
        let survivors = topology.filter { display in
            display.isEnabled && isUsable(display) && !candidates.contains { $0.uuid == display.uuid }
        }
        if !candidates.isEmpty && survivors.isEmpty {
            errors.append("需保留一块可用屏幕，请先打开内屏或连接未受限制的显示器")
        } else {
            for display in candidates {
                do { try stop(display) }
                catch { errors.append(error.localizedDescription) }
            }
        }
        if state.settings.isActive && topology.contains(where: { !$0.isBuiltin && $0.isEnabled && $0.port == nil }) {
            errors.append("部分显示器的接口无法确认，未改动这些显示器")
        }
        if !errors.isEmpty { throw RestrictionError(errors.joined(separator: "；")) }
    }

    /// Normal termination restores only owned changes and preserves both preferences
    /// for the next launch. Failed restorations keep their journal entries.
    func restoreAll() throws {
        try load()
        let topology = try backend.snapshot()
        var errors: [String] = []
        for record in state.disabled {
            do {
                let current = topology.first(where: { $0.uuid == record.uuid })
                if current == nil, try backend.recoveryPresence(for: record.snapshot) == .disconnected { continue }
                try restore(record, using: current ?? record.snapshot)
            }
            catch { errors.append(error.localizedDescription) }
        }
        if !errors.isEmpty { throw RestrictionError(errors.joined(separator: "；")) }
    }

    /// Legacy per-display controls cannot enable a display governed by a restriction.
    /// An uncertain interface also requires resolving the advanced rule first.
    func permitsEnabling(displayID: UInt32, identity: DisplayRestrictionRecord? = nil) -> Bool {
        guard loaded else { return false }
        if !state.settings.isActive && identity == nil { return true }
        if let identity { backend.remember([identity.snapshot]) }
        guard let topology = try? backend.snapshot(),
              let display = topology.first(where: { $0.id == displayID }),
              identity == nil || display.uuid == identity?.uuid else { return false }
        return display.isBuiltin || display.port.map { !state.settings[$0] } == true
    }

    func captureIdentity(displayID: UInt32) -> DisplayRestrictionRecord? {
        guard let display = try? backend.snapshot().first(where: { $0.id == displayID }),
              !display.isBuiltin, let port = display.port else { return nil }
        return DisplayRestrictionRecord(display, port: port)
    }

    func permitsMinimumBrightness() -> Bool {
        guard loaded else { return false }
        guard state.settings.isActive else { return true }
        guard let topology = try? backend.snapshot() else { return false }
        return topology.contains { !$0.isBuiltin && $0.isEnabled && $0.port.map { !state.settings[$0] } == true }
    }

    private func load() throws {
        guard !loaded else { return }
        let saved = try store.load() ?? DisplayRestrictionState()
        guard Set(saved.disabled.map(\.uuid)).count == saved.disabled.count,
              saved.disabled.allSatisfy({ !$0.uuid.isEmpty && $0.id != 0 }) else {
            throw RestrictionError("屏幕恢复记录无效，未更改显示器设置")
        }
        let removed = Set(state.disabled.map(\.uuid)).subtracting(saved.disabled.map(\.uuid))
        state = saved
        loaded = true
        for uuid in removed { backend.forgetRecovery(uuid: uuid) }
        backend.remember(saved.disabled.map(\.snapshot))
    }

    private func commit(_ next: DisplayRestrictionState) throws {
        do {
            try store.save(next)
            state = next
        } catch {
            // Atomic replacement may have succeeded before a later I/O error.
            // Re-read before any future mutation rather than overwriting an uncertain journal.
            loaded = false
            throw error
        }
    }

    private func stop(_ original: DisplayOutputSnapshot) throws {
        let latest = try backend.snapshot()
        guard let display = latest.first(where: { $0.uuid == original.uuid }),
              !display.isBuiltin, display.isEnabled else { return }
        guard let port = display.port else {
            throw RestrictionError("无法确认「\(display.name)」当前的接口，未停止输出")
        }
        guard state.settings[port] else { return }
        let now = uptime()
        if let last = lastAttemptAt[display.uuid], now - last < 1 { return }
        guard latest.contains(where: { $0.isEnabled && isUsable($0) &&
            ($0.isBuiltin || $0.port.map { !state.settings[$0] } == true) }) else {
            throw RestrictionError("需保留一块可用屏幕，已暂停停止外接屏输出")
        }
        let captured = DisplayRestrictionRecord(display, port: port)
        if let index = state.disabled.firstIndex(where: { $0.uuid == display.uuid }) {
            if state.disabled[index] != captured {
                var next = state
                next.disabled[index] = captured
                try commit(next)
            }
        } else {
            var next = state
            next.disabled.append(captured)
            try commit(next)
        }
        if firstAttemptAt[display.uuid] == nil { firstAttemptAt[display.uuid] = now }
        lastAttemptAt[display.uuid] = now
        do { try backend.setEnabled(false, for: display) }
        catch { throw RestrictionError("无法停止「\(display.name)」的画面输出：\(error.localizedDescription)") }
        let after = try backend.snapshot()
        if after.first(where: { $0.uuid == display.uuid })?.isEnabled == true {
            if now - (firstAttemptAt[display.uuid] ?? now) >= 3 {
                throw RestrictionError("「\(display.name)」仍在显示画面，请重试")
            }
        } else {
            firstAttemptAt[display.uuid] = nil
            lastAttemptAt[display.uuid] = nil
        }
    }

    private func restore(_ record: DisplayRestrictionRecord, using display: DisplayOutputSnapshot) throws {
        if !confirmedEnabled(display) {
            let now = uptime()
            if let last = lastRestoreAt[record.uuid], now - last < 3 {
                throw RestrictionError("正在等待「\(record.name)」恢复画面，请稍候")
            }
            do {
                try backend.setEnabled(true, for: display)
                lastRestoreAt[record.uuid] = now
            }
            catch { throw RestrictionError("无法恢复「\(record.name)」：\(error.localizedDescription)") }
        }
        let after = try backend.snapshot()
        guard after.contains(where: { $0.uuid == record.uuid && confirmedEnabled($0) }) else {
            throw RestrictionError("尚未确认「\(record.name)」已恢复，请稍后重试")
        }
        var next = state
        next.disabled.removeAll { $0.uuid == record.uuid }
        try commit(next)
        backend.forgetRecovery(uuid: record.uuid)
        firstAttemptAt[record.uuid] = nil
        lastAttemptAt[record.uuid] = nil
        lastRestoreAt[record.uuid] = nil
    }

    private func confirmedEnabled(_ display: DisplayOutputSnapshot) -> Bool {
        display.isConfirmedEnabled ?? display.isEnabled
    }

    private struct RestrictionError: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }
}
