import Foundation
import AppKit
#if canImport(XCTest) && !PORT_MONITOR_STANDALONE
import XCTest
@testable import BatteryCycle
#elseif PORT_MONITOR_STANDALONE
private var monitorFailures = 0
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) {
    if lhs != rhs { monitorFailures += 1; print("FAIL: \(lhs) != \(rhs)") }
}

final class MonitorExpectation: @unchecked Sendable {
    let description: String
    var isInverted = false
    private let lock = NSLock()
    private var fulfilled = false
    init(description: String) { self.description = description }
    func fulfill() { lock.withLock { fulfilled = true } }
    var isFulfilled: Bool { lock.withLock { fulfilled } }
}

class XCTestCase {
    func expectation(description: String) -> MonitorExpectation { MonitorExpectation(description: description) }
    @MainActor
    func fulfillment(of expectations: [MonitorExpectation], timeout: TimeInterval) async {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if expectations.allSatisfy({ !$0.isInverted && $0.isFulfilled }) { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        for expectation in expectations where expectation.isFulfilled == expectation.isInverted {
            monitorFailures += 1
            print("FAIL: \(expectation.description)")
        }
    }
}

@main
private struct PortMonitorTestRunner {
    @MainActor static func main() async {
        let tests = PortMonitorTests()
        await tests.testStartReadsImmediatelyWithoutWaitingForTimer()
        await tests.testTimerFindsChangesWithoutAnyDriverNotification()
        await tests.testStopDiscardsAReadAlreadyInProgress()
        await tests.testRefreshBurstDuringReadHasOnlyOneFollowUpRead()
        await tests.testMissingPreviouslyKnownPortBecomesUnknown()
        await tests.testRestartRejectsThePreviousSessionsRead()
        await tests.testPowerChangesPublishWhenPortsStayTheSame()
        await tests.testSleepClearsPowerAndWakeReadsAgain()
        await tests.testStopFromPortCallbackDoesNotPublishOldPower()
        await tests.testQueuedSleepFromPreviousSessionDoesNotSuspendRestart()
        await tests.testSleepPortCallbackCannotPublishPowerAfterStopOrRestart()
        await tests.testRegistryRebuildReplacesOnlyItsPreviousPhysicalPosition()
        await tests.testUnlocatedRegistryIdentitiesDoNotAccumulate()
        await tests.testConcurrentSameSidePortsRetainTheirMissingSibling()
        await tests.testSameSideRebuildsStayWithinObservedConcurrentCapacity()
        print("PortMonitor: 15 checks, \(monitorFailures) failures")
        if monitorFailures > 0 { exit(1) }
    }
}
#endif

#if canImport(XCTest) || PORT_MONITOR_STANDALONE
final class PortMonitorTests: XCTestCase {
    private let connected = PortStatus(
        id: "USB-C:3", kind: .usbC, label: "右侧 USB-C", location: "right", connection: .connected
    )

    @MainActor
    func testStartReadsImmediatelyWithoutWaitingForTimer() async {
        let published = expectation(description: "initial port snapshot")
        let reader = ControlledPortReader(ports: [connected])
        let monitor = PortMonitor(reader: { reader.read() }, interval: 60, observesSystemEvents: false) { ports in
            XCTAssertEqual(ports, [self.connected])
            published.fulfill()
        }
        monitor.start()
        await fulfillment(of: [published], timeout: 1)
        monitor.stop()
        XCTAssertEqual(reader.readCount, 1)
    }

    @MainActor
    func testTimerFindsChangesWithoutAnyDriverNotification() async {
        let initial = expectation(description: "initial snapshot")
        let changed = expectation(description: "timer observed disconnect")
        let reader = ControlledPortReader(ports: [connected])
        let monitor = PortMonitor(reader: { reader.read() }, interval: 0.03, observesSystemEvents: false) { ports in
            if ports.first?.connection == .connected { initial.fulfill() }
            if ports.first?.connection == .disconnected { changed.fulfill() }
        }
        monitor.start()
        await fulfillment(of: [initial], timeout: 1)
        var disconnected = connected
        disconnected.connection = .disconnected
        reader.setPorts([disconnected])
        await fulfillment(of: [changed], timeout: 1)
        monitor.stop()
    }

