import Carbon
import AppKit
import Foundation

protocol BrightnessRestoreShortcutHandling: AnyObject {
    func start(_ callback: @escaping () -> Void) -> Bool
    func stop()
}

/// A way to restore a zero-backlight panel without finding a menu on a dark screen.
/// Carbon hot keys work across applications without an Accessibility permission prompt.
final class BrightnessRestoreShortcut: BrightnessRestoreShortcutHandling {
    private final class WeakShortcut {
        weak var value: BrightnessRestoreShortcut?
        init(_ value: BrightnessRestoreShortcut) { self.value = value }
    }

    private static let signature: OSType = 0x42434D42 // BCMB
    private static var shortcuts: [UInt32: WeakShortcut] = [:]
    private static var nextToken: UInt64 = 1

    private var token: UInt32?
    private var key: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var callback: (() -> Void)?
    private var deliveryPending = false
    private var localMonitor: Any?

    /// Registers Control + Option + Command + B. A conflicting shortcut causes failure.
    @discardableResult
    func start(_ callback: @escaping () -> Void) -> Bool {
        precondition(Thread.isMainThread)
        stop()
        guard Self.nextToken <= UInt32.max else { return false }
        let token = UInt32(Self.nextToken)
        Self.nextToken += 1
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handler: EventHandlerRef?
        let installed = InstallEventHandler(
            GetApplicationEventTarget(), brightnessRestoreHotKeyPressed,
            1, &eventType, UnsafeMutableRawPointer(bitPattern: UInt(token)), &handler
        )
        guard installed == noErr, let handler else { return false }
        var key: EventHotKeyRef?
        let registered = RegisterEventHotKey(
            UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: Self.signature, id: token),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &key
        )
        guard registered == noErr, let key else {
            RemoveEventHandler(handler)
            return false
        }
        self.token = token
        self.handler = handler
        self.key = key
        self.callback = callback
        Self.shortcuts[token] = WeakShortcut(self)
        // Foreground events can reach Cocoa directly. Observe only this app; Carbon
        // remains the global shortcut and both paths share the same deferred delivery.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.token == token, Self.matches(event) else { return event }
            Self.enqueueDelivery(token: token)
            return nil
        }
        return true
    }

    func stop() {
        precondition(Thread.isMainThread)
        Self.remove(token: token, key: key, handler: handler, localMonitor: localMonitor)
        token = nil
        callback = nil
        deliveryPending = false
        key = nil
        handler = nil
        localMonitor = nil
    }

    private static func remove(token: UInt32?, key: EventHotKeyRef?, handler: EventHandlerRef?, localMonitor: Any?) {
        if let token { shortcuts.removeValue(forKey: token) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let key { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }

    static func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat, event.keyCode == UInt16(kVK_ANSI_B) else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        return event.modifierFlags.intersection(relevant) == [.command, .option, .control]
    }

    fileprivate static func handle(event: EventRef?, token: UInt32) -> OSStatus {
        guard let event,
              GetEventClass(event) == OSType(kEventClassKeyboard),
              GetEventKind(event) == UInt32(kEventHotKeyPressed) else { return OSStatus(eventNotHandledErr) }
        var keyID = EventHotKeyID()
        let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &keyID)
        guard result == noErr, keyID.signature == signature, keyID.id == token else {
            return OSStatus(eventNotHandledErr)
        }
        enqueueDelivery(token: token)
        return noErr
    }

    private static func enqueueDelivery(token: UInt32) {
        // Defer until Carbon/Cocoa has returned from dispatch, and coalesce duplicate
        // deliveries before the callback unregisters itself.
        DispatchQueue.main.async {
            guard let shortcut = shortcuts[token]?.value,
                  shortcut.token == token, !shortcut.deliveryPending else { return }
            shortcut.deliveryPending = true
            DispatchQueue.main.async { [weak shortcut] in
                guard let shortcut, shortcut.token == token else { return }
                shortcut.deliveryPending = false
                shortcut.callback?()
            }
        }
    }

    deinit {
        let token = token, key = key, handler = handler, localMonitor = localMonitor
        if Thread.isMainThread { Self.remove(token: token, key: key, handler: handler, localMonitor: localMonitor) }
        else { DispatchQueue.main.async { Self.remove(token: token, key: key, handler: handler, localMonitor: localMonitor) } }
    }
}

private let brightnessRestoreHotKeyPressed: EventHandlerUPP = { _, event, userData in
    let token = UInt32(truncatingIfNeeded: UInt(bitPattern: userData))
    return BrightnessRestoreShortcut.handle(event: event, token: token)
}
