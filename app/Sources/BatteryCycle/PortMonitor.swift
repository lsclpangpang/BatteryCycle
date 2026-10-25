import AppKit
import Foundation
import IOKit

/// Reads run off the main thread. A burst of notifications requests at most one
/// additional read; the timer also catches drivers that publish no notification.
@MainActor
final class PortMonitor {
    private let reader: @Sendable () -> [PortStatus]
    private let powerReader: (@Sendable () -> PowerTelemetry)?
    private let onPowerChange: ((PowerTelemetry) -> Void)?
    private let interval: TimeInterval
    private let observesSystemEvents: Bool
    private let onChange: ([PortStatus]) -> Void
    private let readQueue = DispatchQueue(label: "com.local.batterycycle.ports", qos: .utility,
                                         autoreleaseFrequency: .workItem)
    private var timer: DispatchSourceTimer?
    private var eventSource: PortEventSource?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var running = false
    private var sleeping = false
    private var readInFlight = false
    private var refreshPending = false
    private var generation: UInt64 = 0
    /// Changes only at start/stop. Normal sleep invalidates reads without
    /// invalidating the wake observer registered for the same running session.
    private var sessionID: UInt64 = 0
    private var knownPorts: [PortStatus] = []
    private var positionCapacities: [String: Int] = [:]
    private var lastPublished: [PortStatus]?
    private var lastPowerPublished: PowerTelemetry?

    init(reader: @escaping @Sendable () -> [PortStatus] = { PortReader.read() },
         powerReader: (@Sendable () -> PowerTelemetry)? = nil,
         onPowerChange: ((PowerTelemetry) -> Void)? = nil,
         interval: TimeInterval = 1,
         observesSystemEvents: Bool = true,
         onChange: @escaping ([PortStatus]) -> Void) {
        self.reader = reader
        self.powerReader = powerReader
        self.onPowerChange = onPowerChange
        self.interval = max(0.02, interval)
        self.observesSystemEvents = observesSystemEvents
        self.onChange = onChange
    }

    func start() {
        guard !running else { return }
        running = true
        sleeping = false
        generation &+= 1
        sessionID &+= 1
        lastPublished = nil
        lastPowerPublished = nil
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
                let sleepGeneration = monitor.generation
                monitor.publish(monitor.knownPorts.map(Self.unknown))
                // The port subscriber may synchronously stop/restart us.
                if monitor.running, monitor.sleeping, monitor.generation == sleepGeneration {
                    monitor.publishPower(.unavailable)
                }
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
        sessionID &+= 1
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
        let powerReader = self.powerReader
        readQueue.async { [weak self] in
            let ports = reader()
            let power = powerReader?()
            Task { @MainActor [weak self] in
                self?.didRead(ports, power: power, generation: currentGeneration)
            }
        }
    }

    private func didRead(_ ports: [PortStatus], power: PowerTelemetry?, generation completedGeneration: UInt64) {
        readInFlight = false
        let followUp = refreshPending
        refreshPending = false
        guard running, !sleeping else { return }
        if completedGeneration == generation {
            let present = Set(ports.map(\.id))
            var occupied = Dictionary(grouping: ports.compactMap(Self.physicalPosition), by: { $0 })
                .mapValues { $0.count }
            for (position, count) in occupied {
                positionCapacities[position] = max(positionCapacities[position, default: 0], count)
            }
            // A missing registry entry is an unavailable reading, not proof of
            // unplugging. Preserve its observed position without inventing ports.
            let missing = knownPorts.filter { !present.contains($0.id) }
            var retained = missing.filter { !Self.hasRegistryIdentity($0) }
            for old in retained {
                if let position = Self.physicalPosition(old) { occupied[position, default: 0] += 1 }
            }
            let fallback = missing.filter(Self.hasRegistryIdentity)
            // A coarse location such as "left" may contain multiple ports. Keep
            // the largest simultaneously observed count, not every historical ID.
            // Prefer existing unknown slots so repeated rebuilds of the remaining
            // controller do not displace a separately observed, now missing port.
            for old in fallback.filter({ $0.connection == .unknown }) + fallback.filter({ $0.connection != .unknown }) {
                guard let position = Self.physicalPosition(old),
                      occupied[position, default: 0] < positionCapacities[position, default: 0] else { continue }
                occupied[position, default: 0] += 1
                retained.append(old)
            }
            knownPorts = PortReader.sorted(ports + retained.map(Self.unknown))
            publish(knownPorts)
            // A subscriber may stop/restart the monitor synchronously. Do not
            // deliver the rest of the old snapshot into that new lifecycle.
            if running, !sleeping, completedGeneration == generation, let power {
                publishPower(power)
            }
        }
        if followUp || completedGeneration != generation { requestRefresh() }
    }

    private static func unknown(_ port: PortStatus) -> PortStatus {
        var port = port
        port.connection = .unknown
        return port
    }

    private static func physicalPosition(_ port: PortStatus) -> String? {
        guard let location = port.location,
              ["left-back", "left-front", "left", "right-back", "right-front", "right"].contains(location) else { return nil }
        return "\(port.kind.rawValue):\(location)"
    }

    private static func hasRegistryIdentity(_ port: PortStatus) -> Bool {
        port.id.hasPrefix("\(port.kind.rawValue):registry-")
    }

    private func publish(_ ports: [PortStatus]) {
        guard ports != lastPublished else { return }
        lastPublished = ports
        onChange(ports)
    }

    private func publishPower(_ power: PowerTelemetry) {
        guard power != lastPowerPublished else { return }
        lastPowerPublished = power
        onPowerChange?(power)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (PortMonitor) -> Void) {
        let observedSession = sessionID
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, self.sessionID == observedSession else { return }
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
