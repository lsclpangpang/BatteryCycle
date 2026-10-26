import CoreGraphics
import Foundation

/// Notifications shorten the time to notice external changes. The controller also polls,
/// because private notifications may be unavailable or disappear when displays reconnect.
/// All methods and the weak observer table are used on the main thread.
final class NativeBrightnessEvents {
    private final class WeakObserver {
        weak var value: NativeBrightnessEvents?
        init(_ value: NativeBrightnessEvents) { self.value = value }
    }

    private static var observers: [UInt32: WeakObserver] = [:]
    private static var nextToken: UInt64 = 1

    private var registration: (display: CGDirectDisplayID, token: UInt32)?
    private var onChange: (() -> Void)?
    private var deliveryPending = false

    /// Returns false if notifications are unavailable; callers must keep their polling fallback.
    @discardableResult
    func start(_ onChange: @escaping () -> Void) -> Bool {
        precondition(Thread.isMainThread)
        stop()
        guard let api = NativeBrightnessAPI.shared,
              let registerBrightness = api.registerBrightness,
              let registerAutomatic = api.registerAutomatic,
              let unregisterBrightness = api.unregisterBrightness,
              api.unregisterAutomatic != nil,
              let display = try? NativeBrightnessDisplay.current(),
              Self.nextToken <= UInt32.max else { return false }

        let token = UInt32(Self.nextToken)
        Self.nextToken += 1
        self.onChange = onChange
        registration = (display.id, token)
        Self.observers[token] = WeakObserver(self)
        guard registerBrightness(display.id, token, nativeBrightnessChanged) == 0 else {
            Self.observers.removeValue(forKey: token)
            registration = nil
            self.onChange = nil
            return false
        }
        guard registerAutomatic(display.id, token, nativeBrightnessChanged) == 0 else {
            Self.observers.removeValue(forKey: token)
            registration = nil
            self.onChange = nil
            _ = unregisterBrightness(display.id, token)
            return false
        }
        return true
    }

    func stop() {
        precondition(Thread.isMainThread)
        guard let registration else { return }
        // Invalidate before calling the framework; already queued callbacks must be harmless.
        self.registration = nil
        onChange = nil
        deliveryPending = false
        Self.remove(registration)
    }

    private static func remove(_ registration: (display: CGDirectDisplayID, token: UInt32)) {
        observers.removeValue(forKey: registration.token)
        if let api = NativeBrightnessAPI.shared {
            _ = api.unregisterBrightness?(registration.display, registration.token)
            _ = api.unregisterAutomatic?(registration.display, registration.token)
        }
    }

    fileprivate static func deliver(token: UInt32) {
        precondition(Thread.isMainThread)
        guard let observer = observers[token]?.value,
              observer.registration?.token == token,
              !observer.deliveryPending else { return }
        observer.deliveryPending = true
        // Defer once more to coalesce a burst and avoid re-entering a brightness write.
        DispatchQueue.main.async { [weak observer] in
            guard let observer, observer.registration?.token == token else { return }
            observer.deliveryPending = false
            observer.onChange?()
        }
    }

    deinit {
        guard let registration else { return }
        // The last reference can be released away from the main thread even when methods
        // are main-thread-only. Never dereference self from delayed framework cleanup.
        if Thread.isMainThread { Self.remove(registration) }
        else { DispatchQueue.main.async { Self.remove(registration) } }
    }
}

private let nativeBrightnessChanged: CFNotificationCallback = { _, observer, _, _, _ in
    let token = UInt32(truncatingIfNeeded: UInt(bitPattern: observer))
    DispatchQueue.main.async { NativeBrightnessEvents.deliver(token: token) }
}
