import Foundation

enum DisplayPhysicalConnection: Equatable { case connected, disconnected, unknown }

struct DisplayPhysicalPort: Equatable {
    let kind: DisplayOutputPort
    let connection: DisplayPhysicalConnection
}

struct DisplayTransportEvidence {
    let isNativeDCP: Bool
    let isVirtual: Bool
    let ancestorPorts: [DisplayOutputPort]
    let inventory: [DisplayPhysicalPort]
    let inventoryComplete: Bool
    let transportUpstream: String?
    let transportDownstream: String?
}

struct DisplayTransportClassification {
    let port: DisplayOutputPort?
    /// Describes evidence, never EDID, UUID, serial number or full registry paths.
    let reason: String
}

enum DisplayTransportClassifier {
    static func classify(_ evidence: DisplayTransportEvidence) -> DisplayTransportClassification {
        guard evidence.isNativeDCP, !evidence.isVirtual else {
            return .init(port: nil, reason: "未确认原生实体显示链路")
        }
        let ancestors = Set(evidence.ancestorPorts)
        if ancestors.count == 1 {
            return .init(port: ancestors.first, reason: "显示链路具有明确的内置物理端口归属")
        }
        guard ancestors.isEmpty else { return .init(port: nil, reason: "物理端口证据相互冲突") }
        guard evidence.inventoryComplete, !evidence.inventory.isEmpty,
              !evidence.inventory.contains(where: { $0.connection == .unknown }) else {
            return .init(port: nil, reason: "物理端口状态缺失或未知")
        }
        let hdmi = evidence.inventory.filter { $0.kind == .hdmi }
        let usb = evidence.inventory.filter { $0.kind == .usbC }
        // HDMI downstream is deliberately not used: USB-C adapters, docks and some
        // built-in HDMI converters all publish DP -> HDMI transport.
        if hdmi.contains(where: { $0.connection == .connected }), !usb.isEmpty,
           usb.allSatisfy({ $0.connection == .disconnected }) {
            return .init(port: .hdmi, reason: "原生显示链路，HDMI 已连接且所有已枚举 USB-C 端口均未连接")
        }
        if usb.contains(where: { $0.connection == .connected }), !hdmi.isEmpty,
           hdmi.allSatisfy({ $0.connection == .disconnected }) {
            return .init(port: .usbC, reason: "原生显示链路，USB-C 已连接且未发现已连接的内置 HDMI 端口")
        }
        return .init(port: nil, reason: "接口并存或缺少唯一来源证据")
    }
}

struct DisplayTransportIdentity: Equatable {
    let registryPath: String?
    let edid: Data?
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32
}