    @MainActor
    func testStopDiscardsAReadAlreadyInProgress() async {
        let started = expectation(description: "background read started")
        let unwanted = expectation(description: "stopped monitor must not publish")
        unwanted.isInverted = true
        let reader = ControlledPortReader(ports: [connected], blockFirstRead: true)
        reader.onRead = { count in if count == 1 { started.fulfill() } }
        let monitor = PortMonitor(reader: { reader.read() }, interval: 60, observesSystemEvents: false) { _ in
            unwanted.fulfill()
        }
        monitor.start()
        await fulfillment(of: [started], timeout: 1)
        monitor.stop()
        reader.unblock()
        await fulfillment(of: [unwanted], timeout: 0.1)
        XCTAssertEqual(reader.readCount, 1)
    }

    @MainActor
    func testRefreshBurstDuringReadHasOnlyOneFollowUpRead() async {
        let started = expectation(description: "first read blocked")
        let followUp = expectation(description: "one follow-up read")
        let excess = expectation(description: "no accumulated reads")
        excess.isInverted = true
        let reader = ControlledPortReader(ports: [connected], blockFirstRead: true)
        reader.onRead = { count in
            if count == 1 { started.fulfill() }
            if count == 2 { followUp.fulfill() }
            if count > 2 { excess.fulfill() }
        }
        let monitor = PortMonitor(reader: { reader.read() }, interval: 60, observesSystemEvents: false) { _ in }
        monitor.start()
        await fulfillment(of: [started], timeout: 1)
        for _ in 0..<50 { monitor.requestRefresh() }
        reader.unblock()
        await fulfillment(of: [followUp], timeout: 1)
        await fulfillment(of: [excess], timeout: 0.1)
        monitor.stop()
        XCTAssertEqual(reader.readCount, 2)
        XCTAssertEqual(reader.maximumConcurrentReads, 1)
    }

    @MainActor
    func testMissingPreviouslyKnownPortBecomesUnknown() async {
        let initial = expectation(description: "known port")
        let unknown = expectation(description: "missing port retained as unknown")
        let reader = ControlledPortReader(ports: [connected])
        let monitor = PortMonitor(reader: { reader.read() }, interval: 60, observesSystemEvents: false) { ports in
            if ports.first?.connection == .connected { initial.fulfill() }
            if ports.first?.connection == .unknown {
                XCTAssertEqual(ports.first?.id, self.connected.id)
                XCTAssertEqual(ports.first?.location, "right")
                unknown.fulfill()
            }
        }
        monitor.start()
        await fulfillment(of: [initial], timeout: 1)
        reader.setPorts([])
        monitor.requestRefresh()
        await fulfillment(of: [unknown], timeout: 1)
        monitor.stop()
    }

    @MainActor
    func testRestartRejectsThePreviousSessionsRead() async {
        let started = expectation(description: "old read blocked")
        let fresh = expectation(description: "only new session publishes")
        let reader = ControlledPortReader(ports: [connected], blockFirstRead: true)
        reader.onRead = { count in if count == 1 { started.fulfill() } }
        let monitor = PortMonitor(reader: { reader.read() }, interval: 60, observesSystemEvents: false) { ports in
            XCTAssertEqual(ports.first?.connection, .disconnected)
            fresh.fulfill()
        }
        monitor.start()
        await fulfillment(of: [started], timeout: 1)
        monitor.stop()
        var disconnected = connected
        disconnected.connection = .disconnected
        reader.setPorts([disconnected])
        monitor.start()
        monitor.start()
        reader.unblock()
        await fulfillment(of: [fresh], timeout: 1)
        monitor.stop()
        XCTAssertEqual(reader.readCount, 2)
        XCTAssertEqual(reader.maximumConcurrentReads, 1)
    }

