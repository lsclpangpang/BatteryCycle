import AppKit
import Foundation
import IOKit

/// Reads run off the main thread. A burst of notifications requests at most one
/// additional read; the timer also catches drivers that publish no notification.
@MainActor
final class PortMonitor {
    private let reader: @Sendable () -> [PortStatus]
    private let interval: TimeInterval
    private let observesSystemEvents: Bool
    private let onChange: ([PortStatus]) -> Void
    private let readQueue = DispatchQueue(label: "com.local.batterycycle.ports", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var eventSource: PortEventSource?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var running = false
    private var sleeping = false
    private var readInFlight = false
    private var refreshPending = false
    private var generation: UInt64 = 0
    private var knownPorts: [PortStatus] = []
    private var lastPublished: [PortStatus]?

    init(reader: @escaping @Sendable () -> [PortStatus] = { PortReader.read() },
         interval: TimeInterval = 1,
         observesSystemEvents: Bool = true,
         onChange: @escaping ([PortStatus]) -> Void) {
        self.reader = reader
        self.interval = max(0.02, interval)
        self.observesSystemEvents = observesSystemEvents
        self.onChange = onChange
    }

    func start() {
        guard !running else { return }
        running = true
        sleeping = false
        generation &+= 1
        lastPublished = nil
        if observesSystemEvents {
            let source = PortEventSource { [weak self] in
                Task { @MainActor in self?.requestRefresh() }
            }
            eventSource = source
            source.start()
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { monitor in
                monitor.sleeping = true
                monitor.generation &+= 1
                monitor.refreshPending = false
                monitor.publish(monitor.knownPorts.map(Self.unknown))
            }
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { monitor in
                monitor.sleeping = false
                monitor.requestRefresh()
            }
            observe(.default, NSApplication.didBecomeActiveNotification) { $0.requestRefresh() }
            observe(.default, NSApplication.willTerminateNotification) { $0.stop() }
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.requestRefresh() }
        }
        self.timer = timer
        timer.resume()
        requestRefresh()
    }

    func stop() {
        running = false
        generation &+= 1
        refreshPending = false
        timer?.cancel()
        timer = nil
        eventSource?.stop()
        eventSource = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        // An existing read cannot be cancelled. Keep readInFlight until it
        // finishes so stop/start cycles cannot enqueue extra background reads.
    }

    func requestRefresh() {
        guard running, !sleeping else { return }
        guard !readInFlight else {
            refreshPending = true
            return
        }
        readInFlight = true
        let currentGeneration = generation
        let reader = self.reader
        readQueue.async { [weak self] in
            let ports = reader()
            Task { @MainActor [weak self] in
                self?.didRead(ports, generation: currentGeneration)
            }
        }
    }

    private func didRead(_ ports: [PortStatus], generation completedGeneration: UInt64) {
        readInFlight = false
        let followUp = refreshPending
        refreshPending = false
        guard running, !sleeping else { return }
        if completedGeneration == generation {
            let present = Set(ports.map(\.id))
            // A missing registry entry is an unavailable reading, not proof of
            // unplugging. Preserve its observed position without inventing ports.
            knownPorts = PortReader.sorted(ports + knownPorts.filter { !present.contains($0.id) }.map(Self.unknown))
            publish(knownPorts)
        }
        if followUp || completedGeneration != generation { requestRefresh() }
    }

    private static func unknown(_ port: PortStatus) -> PortStatus {
        var port = port
        port.connection = .unknown
        return port
    }

    private func publish(_ ports: [PortStatus]) {
        guard ports != lastPublished else { return }
        lastPublished = ports
        onChange(ports)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (PortMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    deinit {
        timer?.cancel()
        eventSource?.stop()
        for (center, token) in observers { center.removeObserver(token) }
    }
}

/// All IOKit registration, callbacks and cleanup share a serial queue. The
/// borrowed callback pointer remains valid until stop() drains that queue.
private final class PortEventSource: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.local.batterycycle.port-events", qos: .utility)
    private let onChange: @Sendable () -> Void
    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var interests: [UInt64: io_object_t] = [:]
    private var arming = false

    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }

    func start() {
        queue.sync {
            guard notificationPort == nil,
                  let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
            notificationPort = port
            IONotificationPortSetDispatchQueue(port, queue)
            arming = true
            let context = Unmanaged.passUnretained(self).toOpaque()
            for className in PortReader.matchingClasses {
                var appeared: io_iterator_t = 0
                let added: IOServiceMatchingCallback = { context, iterator in
                    guard let context else { return }
                    Unmanaged<PortEventSource>.fromOpaque(context).takeUnretainedValue().drain(iterator, appeared: true)
                }
                if IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching(className),
                                                    added, context, &appeared) == KERN_SUCCESS {
                    iterators.append(appeared)
                    drain(appeared, appeared: true)
                }
                var terminated: io_iterator_t = 0
                let removed: IOServiceMatchingCallback = { context, iterator in
                    guard let context else { return }
                    Unmanaged<PortEventSource>.fromOpaque(context).takeUnretainedValue().drain(iterator, appeared: false)
                }
                if IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching(className),
                                                    removed, context, &terminated) == KERN_SUCCESS {
                    iterators.append(terminated)
                    drain(terminated, appeared: false)
                }
            }
            arming = false
        }
    }

    private func drain(_ iterator: io_iterator_t, appeared: Bool) {
        var changed = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            changed = true
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            if appeared {
                guard interests[id] == nil, let port = notificationPort else { continue }
                var notification: io_object_t = 0
                let callback: IOServiceInterestCallback = { context, _, _, _ in
                    guard let context else { return }
                    Unmanaged<PortEventSource>.fromOpaque(context).takeUnretainedValue().onChange()
                }
                if IOServiceAddInterestNotification(port, service, kIOGeneralInterest, callback,
                                                    Unmanaged.passUnretained(self).toOpaque(), &notification) == KERN_SUCCESS {
                    interests[id] = notification
                }
            } else if let notification = interests.removeValue(forKey: id) {
                IOObjectRelease(notification)
            }
        }
        if changed && !arming { onChange() }
    }

    func stop() {
        queue.sync {
            if let port = notificationPort {
                IONotificationPortDestroy(port)
                notificationPort = nil
            }
            for notification in interests.values { IOObjectRelease(notification) }
            interests.removeAll()
            for iterator in iterators { IOObjectRelease(iterator) }
            iterators.removeAll()
        }
        // Drain any callback already queued when the notification port closed.
        queue.sync {}
    }

    deinit { stop() }
}
