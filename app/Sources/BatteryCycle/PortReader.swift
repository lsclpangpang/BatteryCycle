import Foundation
import IOKit

enum PortConnection: Equatable, Sendable {
    case connected, disconnected, unknown

    var title: String {
        switch self {
        case .connected: return "已连接"
        case .disconnected: return "未连接"
        case .unknown: return "未知"
        }
    }
}

enum PortKind: String, Sendable {
    case magSafe, usbC, hdmi
}

struct PortStatus: Identifiable, Equatable, Sendable {
    let id: String
    let kind: PortKind
    let label: String
    let location: String?
    var connection: PortConnection
}

/// Read-only IORegistry snapshots. The IOKit API is public, but these driver
/// properties are not a stable Apple contract: unavailable values stay unknown.
enum PortReader {
    // IOAccessoryManager contains USB-C and MagSafe; HDMI uses a separate class.
    static let matchingClasses = ["IOAccessoryManager", "AppleHDMIPortController"]

    static func read() -> [PortStatus] {
        var ports: [String: PortStatus] = [:]
        for className in matchingClasses {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className),
                                               &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                if let port = read(service) { ports[port.id] = port }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
        }
        return sorted(Array(ports.values))
    }

    static func sorted(_ ports: [PortStatus]) -> [PortStatus] {
        ports.sorted {
            let left = sortRank($0), right = sortRank($1)
            if left != right { return left < right }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    private static func sortRank(_ port: PortStatus) -> Int {
        switch port.kind {
        case .magSafe: return 0
        case .hdmi: return 100
        case .usbC:
            switch port.location {
            case "left-back": return 10
            case "left-front": return 20
            case "left": return 25
            case "right-back": return 30
            case "right-front": return 40
            case "right": return 45
            default: return 50
            }
        }
    }

    /// Separate decoding from hardware access so malformed or incomplete driver
    /// snapshots can be checked without plugging in specific hardware.
    static func decode(properties: [String: Any], registryID: UInt64,
                       location: String?, ccActive: Bool?) -> PortStatus? {
        // Do not accidentally show a dock's downstream connectors as Mac ports.
        guard boolean(properties["BuiltIn"]) == true,
              let type = properties["PortTypeDescription"] as? String else { return nil }
        let kind: PortKind
        switch type {
        case "USB-C": kind = .usbC
        case "MagSafe", "MagSafe 3": kind = .magSafe
        case "HDMI": kind = .hdmi
        default: return nil
        }

        let number = portNumber(properties["PortNumber"])
        // USB-C @1 and MagSafe @1 are different physical connectors.
        let identity = number.map(String.init) ?? "registry-\(registryID)"
        let active = boolean(properties["ConnectionActive"])
        let connection: PortConnection
        if let active, let ccActive, active != ccActive {
            // An insertion/removal can happen between the two property reads.
            connection = .unknown
        } else if let connected = active ?? ccActive {
            connection = connected ? .connected : .disconnected
        } else {
            connection = .unknown
        }

        let label: String
        switch kind {
        case .magSafe: label = "MagSafe"
        case .hdmi: label = "HDMI"
        case .usbC:
            let positions = ["left-back": "左上", "left-front": "左下", "left": "左侧",
                             "right-back": "右上", "right-front": "右下", "right": "右侧"]
            if let location, let position = positions[location] {
                label = "\(position) USB-C"
            } else {
                // A logical port number does not tell us its physical side.
                label = number.map { "USB-C \($0)" } ?? "USB-C"
            }
        }
        return PortStatus(id: "\(kind.rawValue):\(identity)", kind: kind, label: label,
                          location: location, connection: connection)
    }

    private static func read(_ service: io_service_t) -> PortStatus? {
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = raw?.takeRetainedValue() as? [String: Any] else { return nil }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { return nil }
        return decode(properties: properties, registryID: registryID,
                      location: readLocation(service), ccActive: readCCState(service))
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func readCCState(_ service: io_service_t) -> Bool? {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(children) }
        var child = IOIteratorNext(children)
        while child != 0 {
            let isCC = IOObjectConformsTo(child, "IOPortTransportStateCC") != 0
            let active = isCC ? boolean(property(child, "Active")) : nil
            IOObjectRelease(child)
            if isCC { return active }
            child = IOIteratorNext(children)
        }
        return nil
    }

    private static func readLocation(_ service: io_service_t) -> String? {
        var entry = service
        IOObjectRetain(entry)
        // The HPM ancestor publishes the position on current Apple Silicon Macs.
        // Walk only this short ancestor chain, never the entire registry tree.
        for _ in 0..<32 {
            let value = property(entry, "port-location")
            let location: String?
            if let string = value as? String {
                location = string
            } else if let data = value as? Data {
                location = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
            } else {
                location = nil
            }
            if let location, !location.isEmpty {
                IOObjectRelease(entry)
                return location
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS else { return nil }
            entry = parent
        }
        IOObjectRelease(entry)
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func portNumber(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.intValue > 0 else { return nil }
        return value.intValue
    }
}