    @MainActor
    func testPowerChangesPublishWhenPortsStayTheSame() async {
        let initial = expectation(description: "first power reading")
        let changed = expectation(description: "power changes independently of ports")
        let power = ControlledPowerReader()
        var portPublications = 0
        let monitor = PortMonitor(reader: { [] }, powerReader: { power.read() },
                                  onPowerChange: { value in
            if value == .unavailable { initial.fulfill() }
            if value.source == .battery && value.batteryWatts == -14 { changed.fulfill() }
        }, interval: 60, observesSystemEvents: false) { _ in portPublications += 1 }
        monitor.start()
        await fulfillment(of: [initial], timeout: 1)
        power.set(PowerTelemetry(source: .battery, batteryWatts: -14, externalConnected: false))
        monitor.requestRefresh()
        await fulfillment(of: [changed], timeout: 1)
        monitor.stop()
        XCTAssertEqual(portPublications, 1)
        XCTAssertEqual(power.readOnMainThread, false)
    }

    @MainActor
    func testSleepClearsPowerAndWakeReadsAgain() async {
        let initial = expectation(description: "initial battery power")
        let cleared = expectation(description: "sleep invalidates old power")
        let resumed = expectation(description: "wake refreshes power")
        let power = ControlledPowerReader()
        power.set(PowerTelemetry(source: .battery, batteryWatts: -14, externalConnected: false))
        let monitor = PortMonitor(reader: { [] }, powerReader: { power.read() },
                                  onPowerChange: { value in
            if value.source == .battery { initial.fulfill() }
            if value == .unavailable { cleared.fulfill() }
            if value.source == .external { resumed.fulfill() }
        }, interval: 60) { _ in }
        monitor.start()
        await fulfillment(of: [initial], timeout: 1)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await fulfillment(of: [cleared], timeout: 1)
        power.set(PowerTelemetry(source: .external, inputWatts: 16, batteryWatts: 0, externalConnected: true))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fulfillment(of: [resumed], timeout: 1)
        monitor.stop()
    }

    @MainActor
    func testStopFromPortCallbackDoesNotPublishOldPower() async {
        let stopped = expectation(description: "subscriber stopped monitor")
        let stalePower = expectation(description: "no power callback after stop")
        stalePower.isInverted = true
        var monitor: PortMonitor?
        monitor = PortMonitor(reader: { [] }, powerReader: { .unavailable },
                              onPowerChange: { _ in stalePower.fulfill() },
                              interval: 60, observesSystemEvents: false) { _ in
            monitor?.stop()
            stopped.fulfill()
        }
        monitor?.start()
        await fulfillment(of: [stopped], timeout: 1)
        await fulfillment(of: [stalePower], timeout: 0.05)
        monitor = nil
    }

    @MainActor
    func testQueuedSleepFromPreviousSessionDoesNotSuspendRestart() async {
        let initial = expectation(description: "first session published")
        let resumed = expectation(description: "new session remains awake")
        let staleSleep = expectation(description: "old session sleep must be discarded")
        staleSleep.isInverted = true
        let power = ControlledPowerReader()
        power.set(PowerTelemetry(source: .battery, batteryWatts: -14))
        let monitor = PortMonitor(reader: { [] }, powerReader: { power.read() },
                                  onPowerChange: { value in
            if value.source == .battery { initial.fulfill() }
            if value.source == .external { resumed.fulfill() }
            if value == .unavailable { staleSleep.fulfill() }
        }, interval: 60) { _ in }
        monitor.start()
        await fulfillment(of: [initial], timeout: 1)
        // The notification callback has queued its main-actor Task, but the
        // synchronous stop/start below happens before that Task can execute.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        monitor.stop()
        power.set(PowerTelemetry(source: .external, inputWatts: 16, batteryWatts: 0))
        monitor.start()
        await fulfillment(of: [resumed], timeout: 1)
        await fulfillment(of: [staleSleep], timeout: 0.05)
        monitor.stop()
    }

