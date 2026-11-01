import CoreGraphics
import ColorSync
import Foundation
import IOKit
import Security
import Darwin

/// User-session display configuration only. Never disables USB controllers, power
/// delivery or data paths. All callers serialize access on the main thread.
final class NativeDisplayOutputBackend: DisplayOutputBackend {
    private var remembered: [String: DisplayOutputSnapshot] = [:]
    private var trustedDisabledIDs: [String: UInt32] = [:]
    /// Connector numbers seen in this process. Registry-ID fallbacks are excluded: they
    /// change on re-enumeration and would otherwise mark the inventory incomplete forever.
    private var knownPhysicalPorts: Set<String> = []
    private var reasons: [UInt32: String] = [:]

    func remember(_ displays: [DisplayOutputSnapshot]) {
        for display in displays where !display.isBuiltin && UUID(uuidString: display.uuid) != nil {
            remembered[display.uuid] = display
        }
    }

    func forgetRecovery(uuid: String) {
        remembered.removeValue(forKey: uuid)
        trustedDisabledIDs.removeValue(forKey: uuid)
    }

    func recoveryPresence(for display: DisplayOutputSnapshot) throws -> DisplayRecoveryPresence {
        guard let port = display.port else { return .unknown }
        let first = physicalInventory()
        let second = physicalInventory()
        return Self.presence(port: port, inventory: second, stable: first == second && second.complete)
    }

