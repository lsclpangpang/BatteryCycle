import Foundation
#if canImport(XCTest) && !BRIGHTNESS_CONTROLLER_STANDALONE
import XCTest
@testable import BatteryCycle
#else
private var failures = 0
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) {
    if lhs != rhs { failures += 1; print("FAIL: \(lhs) != \(rhs)") }
}
class XCTestCase {}
@main struct BrightnessControllerTestRunner {
    @MainActor static func main() {
        let tests = BrightnessControllerTests()
        tests.testTerminationRestoresSynchronously()
        tests.testSleepSuspendsWritesAndWakeEnforcesOriginalSession()
        tests.testTransientUnavailablePanelDuringWakeDoesNotAbandonLock()
        tests.testStartupRestoresInsteadOfDimmingAgain()
        tests.testFailedStartupRecoveryCanBeRetried()
        tests.testFailedStartupRecoveryOffersShortcutRetry()
        tests.testShortcutConflictStillAllowsBrightnessKeys()
        tests.testBrightnessKeyImmediatelyReleasesLockWithoutRestoringOldBrightness()
        tests.testUnavailableKeyboardMonitorPreventsDimming()
        tests.testLostKeyboardAccessRestoresAndStopsLock()
        tests.testTerminationDuringManualHandoffPreservesKeyAdjustedBrightness()
        tests.testReenableDuringManualHandoffCapturesNewBrightnessForNextRestore()
        tests.testSecondInstanceCannotRecoverOrOverwriteOwnersJournal()
        tests.testBlockedInstanceCanAcquireAfterOwnerTerminates()
        tests.testSecondInstanceRecoversAbandonedJournalOnlyAfterAcquiring()
        tests.testDelayedBrightnessKeyRepairsEnforcementCollision()
        tests.testDownKeyDuringHandoffCancelsCollisionRepair()
        print("BrightnessController: 17 checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
#endif

final class BrightnessControllerTests: XCTestCase {
    @MainActor func testTerminationRestoresSynchronously() {
        let backend = ControllerTestBackend()
        let store = ControllerTestStore()
        let controller = BrightnessController(backend: backend, store: store, observesSystemEvents: false)
        controller.setEnabled(true)
        XCTAssertEqual(controller.isEnabled, true)
        controller.prepareForTermination()
        XCTAssertEqual(controller.isEnabled, false)
        XCTAssertEqual(backend.brightness, 0.7)
        XCTAssertEqual(backend.automatic, true)
        XCTAssertEqual(store.saved, nil)
        controller.setEnabled(true)
        XCTAssertEqual(controller.isEnabled, false)
    }

    @MainActor func testSleepSuspendsWritesAndWakeEnforcesOriginalSession() {
        let backend = ControllerTestBackend()
        let store = ControllerTestStore()
        let controller = BrightnessController(backend: backend, store: store, observesSystemEvents: false)
        defer { controller.prepareForTermination() }
        controller.setEnabled(true)
        controller.setSleeping(system: true, asleep: true)
        controller.setSleeping(system: false, asleep: true)
        backend.brightness = 0.9
        backend.automatic = true
        controller.check()
        XCTAssertEqual(backend.brightness, 0.9)
        controller.setSleeping(system: true, asleep: false)
        controller.check()
        XCTAssertEqual(backend.brightness, 0.9)
        controller.setSleeping(system: false, asleep: false)
        controller.check()
        XCTAssertEqual(backend.brightness, 0)
        XCTAssertEqual(backend.automatic, false)
        XCTAssertEqual(store.saved?.brightness, 0.7)
    }

    @MainActor func testTransientUnavailablePanelDuringWakeDoesNotAbandonLock() {
        let backend = ControllerTestBackend()
        let controller = BrightnessController(backend: backend, store: ControllerTestStore(), observesSystemEvents: false)
        defer { controller.prepareForTermination() }
        controller.setEnabled(true)
        controller.setSleeping(system: true, asleep: true)
        backend.unavailable = true
        controller.setSleeping(system: true, asleep: false)
        controller.check()
        XCTAssertEqual(controller.isEnabled, true)
        backend.unavailable = false
        backend.brightness = 0.5
        controller.check()
        XCTAssertEqual(controller.isEnabled, true)
        XCTAssertEqual(backend.brightness, 0)
    }

    @MainActor func testStartupRestoresInsteadOfDimmingAgain() {
        let backend = ControllerTestBackend()
        let store = ControllerTestStore()
        store.saved = BrightnessRecoveryRecord(displayID: "internal", brightness: 0.8, automaticBrightness: false)
        backend.brightness = 0
        backend.automatic = false
        let controller = BrightnessController(backend: backend, store: store, observesSystemEvents: false)
        defer { controller.prepareForTermination() }
        XCTAssertEqual(controller.isEnabled, false)
        XCTAssertEqual(controller.needsRecovery, false)
        XCTAssertEqual(backend.brightness, 0.8)
        XCTAssertEqual(backend.automatic, false)
    }

    @MainActor func testFailedStartupRecoveryCanBeRetried() {
        let backend = ControllerTestBackend()
        let store = ControllerTestStore()
        store.saved = BrightnessRecoveryRecord(displayID: "internal", brightness: 0.6, automaticBrightness: true)
        backend.unavailable = true
        let controller = BrightnessController(backend: backend, store: store, observesSystemEvents: false)
        defer { controller.prepareForTermination() }
        XCTAssertEqual(controller.needsRecovery, true)
        backend.unavailable = false
        controller.recover()
        XCTAssertEqual(controller.needsRecovery, false)
        XCTAssertEqual(controller.isEnabled, false)
        XCTAssertEqual(backend.brightness, 0.6)
        XCTAssertEqual(backend.automatic, true)
    }

    @MainActor func testFailedStartupRecoveryOffersShortcutRetry() {
        let backend = ControllerTestBackend()
        let store = ControllerTestStore()
        let shortcut = ControllerTestShortcut()
        store.saved = BrightnessRecoveryRecord(displayID: "internal", brightness: 0.6, automaticBrightness: true)
        backend.unavailable = true
        let controller = BrightnessController(backend: backend, store: store,
                                              observesSystemEvents: false, shortcut: shortcut)
        defer { controller.prepareForTermination() }
        XCTAssertEqual(controller.needsRecovery, true)
        XCTAssertEqual(shortcut.running, true)
        backend.unavailable = false
        shortcut.callback?()
        XCTAssertEqual(controller.needsRecovery, false)
        XCTAssertEqual(backend.brightness, 0.6)
        XCTAssertEqual(shortcut.running, false)
    }

    @MainActor func testShortcutConflictStillAllowsBrightnessKeys() {
        let backend = ControllerTestBackend()
        let store = ControllerTestStore()
        let shortcut = ControllerTestShortcut()
        shortcut.canRegister = false
        let controller = BrightnessController(backend: backend, store: store,
                                              observesSystemEvents: false, shortcut: shortcut)
        defer { controller.prepareForTermination() }
        controller.setEnabled(true)
        XCTAssertEqual(controller.isEnabled, true)
        XCTAssertEqual(backend.brightness, 0)
    }

    @MainActor func testBrightnessKeyImmediatelyReleasesLockWithoutRestoringOldBrightness() {
        let backend = ControllerTestBackend()
        let keys = ControllerTestKeyMonitor()
        let controller = BrightnessController(backend: backend, store: ControllerTestStore(),
                                              observesSystemEvents: false, keyboard: keys)
        defer { controller.prepareForTermination() }
        controller.setEnabled(true)
        keys.onKey?(.init(direction: .increase, timestamp: 0))
        XCTAssertEqual(controller.isEnabled, false)
        XCTAssertEqual(backend.brightness, 0)
        backend.brightness = 0.0625 // The OS processes the original key normally.
        controller.check()
        XCTAssertEqual(backend.brightness, 0.0625)
        controller.finishManualAdjustment()
        XCTAssertEqual(backend.brightness, 0.0625)
        XCTAssertEqual(backend.automatic, true)
        XCTAssertEqual(keys.running, false)
        XCTAssertEqual(controller.needsRecovery, false)
    }

    @MainActor func testUnavailableKeyboardMonitorPreventsDimming() {
        let backend = ControllerTestBackend()
        let keys = ControllerTestKeyMonitor()
        keys.requiresPermission = true
        let controller = BrightnessController(backend: backend, store: ControllerTestStore(),
                                              observesSystemEvents: false, keyboard: keys)
        defer { controller.prepareForTermination() }
        controller.setEnabled(true)
        XCTAssertEqual(controller.isEnabled, false)
        XCTAssertEqual(backend.brightness, 0.7)
        XCTAssertEqual(backend.automatic, true)
        XCTAssertEqual(controller.needsKeyboardPermission, true)
    }

    @MainActor func testLostKeyboardAccessRestoresAndStopsLock() {
        let backend = ControllerTestBackend()
        let keys = ControllerTestKeyMonitor()
        let controller = BrightnessController(backend: backend, store: ControllerTestStore(),
                                              observesSystemEvents: false, keyboard: keys)
        defer { controller.prepareForTermination() }
        controller.setEnabled(true)
        keys.onUnavailable?()
        XCTAssertEqual(controller.isEnabled, false)
        XCTAssertEqual(backend.brightness, 0.7)
        XCTAssertEqual(backend.automatic, true)
    }

    @MainActor func testTerminationDuringManualHandoffPreservesKeyAdjustedBrightness() {
        let backend = ControllerTestBackend()
        let store = ControllerTestStore()
        let keys = ControllerTestKeyMonitor()
        let controller = BrightnessController(backend: backend, store: store,
                                              observesSystemEvents: false, keyboard: keys)
        controller.setEnabled(true)
        keys.onKey?(.init(direction: .increase, timestamp: 0))
        XCTAssertEqual(store.saved?.restoresBrightness, false)
        backend.brightness = 0.0625
        XCTAssertEqual(backend.automatic, false)

        // This synchronous main-actor test never yields to the queued 250 ms completion.
        controller.prepareForTermination()
        XCTAssertEqual(controller.isEnabled, false)
        XCTAssertEqual(controller.needsRecovery, false)
        XCTAssertEqual(backend.brightness, 0.0625)
        XCTAssertEqual(backend.brightnessWrites, [0])
        XCTAssertEqual(backend.automatic, true)
        XCTAssertEqual(store.saved, nil)
        XCTAssertEqual(keys.running, false)
        // A completion delivered after termination must also leave the key's value alone.
        controller.finishManualAdjustment()
        XCTAssertEqual(backend.brightnessWrites, [0])
    }

    @MainActor func testReenableDuringManualHandoffCapturesNewBrightnessForNextRestore() {
        let backend = ControllerTestBackend()
        let store = ControllerTestStore()
        let keys = ControllerTestKeyMonitor()
        let controller = BrightnessController(backend: backend, store: store,
                                              observesSystemEvents: false, keyboard: keys)
        defer { controller.prepareForTermination() }
        controller.setEnabled(true)
        keys.onKey?(.init(direction: .increase, timestamp: 0))
        backend.brightness = 0.25
        XCTAssertEqual(store.saved?.brightness, 0.7)
        XCTAssertEqual(store.saved?.restoresBrightness, false)

        // Re-enable before the delayed completion gets a chance to run.
        controller.setEnabled(true)
        XCTAssertEqual(controller.isEnabled, true)
        XCTAssertEqual(backend.brightness, 0)
        XCTAssertEqual(store.saved?.brightness, 0.25)
        XCTAssertEqual(store.saved?.automaticBrightness, true)
        XCTAssertEqual(store.saved?.restoresBrightness, true)
        XCTAssertEqual(backend.brightnessWrites, [0, 0])
        controller.finishManualAdjustment()
        XCTAssertEqual(controller.isEnabled, true)

        controller.setEnabled(false)
        XCTAssertEqual(controller.needsRecovery, false)
        XCTAssertEqual(backend.brightness, 0.25)
        XCTAssertEqual(backend.automatic, true)
        XCTAssertEqual(backend.brightnessWrites, [0, 0, 0.25])
        XCTAssertEqual(store.saved, nil)
    }
    @MainActor func testSecondInstanceCannotRecoverOrOverwriteOwnersJournal() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = ControllerTestBackend()
        let store = FileBrightnessRecoveryStore(url: folder.appendingPathComponent("recovery.json"))
        let lock = folder.appendingPathComponent("control.lock")
        let a = BrightnessController(backend: backend, store: store, observesSystemEvents: false,
                                     lease: FileBrightnessControlLease(url: lock))
        defer { a.prepareForTermination() }
        a.setEnabled(true)
        let writes = backend.brightnessWrites
        let b = BrightnessController(backend: backend, store: store, observesSystemEvents: false,
                                     lease: FileBrightnessControlLease(url: lock))
        XCTAssertEqual(b.message?.contains("另一个"), true)
        b.setEnabled(true)
        XCTAssertEqual(b.isEnabled, false)
        XCTAssertEqual(backend.brightnessWrites, writes)
        XCTAssertEqual((try? store.load())?.brightness, 0.7)
        b.prepareForTermination()
        XCTAssertEqual(backend.brightnessWrites, writes)
        a.setEnabled(false)
        XCTAssertEqual(backend.brightness, 0.7)
        XCTAssertEqual(backend.automatic, true)
    }

    @MainActor func testBlockedInstanceCanAcquireAfterOwnerTerminates() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = ControllerTestBackend()
        let store = FileBrightnessRecoveryStore(url: folder.appendingPathComponent("recovery.json"))
        let lock = folder.appendingPathComponent("control.lock")
        let a = BrightnessController(backend: backend, store: store, observesSystemEvents: false,
                                     lease: FileBrightnessControlLease(url: lock))
        let b = BrightnessController(backend: backend, store: store, observesSystemEvents: false,
                                     lease: FileBrightnessControlLease(url: lock))
        defer { b.prepareForTermination() }
        a.setEnabled(true)
        b.setEnabled(true)
        XCTAssertEqual(b.isEnabled, false)
        a.prepareForTermination()
        b.setEnabled(true)
        XCTAssertEqual(b.isEnabled, true)
        XCTAssertEqual((try? store.load())?.brightness, 0.7)
        b.setEnabled(false)
        XCTAssertEqual(backend.brightness, 0.7)
    }

    @MainActor func testSecondInstanceRecoversAbandonedJournalOnlyAfterAcquiring() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = ControllerTestBackend()
        let store = FileBrightnessRecoveryStore(url: folder.appendingPathComponent("recovery.json"))
        let lock = folder.appendingPathComponent("control.lock")
        var a: BrightnessController? = BrightnessController(backend: backend, store: store, observesSystemEvents: false,
                                                           lease: FileBrightnessControlLease(url: lock))
        a?.setEnabled(true)
        let b = BrightnessController(backend: backend, store: store, observesSystemEvents: false,
                                     lease: FileBrightnessControlLease(url: lock))
        defer { b.prepareForTermination() }
        XCTAssertEqual(backend.brightness, 0)
        a = nil // Drop ownership without a normal restore, like an abandoned process.
        b.recover()
        XCTAssertEqual(backend.brightness, 0.7)
        XCTAssertEqual(backend.automatic, true)
        XCTAssertEqual(b.needsRecovery, false)
        XCTAssertEqual(try? store.load(), nil)
    }