    @MainActor
    func testSleepPortCallbackCannotPublishPowerAfterStopOrRestart() async {
        for restart in [false, true] {
            let initial = expectation(description: "power before sleep")
            let stopped = expectation(description: "port subscriber stops during sleep publication")
            let stalePower = expectation(description: "old sleep handler cannot publish power")
            stalePower.isInverted = true
            let resumed = restart ? expectation(description: "new session power") : nil
            let power = ControlledPowerReader()
            power.set(PowerTelemetry(source: .battery, batteryWatts: -14))
            let port = connected
            var monitor: PortMonitor?
            monitor = PortMonitor(reader: { [port] }, powerReader: { power.read() },
                                  onPowerChange: { value in
                if value.source == .battery { initial.fulfill() }
                if value.source == .external { resumed?.fulfill() }
                if value == .unavailable { stalePower.fulfill() }
            }, interval: 60) { ports in
                guard ports.first?.connection == .unknown else { return }
                monitor?.stop()
                if restart {
                    power.set(PowerTelemetry(source: .external, inputWatts: 16, batteryWatts: 0))
                    monitor?.start()
                }
                stopped.fulfill()
            }
            monitor?.start()
            await fulfillment(of: [initial], timeout: 1)
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            await fulfillment(of: [stopped], timeout: 1)
            if let resumed { await fulfillment(of: [resumed], timeout: 1) }
            await fulfillment(of: [stalePower], timeout: 0.05)
            monitor?.stop()
            monitor = nil
        }
    }

    @MainActor
    func testRegistryRebuildReplacesOnlyItsPreviousPhysicalPosition() async {
        let rebuilt = expectation(description: "twenty reconstructions of one controller")
        let missing = expectation(description: "last observed physical positions remain unknown")
        let left = PortStatus(id: "usbC:1", kind: .usbC, label: "左上 USB-C",
                              location: "left-back", connection: .connected)
        let reader = ControlledPortReader(ports: [left, fallbackPort(1, location: "right")])
        var count = 0
        var last: [PortStatus] = []
        var awaitingMissing = false
        var monitor: PortMonitor?
        monitor = PortMonitor(reader: { reader.read() }, interval: 60, observesSystemEvents: false) { ports in
            last = ports
            if awaitingMissing {
                missing.fulfill()
                return
            }
            count += 1
            if count < 20 {
                reader.setPorts([self.fallbackPort(UInt64(count + 1), location: "right")])
                monitor?.requestRefresh()
            } else { rebuilt.fulfill() }
        }
        monitor?.start()
        await fulfillment(of: [rebuilt], timeout: 1)
        XCTAssertEqual(last.count, 2)
        XCTAssertEqual(last.first(where: { $0.id == left.id })?.connection, .unknown)
        XCTAssertEqual(last.filter { $0.location == "right" }.map(\.id), ["usbC:registry-20"])
        awaitingMissing = true
        reader.setPorts([])
        monitor?.requestRefresh()
        await fulfillment(of: [missing], timeout: 1)
        XCTAssertEqual(last.count, 2)
        XCTAssertEqual(last.map(\.connection), [.unknown, .unknown])
        monitor?.stop()
        monitor = nil
    }

    @MainActor
    func testUnlocatedRegistryIdentitiesDoNotAccumulate() async {
        let rebuilt = expectation(description: "unidentified controllers stay snapshot-only")
        let reader = ControlledPortReader(ports: [fallbackPort(1, location: nil)])
        var count = 0
        var largestRoster = 0
        var monitor: PortMonitor?
        monitor = PortMonitor(reader: { reader.read() }, interval: 60, observesSystemEvents: false) { ports in
            largestRoster = max(largestRoster, ports.count)
            count += 1
            if count < 20 {
                // An unrecognized location is not a stable physical identity either.
                reader.setPorts([self.fallbackPort(UInt64(count + 1), location: count.isMultiple(of: 2) ? nil : "internal")])
                monitor?.requestRefresh()
            } else { rebuilt.fulfill() }
        }
        monitor?.start()
        await fulfillment(of: [rebuilt], timeout: 1)
        XCTAssertEqual(largestRoster, 1)
        monitor?.stop()
        monitor = nil
    }

