import Foundation
#if canImport(XCTest) && !DISPLAY_RESTRICTION_CONTROLLER_STANDALONE
import XCTest
@testable import BatteryCycle
#else
private var failures = 0
private func XCTAssertTrue(_ value: Bool) { if !value { failures += 1; print("FAIL: expected true") } }
private func XCTAssertFalse(_ value: Bool) { if value { failures += 1; print("FAIL: expected false") } }
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) { if lhs != rhs { failures += 1; print("FAIL: \(lhs) != \(rhs)") } }
class XCTestCase {}
@main struct DisplayRestrictionControllerTestRunner {
    @MainActor static func main() {
        let tests = DisplayRestrictionControllerTests()
        tests.testLockedSettingsCannotChangeButExistingPolicyContinues()
        tests.testSleepSuspendsPolicyAndFullyAwakeReappliesIt()
        tests.testTemporaryStartupReadFailureIsRetriedWithoutOverwritingSavedPolicy()
        tests.testSecondCopyCannotChangeJournalUntilLeaseIsAvailable()
        tests.testTerminationKeepsPolicyAndPreventsQueuedPolicyWrites()
        print("Display restriction controller: 5 checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
#endif

final class DisplayRestrictionControllerTests: XCTestCase {
    @MainActor func testLockedSettingsCannotChangeButExistingPolicyContinues() {
        let backend = OutputControllerBackend()
        let store = OutputControllerStore()
        var unlocked = false
        let controller = DisplayOutputRestrictionController(backend: backend, store: store,
            canChangeSettings: { unlocked }, observesSystemEvents: false)
        defer { controller.prepareForTermination() }
        controller.setRestricted(.hdmi, true)
        XCTAssertFalse(controller.settings.hdmi)
        XCTAssertEqual(backend.writeCount, 0)
        unlocked = true
        controller.setRestricted(.hdmi, true)
        XCTAssertTrue(controller.settings.hdmi)
        unlocked = false
        backend.displays[1] = outputControllerDisplay(99, "new-hdmi", .hdmi)
        controller.check()
        XCTAssertFalse(backend.displays[1].isEnabled)
        controller.setRestricted(.hdmi, false)
        XCTAssertTrue(controller.settings.hdmi)
    }

    @MainActor func testSleepSuspendsPolicyAndFullyAwakeReappliesIt() {
        let backend = OutputControllerBackend()
        let controller = DisplayOutputRestrictionController(backend: backend, store: OutputControllerStore(),
            canChangeSettings: { true }, observesSystemEvents: false)
        defer { controller.prepareForTermination() }
        controller.setRestricted(.hdmi, true)
        controller.setSleeping(system: true, asleep: true)
        controller.setSleeping(system: false, asleep: true)
        backend.displays[1] = outputControllerDisplay(10, "hdmi", .hdmi)
        let before = backend.writeCount
        controller.setSleeping(system: true, asleep: false)
        controller.check()
        XCTAssertEqual(backend.writeCount, before)
        controller.setSleeping(system: false, asleep: false)
        controller.check()
        XCTAssertFalse(backend.displays[1].isEnabled)
    }

    @MainActor func testTemporaryStartupReadFailureIsRetriedWithoutOverwritingSavedPolicy() {
        let backend = OutputControllerBackend()
        let store = OutputControllerStore()
        store.state = .init(settings: .init(hdmi: true))
        store.failLoad = true
        let controller = DisplayOutputRestrictionController(backend: backend, store: store,
            canChangeSettings: { false }, observesSystemEvents: false)
        defer { controller.prepareForTermination() }
        XCTAssertEqual(backend.writeCount, 0)
        store.failLoad = false
        controller.check()
        XCTAssertTrue(controller.settings.hdmi)
        XCTAssertFalse(backend.displays[1].isEnabled)
    }

    @MainActor func testSecondCopyCannotChangeJournalUntilLeaseIsAvailable() {
        let backend = OutputControllerBackend()
        let store = OutputControllerStore()
        store.state = .init(settings: .init(usbC: true))
        let lease = OutputControllerLease()
        lease.available = false
        let controller = DisplayOutputRestrictionController(backend: backend, store: store, lease: lease,
            canChangeSettings: { true }, observesSystemEvents: false)
        defer { controller.prepareForTermination() }
        controller.setRestricted(.hdmi, true)
        XCTAssertEqual(backend.writeCount, 0)
        XCTAssertEqual(store.state?.settings.hdmi, false)
        lease.available = true
        controller.setRestricted(.hdmi, true)
        XCTAssertTrue(controller.settings.usbC)
        XCTAssertTrue(controller.settings.hdmi)
    }

    @MainActor func testTerminationKeepsPolicyAndPreventsQueuedPolicyWrites() {
        let backend = OutputControllerBackend()
        let store = OutputControllerStore()
        let lease = OutputControllerLease()
        let controller = DisplayOutputRestrictionController(backend: backend, store: store, lease: lease,
            canChangeSettings: { true }, observesSystemEvents: false)
        controller.setRestricted(.hdmi, true)
        controller.prepareForTermination()
        XCTAssertFalse(backend.displays[1].isEnabled)
        XCTAssertEqual(store.state?.settings.hdmi, true)
        XCTAssertEqual(store.state?.disabled.map(\.uuid), ["hdmi"])
        XCTAssertTrue(lease.released)
        let count = backend.writeCount
        controller.check(force: true)
        controller.setRestricted(.usbC, true)
        XCTAssertEqual(backend.writeCount, count)
    }
}

private enum OutputControllerError: Error { case unavailable }
private func outputControllerDisplay(_ id: UInt32, _ uuid: String, _ port: DisplayOutputPort?,
                                     builtin: Bool = false, enabled: Bool = true) -> DisplayOutputSnapshot {
    .init(id: id, uuid: uuid, name: uuid, isBuiltin: builtin, isEnabled: enabled, port: port)
}
private final class OutputControllerBackend: DisplayOutputBackend {
    var displays = [outputControllerDisplay(1, "internal", nil, builtin: true),
                    outputControllerDisplay(10, "hdmi", .hdmi), outputControllerDisplay(11, "usb", .usbC)]
    var writeCount = 0
    func snapshot() throws -> [DisplayOutputSnapshot] { displays }
    func setEnabled(_ enabled: Bool, for display: DisplayOutputSnapshot) throws {
        guard let index = displays.firstIndex(where: { $0.uuid == display.uuid }) else { throw OutputControllerError.unavailable }
        writeCount += 1
        displays[index] = outputControllerDisplay(display.id, display.uuid, display.port,
                                                  builtin: display.isBuiltin, enabled: enabled)
    }
}
private final class OutputControllerStore: DisplayRestrictionStoring {
    var state: DisplayRestrictionState?
    var failLoad = false
    func load() throws -> DisplayRestrictionState? {
        if failLoad { throw OutputControllerError.unavailable }
        return state
    }
    func save(_ state: DisplayRestrictionState) throws { self.state = state }
}
private final class OutputControllerLease: DisplayRestrictionLeasing {
    var available = true
    var released = false
    func acquire() throws { if !available { throw OutputControllerError.unavailable } }
    func release() { released = true }
}