enum DisplayTransportMatcher {
    static func match(_ display: DisplayTransportIdentity, candidates: [DisplayTransportIdentity]) -> Int? {
        if let path = display.registryPath, !path.isEmpty {
            let matches = candidates.indices.filter { candidates[$0].registryPath == path }
            // A known path that now points to another identity must not fall back
            // to a weaker EDID/model match elsewhere in the registry.
            if !matches.isEmpty {
                guard matches.count == 1, compatible(display, candidates[matches[0]]) else { return nil }
                return matches[0]
            }
        }
        if let edid = display.edid, validEDID(edid) {
            let matches = candidates.indices.filter { candidates[$0].edid == edid && compatible(display, candidates[$0]) }
            return matches.count == 1 ? matches[0] : nil
        }
        guard display.serial != 0 else { return nil }
        let matches = candidates.indices.filter {
            candidates[$0].serial == display.serial && compatible(display, candidates[$0])
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func compatible(_ first: DisplayTransportIdentity, _ second: DisplayTransportIdentity) -> Bool {
        guard first.vendor == second.vendor, first.product == second.product else { return false }
        if first.serial != 0, second.serial != 0, first.serial != second.serial { return false }
        if let firstEDID = first.edid, let secondEDID = second.edid,
           validEDID(firstEDID), validEDID(secondEDID), firstEDID != secondEDID { return false }
        return true
    }

    static func validEDID(_ data: Data) -> Bool {
        let bytes = Array(data)
        guard bytes.count >= 128, bytes.count % 128 == 0,
              Array(bytes.prefix(8)) == [0, 255, 255, 255, 255, 255, 255, 0],
              bytes.count == (Int(bytes[126]) + 1) * 128 else { return false }
        for start in stride(from: 0, to: bytes.count, by: 128) {
            guard bytes[start..<(start + 128)].reduce(UInt8(0), &+) == 0 else { return false }
        }
        return true
    }
}

enum DisplayOutputPresence {
    static func isEnabled(active: Bool, mirrored: Bool, asleep: Bool) -> Bool {
        active || mirrored || asleep
    }
}

/// Positive per-display transport evidence. The fields and real-device fixture
/// shape are documented by the MIT CableScope project:
/// https://github.com/tzzs/cablescope/blob/main/Sources/CableKit/Services/DisplayPortTransportService.swift
/// This parser deliberately requires stronger identity and built-in-parent
/// evidence than its informational UI. Missing data never means an idle link.
struct DisplayPortLinkEvidence: Equatable {
    let port: DisplayOutputPort?
    let active: Bool?
    let vendor: UInt32?
    let product: UInt32?
    let serial: UInt32?

    init(properties: [String: Any]) {
        active = Self.boolean(properties["Active"])
        let metadata = properties["Metadata"] as? [String: Any] ?? [:]
        let manufacturer = properties["ManufacturerName"] as? String ?? metadata["ManufacturerName"] as? String
        vendor = manufacturer.flatMap(Self.packedManufacturer)
        product = Self.number(properties["ProductID"] ?? metadata["ProductID"])
        serial = Self.number(properties["SerialNumber"] ?? metadata["SerialNumber"])
        let parentType = properties["ParentBuiltInPortTypeDescription"] as? String
        let directType = properties["ParentPortTypeDescription"] as? String
        let number = Self.number(properties["ParentBuiltInPortNumber"])
        if Self.boolean(properties["ParentPortBuiltIn"]) == true,
           let type = parentType, directType == nil || directType == type,
           let number, (1...255).contains(number),
           let description = properties["TransportDescription"] as? String,
           Self.matches(description, type: type, number: number) {
            port = type == "HDMI" ? .hdmi : type == "USB-C" ? .usbC : nil
        } else {
            port = nil
        }
    }

    private static func matches(_ description: String, type: String, number: UInt32) -> Bool {
        let parts = description.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Port-\(type)@\(number)" else { return false }
        if parts[1] == "DisplayPort" { return true }
        guard parts[1].hasPrefix("DisplayPort@") else { return false }
        let index = parts[1].dropFirst("DisplayPort@".count)
        return !index.isEmpty && index.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func packedManufacturer(_ value: String) -> UInt32? {
        let letters = Array(value.utf8)
        guard letters.count == 3, letters.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return UInt32(letters[0] - 64) << 10 | UInt32(letters[1] - 64) << 5 | UInt32(letters[2] - 64)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func number(_ value: Any?) -> UInt32? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        guard number.isFinite, number.rounded() == number, (0...Double(UInt32.max)).contains(number) else { return nil }
        return UInt32(number)
    }
}

enum DisplayPortLinkMatcher {
    static func port(for display: DisplayTransportIdentity, among displays: [DisplayTransportIdentity],
                     links: [DisplayPortLinkEvidence]) -> DisplayOutputPort? {
        guard display.serial != 0, display.vendor != 0, display.product != 0 else { return nil }
        let sameDisplay = displays.filter {
            $0.vendor == display.vendor && $0.product == display.product && $0.serial == display.serial
        }
        guard sameDisplay.count == 1 else { return nil }
        let candidates = links.filter {
            $0.active == true && $0.port != nil && $0.vendor == display.vendor
                && $0.product == display.product && $0.serial == display.serial
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0].port
    }
}
