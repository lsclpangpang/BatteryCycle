import AppKit
import CoreGraphics

struct BrightnessKeyPress: Equatable {
    enum Direction { case increase, decrease }
    let direction: Direction
    /// Original system uptime timestamp, not the time the app eventually handles the key.
    let timestamp: TimeInterval
}

protocol BrightnessKeyMonitoring: AnyObject {
    var requiresPermission: Bool { get }
    func start(onKey: @escaping (BrightnessKeyPress) -> Void, onUnavailable: @escaping () -> Void) -> Bool
    func stop()
    func requestPermission()
}

/// Observes only system media-key events while minimum brightness is active.
/// It never consumes input, subscribes to ordinary typing, or records key history.
final class NativeBrightnessKeyMonitor: BrightnessKeyMonitoring {
    private final class WeakMonitor {
        weak var value: NativeBrightnessKeyMonitor?
        init(_ value: NativeBrightnessKeyMonitor) { self.value = value }
    }

    private static var monitors: [UInt: WeakMonitor] = [:]
    private static var nextToken: UInt = 1

    private var token: UInt?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var localMonitor: Any?
    private var onKey: ((BrightnessKeyPress) -> Void)?
    private var onUnavailable: (() -> Void)?
    // Deduplicate the same event delivered by the global tap and local AppKit monitor.
    private var lastDelivery: (timestamp: TimeInterval, data: Int)?

    var requiresPermission: Bool { !CGPreflightListenEventAccess() }

    /// Called only by the permission button. Checking/starting never requests access.
    func requestPermission() {
        precondition(Thread.isMainThread)
        _ = CGRequestListenEventAccess()
    }

    @discardableResult
    func start(onKey: @escaping (BrightnessKeyPress) -> Void, onUnavailable: @escaping () -> Void) -> Bool {
        precondition(Thread.isMainThread)
        stop()
        guard !requiresPermission, Self.nextToken < UInt.max else { return false }
        let token = Self.nextToken
        Self.nextToken += 1
        let mask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: nativeBrightnessKeyEvent,
            userInfo: UnsafeMutableRawPointer(bitPattern: token)
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        self.token = token
        self.tap = tap
        self.source = source
        self.onKey = onKey
        self.onUnavailable = onUnavailable
        Self.monitors[token] = WeakMonitor(self)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            stop()
            return false
        }
        // App-targeted events can reach Cocoa without passing through the global tap.
        // This fallback observes only this app and leaves the original event untouched.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            if let self, self.token == token { self.deliver(event) }
            return event
        }
        return true
    }

    func stop() {
        precondition(Thread.isMainThread)
        Self.remove(token: token, tap: tap, source: source, localMonitor: localMonitor)
        token = nil
        tap = nil
        source = nil
        localMonitor = nil
        onKey = nil
        onUnavailable = nil
        lastDelivery = nil
    }

    /// NX_SYSDEFINED / NX_SUBTYPE_AUX_CONTROL_BUTTONS from the IOKit event headers.
    /// Accept screen brightness up/down only, including held-key repeats; not F1/F2,
    /// keyboard illumination, media playback, or a change in the brightness value itself.
    static func isBrightnessKey(_ event: NSEvent) -> Bool {
        brightnessKeyPress(event) != nil
    }

    static func brightnessKeyPress(_ event: NSEvent) -> BrightnessKeyPress? {
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return nil }
        let data = UInt32(truncatingIfNeeded: event.data1)
        let key = (data >> 16) & 0xFFFF
        let state = (data >> 8) & 0xFF
        guard (key == 2 || key == 3), state == 0xA else { return nil }
        // An unreliable timestamp may rule out race compensation, but must never stop a
        // recognized brightness key from releasing minimum mode.
        return BrightnessKeyPress(direction: key == 2 ? .increase : .decrease, timestamp: event.timestamp)
    }

    private func deliver(_ event: NSEvent) {
        guard token != nil, let key = Self.brightnessKeyPress(event) else { return }
        if event.timestamp > 0, let lastDelivery,
           lastDelivery.timestamp == event.timestamp, lastDelivery.data == event.data1 { return }
        lastDelivery = (event.timestamp, event.data1)
        // This source runs on the main run loop. Notify immediately so the controller
        // can stop enforcing minimum brightness before processing subsequent updates.
        onKey?(key)
    }

    fileprivate static func handle(type: CGEventType, event: CGEvent, token: UInt) {
        precondition(Thread.isMainThread)
        guard let monitor = monitors[token]?.value, monitor.token == token else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            guard let tap = monitor.tap else { return }
            guard !monitor.requiresPermission else {
                monitor.reportUnavailable()
                return
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            if !CGEvent.tapIsEnabled(tap: tap) { monitor.reportUnavailable() }
        } else if type.rawValue == UInt32(NSEvent.EventType.systemDefined.rawValue),
                  let nsEvent = NSEvent(cgEvent: event) {
            monitor.deliver(nsEvent)
        }
    }

    private func reportUnavailable() {
        let unavailable = onUnavailable
        stop()
        unavailable?()
    }

    private static func remove(token: UInt?, tap: CFMachPort?, source: CFRunLoopSource?, localMonitor: Any?) {
        if let token { monitors.removeValue(forKey: token) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }

    deinit {
        let token = token, tap = tap, source = source, localMonitor = localMonitor
        if Thread.isMainThread { Self.remove(token: token, tap: tap, source: source, localMonitor: localMonitor) }
        else { DispatchQueue.main.async { Self.remove(token: token, tap: tap, source: source, localMonitor: localMonitor) } }
    }
}

private let nativeBrightnessKeyEvent: CGEventTapCallBack = { _, type, event, userInfo in
    NativeBrightnessKeyMonitor.handle(type: type, event: event, token: UInt(bitPattern: userInfo))
    // A listen-only tap always passes the system event through unchanged.
    return Unmanaged.passUnretained(event)
}