    @MainActor
    func testConcurrentSameSidePortsRetainTheirMissingSibling() async {
        let initial = expectation(description: "two concurrently observed left-side ports")
        let missing = expectation(description: "one left-side port is temporarily missing")
        let first = fallbackPort(100, location: "left")
        let second = fallbackPort(200, location: "left")
        let reader = ControlledPortReader(ports: [first, second])
        var last: [PortStatus] = []
        var awaitingMissing = false
        let monitor = PortMonitor(reader: { reader.read() }, interval: 60, observesSystemEvents: false) { ports in
            last = ports
            if awaitingMissing { missing.fulfill() } else { initial.fulfill() }
        }
        monitor.start()
        await fulfillment(of: [initial], timeout: 1)
        awaitingMissing = true
        reader.setPorts([second])
        monitor.requestRefresh()
        await fulfillment(of: [missing], timeout: 1)
        XCTAssertEqual(last.count, 2)
        XCTAssertEqual(last.first(where: { $0.id == first.id })?.connection, .unknown)
        XCTAssertEqual(last.first(where: { $0.id == second.id })?.connection, .connected)
        monitor.stop()
    }

    @MainActor
    func testSameSideRebuildsStayWithinObservedConcurrentCapacity() async {
        let rebuilt = expectation(description: "repeated rebuilding with two known left-side ports")
        let reader = ControlledPortReader(ports: [fallbackPort(100, location: "left"), fallbackPort(200, location: "left")])
        var count = 0
        var rosterSizes: [Int] = []
        var last: [PortStatus] = []
        var monitor: PortMonitor?
        monitor = PortMonitor(reader: { reader.read() }, interval: 60, observesSystemEvents: false) { ports in
            last = ports
            rosterSizes.append(ports.count)
            count += 1
            if count < 20 {
                reader.setPorts([self.fallbackPort(UInt64((count + 1) * 100), location: "left")])
                monitor?.requestRefresh()
            } else { rebuilt.fulfill() }
        }
        monitor?.start()
        await fulfillment(of: [rebuilt], timeout: 1)
        XCTAssertEqual(rosterSizes, Array(repeating: 2, count: 20))
        XCTAssertEqual(last.map(\.id), ["usbC:registry-100", "usbC:registry-2000"])
        XCTAssertEqual(last.first(where: { $0.id == "usbC:registry-100" })?.connection, .unknown)
        monitor?.stop()
        monitor = nil
    }

    private func fallbackPort(_ registryID: UInt64, location: String?) -> PortStatus {
        PortReader.decode(properties: ["BuiltIn": true, "PortTypeDescription": "USB-C", "ConnectionActive": true],
                          registryID: registryID, location: location, ccActive: true)!
    }
}

private final class ControlledPowerReader: @unchecked Sendable {
    private let lock = NSLock()
    private var value = PowerTelemetry.unavailable
    private var onMain = false
    var readOnMainThread: Bool { lock.withLock { onMain } }
    func set(_ value: PowerTelemetry) { lock.withLock { self.value = value } }
    func read() -> PowerTelemetry {
        lock.withLock { onMain = onMain || Thread.isMainThread; return value }
    }
}

private final class ControlledPortReader: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var ports: [PortStatus]
    private let blockFirstRead: Bool
    private var count = 0
    private var concurrent = 0
    private var maximum = 0
    var onRead: (@Sendable (Int) -> Void)?

    init(ports: [PortStatus], blockFirstRead: Bool = false) {
        self.ports = ports
        self.blockFirstRead = blockFirstRead
    }

    var readCount: Int { lock.withLock { count } }
    var maximumConcurrentReads: Int { lock.withLock { maximum } }

    func setPorts(_ ports: [PortStatus]) { lock.withLock { self.ports = ports } }
    func unblock() { gate.signal() }

    func read() -> [PortStatus] {
        let (number, snapshot) = lock.withLock {
            count += 1
            concurrent += 1
            maximum = max(maximum, concurrent)
            return (count, ports)
        }
        onRead?(number)
        if blockFirstRead && number == 1 { _ = gate.wait(timeout: .now() + 2) }
        lock.withLock { concurrent -= 1 }
        return snapshot
    }
}
#endif
