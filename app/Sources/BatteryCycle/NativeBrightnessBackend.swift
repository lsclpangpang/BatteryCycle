import CoreGraphics
import ColorSync
import Foundation

/// Brightness changes belong to the logged-in user, not the privileged charging daemon.
/// Resolve the built-in panel for every operation: the main display can be an external monitor.
final class NativeBrightnessBackend: BrightnessBackend {
    func snapshot() throws -> BrightnessSnapshot {
        let api = try NativeBrightnessAPI.required()
        let display = try NativeBrightnessDisplay.current()
        try api.requireSupport(display.id)
        var brightness: Float = 0
        try NativeBrightnessError.check(api.getBrightness(display.id, &brightness), operation: "读取屏幕亮度")
        guard brightness.isFinite, (0...1).contains(brightness) else {
            throw NativeBrightnessError.invalidBrightness
        }
        var automatic = false
        try NativeBrightnessError.check(api.getAutomatic(display.id, &automatic), operation: "读取自动亮度设置")
        return BrightnessSnapshot(displayID: display.uuid, brightness: brightness, automaticBrightness: automatic)
    }

    func setBrightness(_ value: Float, displayID: String) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw NativeBrightnessError.invalidBrightness
        }
        let api = try NativeBrightnessAPI.required()
        let display = try NativeBrightnessDisplay.current(matching: displayID)
        try api.requireSupport(display.id)
        try NativeBrightnessError.check(api.setBrightness(display.id, value), operation: "设置屏幕亮度")
    }

    func setAutomaticBrightness(_ enabled: Bool, displayID: String) throws {
        let api = try NativeBrightnessAPI.required()
        let display = try NativeBrightnessDisplay.current(matching: displayID)
        try api.requireSupport(display.id)
        try NativeBrightnessError.check(api.setAutomatic(display.id, enabled), operation: "设置自动亮度")
    }
}

enum NativeBrightnessError: LocalizedError {
    case unsupportedSystem
    case unavailableDisplay
    case changedDisplay
    case unsupportedDisplay
    case invalidBrightness
    case operation(String, Int32)

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem: return "当前系统不支持控制屏幕亮度和自动亮度"
        case .unavailableDisplay: return "内置屏幕暂不可用，请打开屏幕后重试"
        case .changedDisplay: return "内置屏幕与保存的恢复记录不匹配，未修改亮度"
        case .unsupportedDisplay: return "此内置屏幕不支持暂停自动亮度，无法锁定最低亮度"
        case .invalidBrightness: return "系统返回的屏幕亮度无效"
        case let .operation(name, code): return "\(name)失败（\(code)）"
        }
    }

    static func check(_ result: Int32, operation: String) throws {
        guard result == 0 else { throw Self.operation(operation, result) }
    }
}

struct NativeBrightnessDisplay {
    let id: CGDirectDisplayID
    let uuid: String

    static func current(matching uuid: String? = nil) throws -> NativeBrightnessDisplay {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            throw NativeBrightnessError.unavailableDisplay
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            throw NativeBrightnessError.unavailableDisplay
        }
        // The controller suspends writes using workspace sleep events. Do not reject a
        // zero-backlight panel here: it must remain addressable when restoring brightness.
        guard let id = ids.prefix(Int(count)).first(where: {
            CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0
        }), let displayUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
            throw NativeBrightnessError.unavailableDisplay
        }
        let identifier = CFUUIDCreateString(kCFAllocatorDefault, displayUUID) as String
        if let uuid, identifier != uuid { throw NativeBrightnessError.changedDisplay }
        return NativeBrightnessDisplay(id: id, uuid: identifier)
    }
}

/// Private framework symbols are checked at runtime so unsupported macOS releases fail visibly.
/// Handles intentionally stay loaded for the process lifetime, including pending notification callbacks.
struct NativeBrightnessAPI {
    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias GetAutomatic = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32
    typealias SetAutomatic = @convention(c) (CGDirectDisplayID, Bool) -> Int32
    typealias Capability = @convention(c) (CGDirectDisplayID) -> Bool
    typealias Register = @convention(c) (CGDirectDisplayID, CGDirectDisplayID, CFNotificationCallback) -> Int32
    typealias Unregister = @convention(c) (CGDirectDisplayID, CGDirectDisplayID) -> Int32

    let getBrightness: GetBrightness
    let setBrightness: SetBrightness
    let getAutomatic: GetAutomatic
    let setAutomatic: SetAutomatic
    let canChangeBrightness: Capability
    let hasAutomaticBrightness: Capability
    let registerBrightness: Register?
    let registerAutomatic: Register?
    let unregisterBrightness: Unregister?
    let unregisterAutomatic: Unregister?

    static let shared: NativeBrightnessAPI? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else {
            return nil
        }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let getBrightness = symbol("DisplayServicesGetBrightness", GetBrightness.self),
              let setBrightness = symbol("DisplayServicesSetBrightness", SetBrightness.self),
              let getAutomatic = symbol("DisplayServicesAmbientLightCompensationEnabled", GetAutomatic.self),
              let setAutomatic = symbol("DisplayServicesEnableAmbientLightCompensation", SetAutomatic.self),
              let canChangeBrightness = symbol("DisplayServicesCanChangeBrightness", Capability.self),
              let hasAutomaticBrightness = symbol("DisplayServicesHasAmbientLightCompensation", Capability.self)
        else { return nil }
        return NativeBrightnessAPI(
            getBrightness: getBrightness, setBrightness: setBrightness,
            getAutomatic: getAutomatic, setAutomatic: setAutomatic,
            canChangeBrightness: canChangeBrightness, hasAutomaticBrightness: hasAutomaticBrightness,
            registerBrightness: symbol("DisplayServicesRegisterForBrightnessChangeNotifications", Register.self),
            registerAutomatic: symbol("DisplayServicesRegisterForAmbientLightCompensationNotifications", Register.self),
            unregisterBrightness: symbol("DisplayServicesUnregisterForBrightnessChangeNotifications", Unregister.self),
            unregisterAutomatic: symbol("DisplayServicesUnregisterForAmbientLightCompensationNotifications", Unregister.self)
        )
    }()

    static func required() throws -> NativeBrightnessAPI {
        guard let shared else { throw NativeBrightnessError.unsupportedSystem }
        return shared
    }

    func requireSupport(_ display: CGDirectDisplayID) throws {
        guard canChangeBrightness(display), hasAutomaticBrightness(display) else {
            throw NativeBrightnessError.unsupportedDisplay
        }
    }
}