    func snapshot() throws -> [DisplayOutputSnapshot] {
        let before = physicalInventory()
        let linksBefore = Self.displayPortLinks()
        let framebuffers = Self.framebuffers()
        let ids = try Self.onlineDisplays()
        let information = Dictionary(uniqueKeysWithValues: ids.map { ($0, Self.info($0)) })
        let identities = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, DisplayTransportIdentity(
                registryPath: information[id]?["IODisplayLocation"] as? String,
                edid: information[id]?["IODisplayEDID"] as? Data,
                vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id)))
        })
        let linksAfter = Self.displayPortLinks()
        let after = physicalInventory()
        let inventoryStable = before == after && after.complete
        let linksStable = linksBefore == linksAfter && linksAfter.complete
        let scope = Self.currentRecoveryScope()
        reasons = [:]
        var result: [DisplayOutputSnapshot] = []
        for id in ids {
            guard let uuid = Self.uuid(id) else { throw NativeDisplayOutputError.unavailableIdentity }
            let builtin = CGDisplayIsBuiltin(id) != 0
            let info = information[id] ?? [:]
            guard let identity = identities[id] else { throw NativeDisplayOutputError.unavailableIdentity }
            let matched = DisplayTransportMatcher.match(identity, candidates: framebuffers.map(\.identity))
            let framebuffer = matched.map { framebuffers[$0] }
            let virtual = ["IsVirtual", "Virtual", "DisplayIsVirtual", "DisplayIsVirtualDevice",
                           "kCGDisplayIsVirtualDevice", "IsAirPlay", "IsSidecar"]
                .contains { Self.boolean(info[$0]) == true }
            // EDID/serial uniqueness can locate a candidate, but does not prove
            // the CG display itself is physical (a virtual display can copy an
            // EDID). Require the CG-provided framebuffer path to corroborate it.
            let physicalPathMatches = identity.registryPath != nil
                && identity.registryPath == framebuffer?.identity.registryPath
            // This is positive identity-matched display transport evidence; a
            // missing/inactive DP node never implies a USB-C port is display-free.
            let linkedPort = linksStable ? DisplayPortLinkMatcher.port(for: identity,
                among: Array(identities.values), links: linksAfter.entries.map(\.evidence)) : nil
            var sourcePorts = framebuffer?.ancestorPorts ?? []
            if let linkedPort { sourcePorts.append(linkedPort) }
            let classification = DisplayTransportClassifier.classify(.init(
                isNativeDCP: physicalPathMatches && !builtin, isVirtual: virtual,
                ancestorPorts: sourcePorts,
                inventory: after.entries.map { .init(kind: $0.kind, connection: $0.connection) },
                inventoryComplete: inventoryStable,
                transportUpstream: framebuffer?.upstream, transportDownstream: framebuffer?.downstream))
            let active = CGDisplayIsActive(id) != 0
            let mirrorPrimary = CGDisplayMirrorsDisplay(id)
            let mirrored = CGDisplayIsInMirrorSet(id) != 0 || mirrorPrimary != kCGNullDirectDisplay
            let asleep = CGDisplayIsAsleep(id) != 0
            let enabled = DisplayOutputPresence.isEnabled(active: active, mirrored: mirrored, asleep: asleep)
            let confirmedEnabled = DisplayRecoveryVerification.isConfirmed(active: active, mirrored: mirrored,
                mirrorPrimaryActive: mirrorPrimary != kCGNullDirectDisplay && mirrorPrimary != id
                    && CGDisplayIsActive(mirrorPrimary) != 0 && CGDisplayIsOnline(id) != 0,
                asleep: asleep)
            let names = info["DisplayProductName"] as? [String: String]
            let name = names?["zh_CN"] ?? names?["en_US"] ?? names?.values.first
                ?? (builtin ? "内置显示器" : "外接显示器")
            let model = identity.vendor != 0 && identity.product != 0
                ? DisplayOutputModel(vendor: identity.vendor, product: identity.product) : nil
            result.append(.init(id: id, uuid: uuid, name: name, isBuiltin: builtin,
                                isEnabled: enabled, port: builtin ? nil : classification.port,
                                model: model, recoveryScope: scope, isConfirmedEnabled: confirmedEnabled))
            reasons[id] = builtin ? "内置屏幕" : classification.reason
        }
        let visibleUUIDs = Set(result.map(\.uuid))
        for record in remembered.values where !visibleUUIDs.contains(record.uuid) {
            if let port = record.port,
               Self.presence(port: port, inventory: after, stable: inventoryStable) == .disconnected { continue }
            // Logical disabling may make both CG UUID APIs return nothing. Keep
            // an owned same-session recovery candidate rather than losing it.
            guard let id = try recoveryID(for: record, enabling: true, onlineIDs: ids) else { continue }
            result.append(.init(id: id, uuid: record.uuid, name: record.name, isBuiltin: false,
                                isEnabled: false, port: record.port, model: record.model,
                                recoveryScope: record.recoveryScope, isConfirmedEnabled: false))
            reasons[id] = "本 App 拥有的同登录会话恢复候选，尚未确认输出"
        }
        return result.sorted { $0.id < $1.id }
    }

    func setEnabled(_ enabled: Bool, for display: DisplayOutputSnapshot) throws {
        guard !display.isBuiltin, let id = try recoveryID(for: display, enabling: enabled),
              CGDisplayIsBuiltin(id) == 0 else { throw NativeDisplayOutputError.changedIdentity }
        var current = display
        if !enabled {
            let all = try snapshot()
            guard let live = all.first(where: { $0.uuid == display.uuid && $0.id == id }),
                  let port = live.port, port == display.port else {
                throw NativeDisplayOutputError.unknownTransport
            }
            guard all.contains(where: { $0.id != id && $0.isEnabled }) else {
                throw NativeDisplayOutputError.lastDisplay
            }
            current = live
        }
        guard let configureEnabled = Self.configureEnabled else { throw NativeDisplayOutputError.unsupported }
        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else {
            throw NativeDisplayOutputError.operation("开始显示配置", Int32(begin.rawValue))
        }
        let change = configureEnabled(configuration, id, enabled)
        guard change == 0 else {
            _ = CGCancelDisplayConfiguration(configuration)
            throw NativeDisplayOutputError.operation("设置显示输出", change)
        }
        let completed = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard completed == .success else {
            throw NativeDisplayOutputError.operation("提交显示配置", Int32(completed.rawValue))
        }
        if !enabled {
            trustedDisabledIDs[display.uuid] = id
            remembered[display.uuid] = .init(id: id, uuid: display.uuid, name: current.name,
                isBuiltin: false, isEnabled: false, port: current.port, model: current.model,
                recoveryScope: current.recoveryScope, isConfirmedEnabled: false)
        }
        // Re-enable submission must retain ownership until the policy engine
        // observes the real online UUID + confirmed output and calls forgetRecovery.
        // A successful call only submits configuration. The policy engine must
        // inspect subsequent snapshots instead of treating this as verification.
    }

    /// Read-only diagnostic: no serials, stable UUIDs, EDID or registry paths.
    func diagnosticSummary() throws -> String {
        let displays = try snapshot()
        return displays.map {
            "display=\($0.id) builtIn=\($0.isBuiltin) enabled=\($0.isEnabled) source=\($0.port?.rawValue ?? "unknown") evidence=\(reasons[$0.id] ?? "unknown")"
        }.joined(separator: "\n")
    }

    private struct PhysicalEntry: Equatable {
        let id: String
        let kind: DisplayOutputPort
        let connection: DisplayPhysicalConnection
    }
    private struct Inventory: Equatable {
        let entries: [PhysicalEntry]
        let complete: Bool
    }

    private static func presence(port: DisplayOutputPort, inventory: Inventory,
                                 stable: Bool) -> DisplayRecoveryPresence {
        let connections = inventory.entries.filter { $0.kind == port }.map { entry -> DisplayRecoveryPresence in
            switch entry.connection {
            case .connected: return .connected
            case .disconnected: return .disconnected
            case .unknown: return .unknown
            }
        }
        return DisplayRecoveryVerification.presence(connections, stable: stable)
    }

    private func physicalInventory() -> Inventory {
        var entries: [PhysicalEntry] = []
        var complete = true
        for className in ["AppleHDMIPortController", "IOAccessoryManager"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
            else { complete = false; continue }
            defer { IOObjectRelease(iterator) }
            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 { break }
                defer { IOObjectRelease(service) }
                guard let properties = Self.properties(service) else { complete = false; continue }
                if Self.boolean(properties["BuiltIn"]) == false { continue }
                guard Self.boolean(properties["BuiltIn"]) == true,
                      let type = properties["PortTypeDescription"] as? String else { complete = false; continue }
                let kind: DisplayOutputPort
                switch type {
                case "HDMI": kind = .hdmi
                case "USB-C": kind = .usbC
                case "MagSafe", "MagSafe 3": continue
                default: complete = false; continue
                }
                var registryID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else {
                    complete = false; continue
                }
                let active = Self.boolean(properties["ConnectionActive"])
                let cc = Self.ccActive(service)
                let connection: DisplayPhysicalConnection
                if let active, let cc, active != cc { connection = .unknown }
                else if let connected = active ?? cc { connection = connected ? .connected : .disconnected }
                else { connection = .unknown }
                // Port controller registry IDs may change after wake. A valid
                // built-in port number identifies the connector across that
                // re-enumeration; never interpret the number as a screen ID.
                let number = properties["PortNumber"] as? NSNumber
                let value = number?.doubleValue
                let identifier: String
                if let number, CFGetTypeID(number) != CFBooleanGetTypeID(),
                   let value, value.isFinite, value.rounded() == value, (1...255).contains(value) {
                    identifier = "\(kind.rawValue):\(Int(value))"
                } else {
                    identifier = "\(kind.rawValue):registry-\(registryID)"
                }
                entries.append(.init(id: identifier, kind: kind, connection: connection))
            }
        }
        let observed = Set(entries.map(\.id).filter { !$0.contains(":registry-") })
        if !knownPhysicalPorts.isSubset(of: observed) { complete = false }
        knownPhysicalPorts.formUnion(observed)
        return Inventory(entries: entries.sorted { $0.id < $1.id }, complete: complete && !entries.isEmpty)
    }

    private struct Framebuffer {
        let identity: DisplayTransportIdentity
        let ancestorPorts: [DisplayOutputPort]
        let upstream: String?
        let downstream: String?
    }

    private struct DisplayLinkRecord: Equatable {
        let id: UInt64
        let evidence: DisplayPortLinkEvidence
    }

    private struct DisplayLinkInventory: Equatable {
        let entries: [DisplayLinkRecord]
        let complete: Bool
    }

    private static func displayPortLinks() -> DisplayLinkInventory {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("IOPortTransportStateDisplayPort"), &iterator) == KERN_SUCCESS else {
            return .init(entries: [], complete: false)
        }
        defer { IOObjectRelease(iterator) }
        var entries: [DisplayLinkRecord] = []
        var complete = true
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
                  let properties = properties(service) else { complete = false; continue }
            entries.append(.init(id: id, evidence: .init(properties: properties)))
        }
        return .init(entries: entries.sorted { $0.id < $1.id }, complete: complete)
    }

    private static func framebuffers() -> [Framebuffer] {
        var result: [Framebuffer] = []
        var seen = Set<UInt64>()
        for className in ["AppleCLCD2", "IOMobileFramebufferShim"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
            else { continue }
            defer { IOObjectRelease(iterator) }
            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 { break }
                defer { IOObjectRelease(service) }
                var registryID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS,
                      seen.insert(registryID).inserted, let properties = properties(service),
                      let attributes = properties["DisplayAttributes"] as? [String: Any],
                      let product = attributes["ProductAttributes"] as? [String: Any],
                      let vendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                      let model = (product["ProductID"] as? NSNumber)?.uint32Value else { continue }
                let transport = properties["Transport"] as? [String: Any]
                result.append(.init(identity: .init(registryPath: registryPath(service),
                    edid: properties["IODisplayEDID"] as? Data, vendor: vendor, product: model,
                    serial: (product["SerialNumber"] as? NSNumber)?.uint32Value ?? 0),
                    ancestorPorts: ancestorPorts(service), upstream: transport?["Upstream"] as? String,
                    downstream: transport?["Downstream"] as? String))
            }
        }
        return result
    }

    private static func ancestorPorts(_ service: io_service_t) -> [DisplayOutputPort] {
        var current = service
        IOObjectRetain(current)
        var ports: [DisplayOutputPort] = []
        for _ in 0..<32 {
            if let properties = properties(current), boolean(properties["BuiltIn"]) == true {
                if properties["PortTypeDescription"] as? String == "HDMI" { ports.append(.hdmi) }
                if properties["PortTypeDescription"] as? String == "USB-C" { ports.append(.usbC) }
            }
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard status == KERN_SUCCESS else { return ports }
            current = parent
        }
        IOObjectRelease(current)
        return ports
    }

    private static func ccActive(_ service: io_service_t) -> Bool? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while true {
            let child = IOIteratorNext(iterator)
            if child == 0 { return nil }
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, "IOPortTransportStateCC") != 0 {
                return properties(child).flatMap { boolean($0["Active"]) }
            }
        }
    }

    private static func properties(_ service: io_service_t) -> [String: Any]? {
        var value: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &value, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return value?.takeRetainedValue() as? [String: Any]
    }

    private static func registryPath(_ service: io_service_t) -> String? {
        var path = [CChar](repeating: 0, count: 4096)
        guard IORegistryEntryGetPath(service, kIOServicePlane, &path) == KERN_SUCCESS else { return nil }
        return String(cString: path)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func onlineDisplays() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        let status = CGGetOnlineDisplayList(0, nil, &count)
        guard status == .success else { throw NativeDisplayOutputError.operation("枚举显示器", Int32(status.rawValue)) }
        if count == 0 { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let read = CGGetOnlineDisplayList(count, &displays, &count)
        guard read == .success else { throw NativeDisplayOutputError.operation("读取显示器", Int32(read.rawValue)) }
        return Array(displays.prefix(Int(count)))
    }

    private static func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
    }

    private func recoveryID(for display: DisplayOutputSnapshot, enabling: Bool,
                            onlineIDs suppliedIDs: [UInt32]? = nil) throws -> UInt32? {
        guard UUID(uuidString: display.uuid) != nil else { return nil }
        let ids = try suppliedIDs ?? Self.onlineDisplays()
        var knownUUIDs: [UInt32: String] = [:]
        for id in ids {
            if let uuid = Self.uuid(id) { knownUUIDs[id] = uuid }
        }
        if let previousUUID = Self.uuid(display.id) { knownUUIDs[display.id] = previousUUID }
        let owned = remembered[display.uuid]
        return DisplayRecoveryResolver.resolve(enabling: enabling, previousID: display.id,
            expectedUUID: display.uuid,
            verifiedUUIDDisplayID: Self.resolve(display.uuid, previousID: display.id),
            knownUUIDs: knownUUIDs, onlineIDs: Set(ids),
            trustedInProcess: trustedDisabledIDs[display.uuid] == display.id,
            rememberedOwned: owned?.id == display.id && owned?.uuid == display.uuid
                && owned?.recoveryScope == display.recoveryScope,
            savedScope: display.recoveryScope, currentScope: Self.currentRecoveryScope())
    }

    /// Security session IDs are login-scoped; the boot UUID prevents reuse after
    /// reboot. This is an informational read and never requests authorization.
    private static func currentRecoveryScope() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1, size < 256 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBufferPointer {
            sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return nil }
        let boot = String(cString: buffer)
        guard UUID(uuidString: boot) != nil else { return nil }
        var session: SecuritySessionId = noSecuritySession
        guard SessionGetInfo(callerSecuritySession, &session, nil) == errSecSuccess,
              session != noSecuritySession, session != callerSecuritySession else { return nil }
        return "\(boot.lowercased()):\(session)"
    }

    private static func resolve(_ uuid: String, previousID: UInt32) -> UInt32? {
        guard UUID(uuidString: uuid) != nil,
              let identifier = CFUUIDCreateFromString(kCFAllocatorDefault, uuid as CFString) else { return nil }
        let currentID = CGDisplayGetDisplayIDFromUUID(identifier)
        if currentID != 0, self.uuid(currentID) == uuid { return currentID }
        if previousID != 0, self.uuid(previousID) == uuid { return previousID }
        return nil
    }

    private typealias CreateInfo = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
    private static let createInfo: CreateInfo? = {
        for path in ["/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
                     "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay"] {
            if let handle = dlopen(path, RTLD_LAZY),
               let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") {
                return unsafeBitCast(symbol, to: CreateInfo.self)
            }
        }
        return nil
    }()

    private static func info(_ id: UInt32) -> [String: Any] {
        createInfo?(id)?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef, UInt32, Bool) -> Int32
    private static let configureEnabled: ConfigureEnabled? = {
        for (path, name) in [
            ("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", "SLSConfigureDisplayEnabled"),
            ("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", "CGSConfigureDisplayEnabled")
        ] {
            if let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, name) {
                return unsafeBitCast(symbol, to: ConfigureEnabled.self)
            }
        }
        return nil
    }()
}

enum NativeDisplayOutputError: LocalizedError {
    case unavailableIdentity, changedIdentity, unknownTransport, lastDisplay, unsupported
    case operation(String, Int32)

    var errorDescription: String? {
        switch self {
        case .unavailableIdentity: return "无法读取显示器标识，未修改显示输出"
        case .changedIdentity: return "显示器已拔出或标识已改变，未修改显示输出"
        case .unknownTransport: return "无法确认显示器的机身连接接口，未修改显示输出"
        case .lastDisplay: return "至少需要保留一块可用屏幕"
        case .unsupported: return "当前系统不支持停止显示输出"
        case let .operation(name, code): return "\(name)失败（\(code)）"
        }
    }
}