    @MainActor func testDelayedBrightnessKeyRepairsEnforcementCollision() {
        var time: TimeInterval = 10
        let backend = ControllerTestBackend()
        let keys = ControllerTestKeyMonitor()
        let controller = BrightnessController(backend: backend, store: ControllerTestStore(),
                                              observesSystemEvents: false, keyboard: keys, uptime: { time })
        defer { controller.prepareForTermination() }
        controller.setEnabled(true)
        backend.brightness = 0.0625 // The OS handles the physical key before our tap callback.
        time = 11
        controller.check()
        XCTAssertEqual(backend.brightness, 0)
        time = 11.1
        keys.onKey?(.init(direction: .increase, timestamp: 10.99))
        controller.finishManualAdjustment()
        XCTAssertEqual(controller.isEnabled, false)
        XCTAssertEqual(backend.brightness, 0.0625)
        XCTAssertEqual(backend.brightnessWrites, [0, 0, 0.0625])
    }

    @MainActor func testDownKeyDuringHandoffCancelsCollisionRepair() {
        var time: TimeInterval = 10
        let backend = ControllerTestBackend()
        let keys = ControllerTestKeyMonitor()
        let controller = BrightnessController(backend: backend, store: ControllerTestStore(),
                                              observesSystemEvents: false, keyboard: keys, uptime: { time })
        defer { controller.prepareForTermination() }
        controller.setEnabled(true)
        backend.brightness = 0.0625
        time = 11
        controller.check()
        time = 11.1
        keys.onKey?(.init(direction: .increase, timestamp: 10.99))
        keys.onKey?(.init(direction: .decrease, timestamp: 11.1))
        controller.finishManualAdjustment()
        XCTAssertEqual(backend.brightness, 0)
        XCTAssertEqual(backend.brightnessWrites, [0, 0])
    }

}

