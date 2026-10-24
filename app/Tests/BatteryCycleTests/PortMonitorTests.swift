import Foundation
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
        print("PortMonitor: 6 checks, \(monitorFailures) failures")
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