private final class ControllerTestKeyMonitor: BrightnessKeyMonitoring {
    var requiresPermission = false
    var running = false
    var onKey: ((BrightnessKeyPress) -> Void)?
    var onUnavailable: (() -> Void)?
    func start(onKey: @escaping (BrightnessKeyPress) -> Void, onUnavailable: @escaping () -> Void) -> Bool {
        self.onKey = onKey
        self.onUnavailable = onUnavailable
        running = !requiresPermission
        return running
    }
    func stop() { running = false; onKey = nil; onUnavailable = nil }
    func requestPermission() { }
}

private final class ControllerTestShortcut: BrightnessRestoreShortcutHandling {
    var canRegister = true
    var running = false
    var callback: (() -> Void)?
    func start(_ callback: @escaping () -> Void) -> Bool {
        self.callback = callback
        running = canRegister
        return canRegister
    }
    func stop() { running = false; callback = nil }
}

private final class ControllerTestBackend: BrightnessBackend {
    var brightness: Float = 0.7
    var brightnessWrites: [Float] = []
    var automatic = true
    var unavailable = false
    func snapshot() throws -> BrightnessSnapshot {
        if unavailable { throw NSError(domain: "Unavailable panel", code: 1) }
        return BrightnessSnapshot(displayID: "internal", brightness: brightness, automaticBrightness: automatic)
    }
    func setBrightness(_ value: Float, displayID: String) throws {
        brightnessWrites.append(value)
        brightness = value
    }
    func setAutomaticBrightness(_ enabled: Bool, displayID: String) throws { automatic = enabled }
}

private final class ControllerTestStore: BrightnessRecoveryStore {
    var saved: BrightnessRecoveryRecord?
    func load() throws -> BrightnessRecoveryRecord? { saved }
    func save(_ snapshot: BrightnessRecoveryRecord) throws { saved = snapshot }
    func clear() throws { saved = nil }
}
