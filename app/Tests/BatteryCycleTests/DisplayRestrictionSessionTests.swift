import Foundation
#if canImport(XCTest) && !DISPLAY_RESTRICTIONS_STANDALONE
import XCTest
@testable import BatteryCycle
#else
private var failures = 0
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) {
    if lhs != rhs { failures += 1; print("FAIL: \(lhs) != \(rhs)") }
}
class XCTestCase {}
@main struct DisplayRestrictionTestRunner {
    static func main() {
        let tests = DisplayRestrictionSessionTests()
        let checks: [() throws -> Void] = [
            tests.testIndependentPoliciesAndRestoration,
            tests.testRepluggedDisplayUsesFreshIdentityAndKeepsPolicy,
            tests.testUnknownTransportIsNeverDisabled,
            tests.testLastUsableScreenIsNotDisabled,
            tests.testPreviouslyDisabledDisplayIsNeverOwnedOrRestored,
            tests.testJournalFailurePreventsHardwareChange,
            tests.testRestoreFailureRetainsRecoveryRecord,
            tests.testRestartRecoversDisabledDisplayWhenPolicyIsOff,
            tests.testTerminationRestoresOwnedDisplaysWithoutForgettingPolicy,
            tests.testMovedDisplayIsRestoredUnderUnrestrictedPort,
            tests.testAcceptedConfigurationStillRequiresObservedChange,
            tests.testUnavailableSnapshotNeverChangesHardware,
            tests.testMinimumBrightnessScreenDoesNotCountAsVisible,
            tests.testUnknownTransportDoesNotHideKnownTargetErrors,
            tests.testMovedUnknownInterfaceIsNotRestoredWhileAnyPolicyRemains,
            tests.testSurvivorIsCheckedAgainBeforeEachDisable,
            tests.testUnreadablePolicyDoesNotPermitLegacyEnable,
            tests.testUncertainSaveIsReloadedBeforeChangingOtherSwitch,
            tests.testTargetIsRevalidatedImmediatelyBeforeDisable,
            tests.testMinimumBrightnessRequiresAnUnrestrictedExternalWhenPoliciesAreActive,
            tests.testUnpluggedOwnedDisplayWaitsForFreshIdentityWithoutRestoringStaleID,
            tests.testLegacyInactiveUSBDisplayCanBeRecognizedWithoutBypassingRestriction,
            tests.testLegacyModelCountsIncludeOnlyOwnedAndConfirmedDisabledDisplays
        ]
        for check in checks { do { try check() } catch { failures += 1; print("FAIL: \(error)") } }
        print("Display restrictions: \(checks.count) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
#endif

final class DisplayRestrictionSessionTests: XCTestCase {
    func testIndependentPoliciesAndRestoration() throws {
        let backend = RestrictionTestBackend()
        let store = RestrictionTestStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        try session.setRestricted(.hdmi, true)
        XCTAssertEqual(backend.enabled("hdmi"), false)
        XCTAssertEqual(backend.enabled("usb"), true)
        try session.setRestricted(.usbC, true)
        try session.setRestricted(.hdmi, false)
        XCTAssertEqual(session.settings.hdmi, false)
        XCTAssertEqual(session.settings.usbC, true)
        XCTAssertEqual(backend.enabled("hdmi"), true)
        XCTAssertEqual(backend.enabled("usb"), false)
        XCTAssertEqual(store.saved?.disabled.map(\.uuid), ["usb"])
    }

    func testRepluggedDisplayUsesFreshIdentityAndKeepsPolicy() throws {
        let backend = RestrictionTestBackend()
        let session = DisplayRestrictionSession(backend: backend, store: RestrictionTestStore())
        try session.start()
        try session.setRestricted(.hdmi, true)
        backend.displays.removeAll { $0.uuid == "hdmi" }
        try session.reconcile()
        XCTAssertEqual(session.settings.hdmi, true)
        backend.displays.append(restrictionDisplay(42, "replacement", .hdmi))
        try session.reconcile()
        XCTAssertEqual(backend.enabled("replacement"), false)
        XCTAssertEqual(backend.writes.last?.id, 42)
    }

    func testUnknownTransportIsNeverDisabled() throws {
        let backend = RestrictionTestBackend()
        backend.displays.append(restrictionDisplay(40, "unknown", nil))
        let session = DisplayRestrictionSession(backend: backend, store: RestrictionTestStore())
        try session.start()
        try? session.setRestricted(.hdmi, true)
        try? session.setRestricted(.usbC, true)
        XCTAssertEqual(backend.enabled("unknown"), true)
        XCTAssertEqual(backend.writes.contains { $0.uuid == "unknown" }, false)
    }

    func testLastUsableScreenIsNotDisabled() throws {
        let backend = RestrictionTestBackend()
        backend.displays = [restrictionDisplay(10, "hdmi", .hdmi)]
        let session = DisplayRestrictionSession(backend: backend, store: RestrictionTestStore())
        try session.start()
        let error = restrictionError { try session.setRestricted(.hdmi, true) }
        XCTAssertEqual(error != nil, true)
        XCTAssertEqual(backend.writes.isEmpty, true)
        XCTAssertEqual(session.settings.hdmi, true)
        backend.displays.append(restrictionDisplay(1, "internal", nil, builtin: true))
        try session.reconcile()
        XCTAssertEqual(backend.enabled("hdmi"), false)
    }

    func testPreviouslyDisabledDisplayIsNeverOwnedOrRestored() throws {
        let backend = RestrictionTestBackend()
        backend.displays[1] = restrictionDisplay(10, "hdmi", .hdmi, enabled: false)
        let store = RestrictionTestStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        try session.setRestricted(.hdmi, true)
        try session.setRestricted(.hdmi, false)
        XCTAssertEqual(backend.writes.isEmpty, true)
        XCTAssertEqual(store.saved?.disabled.isEmpty, true)
    }

    func testJournalFailurePreventsHardwareChange() throws {
        let backend = RestrictionTestBackend()
        let store = RestrictionTestStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        store.failSave = true
        XCTAssertEqual(restrictionError { try session.setRestricted(.hdmi, true) } != nil, true)
        XCTAssertEqual(backend.writes.isEmpty, true)
        XCTAssertEqual(session.settings.hdmi, false)
    }

    func testRestoreFailureRetainsRecoveryRecord() throws {
        let backend = RestrictionTestBackend()
        let store = RestrictionTestStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        try session.setRestricted(.hdmi, true)
        backend.failRestore = true
        XCTAssertEqual(restrictionError { try session.setRestricted(.hdmi, false) } != nil, true)
        XCTAssertEqual(store.saved?.disabled.map(\.uuid), ["hdmi"])
        backend.failRestore = false
        try session.reconcile()
        XCTAssertEqual(backend.enabled("hdmi"), true)
        XCTAssertEqual(store.saved?.disabled.isEmpty, true)
    }

    func testRestartRecoversDisabledDisplayWhenPolicyIsOff() throws {
        let backend = RestrictionTestBackend()
        let store = RestrictionTestStore()
        let first = DisplayRestrictionSession(backend: backend, store: store)
        try first.start()
        try first.setRestricted(.hdmi, true)
        store.saved?.settings.hdmi = false
        let second = DisplayRestrictionSession(backend: backend, store: store)
        try second.start()
        XCTAssertEqual(backend.enabled("hdmi"), true)
        XCTAssertEqual(store.saved?.disabled.isEmpty, true)
    }

    func testTerminationRestoresOwnedDisplaysWithoutForgettingPolicy() throws {
        let backend = RestrictionTestBackend()
        let store = RestrictionTestStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        try session.setRestricted(.hdmi, true)
        try session.setRestricted(.usbC, true)
        try session.restoreAll()
        XCTAssertEqual(backend.enabled("hdmi"), true)
        XCTAssertEqual(backend.enabled("usb"), true)
        XCTAssertEqual(store.saved?.settings.hdmi, true)
        XCTAssertEqual(store.saved?.settings.usbC, true)
        XCTAssertEqual(store.saved?.disabled.isEmpty, true)
    }

    func testMovedDisplayIsRestoredUnderUnrestrictedPort() throws {
        let backend = RestrictionTestBackend()
        let session = DisplayRestrictionSession(backend: backend, store: RestrictionTestStore())
        try session.start()
        try session.setRestricted(.hdmi, true)
        backend.displays[1] = restrictionDisplay(99, "hdmi", .usbC, enabled: false)
        try session.reconcile()
        XCTAssertEqual(backend.enabled("hdmi"), true)
        XCTAssertEqual(backend.writes.last?.id, 99)
    }

    func testAcceptedConfigurationStillRequiresObservedChange() throws {
        let backend = RestrictionTestBackend()
        let store = RestrictionTestStore()
        var time: TimeInterval = 10
        let session = DisplayRestrictionSession(backend: backend, store: store, uptime: { time })
        try session.start()
        backend.ignoreWrites = true
        try session.setRestricted(.hdmi, true)
        time += 5
        XCTAssertEqual(restrictionError { try session.reconcile() } != nil, true)
        XCTAssertEqual(store.saved?.disabled.map(\.uuid), ["hdmi"])
    }

    func testUnavailableSnapshotNeverChangesHardware() throws {
        let backend = RestrictionTestBackend()
        let session = DisplayRestrictionSession(backend: backend, store: RestrictionTestStore())
        try session.start()
        backend.failSnapshot = true
        XCTAssertEqual(restrictionError { try session.setRestricted(.hdmi, true) } != nil, true)
        XCTAssertEqual(backend.writes.isEmpty, true)
    }

    func testMinimumBrightnessScreenDoesNotCountAsVisible() throws {
        let backend = RestrictionTestBackend()
        backend.displays.removeAll { $0.uuid == "usb" }
        let session = DisplayRestrictionSession(backend: backend, store: RestrictionTestStore(),
                                               isUsable: { !$0.isBuiltin })
        try session.start()
        XCTAssertEqual(restrictionError { try session.setRestricted(.hdmi, true) } != nil, true)
        XCTAssertEqual(backend.writes.isEmpty, true)
    }

    func testUnknownTransportDoesNotHideKnownTargetErrors() throws {
        let backend = RestrictionTestBackend()
        backend.displays.append(restrictionDisplay(40, "unknown", nil))
        let session = DisplayRestrictionSession(backend: backend, store: RestrictionTestStore())
        try session.start()
        let error = restrictionError { try session.setRestricted(.usbC, true) }
        XCTAssertEqual(backend.enabled("usb"), false)
        XCTAssertEqual(error != nil, true)
    }

    func testMovedUnknownInterfaceIsNotRestoredWhileAnyPolicyRemains() throws {
        let backend = RestrictionTestBackend()
        let session = DisplayRestrictionSession(backend: backend, store: RestrictionTestStore())
        try session.start()
        try session.setRestricted(.hdmi, true)
        try session.setRestricted(.usbC, true)
        backend.displays[1] = restrictionDisplay(99, "hdmi", nil, enabled: false)
        try? session.setRestricted(.hdmi, false)
        XCTAssertEqual(backend.enabled("hdmi"), false)
        try session.setRestricted(.usbC, false)
        XCTAssertEqual(backend.enabled("hdmi"), true)
    }

    func testSurvivorIsCheckedAgainBeforeEachDisable() throws {
        let backend = RestrictionTestBackend()
        let store = RestrictionTestStore()
        store.saved = DisplayRestrictionState(settings: .init(hdmi: true, usbC: true))
        backend.afterDisable = { [weak backend] _ in backend?.displays.removeAll { $0.isBuiltin } }
        let session = DisplayRestrictionSession(backend: backend, store: store)
        XCTAssertEqual(restrictionError { try session.start() } != nil, true)
        XCTAssertEqual(backend.enabled("usb"), true)
    }

    func testUnreadablePolicyDoesNotPermitLegacyEnable() throws {
        let backend = RestrictionTestBackend()
        let store = RestrictionTestStore()
        store.failLoad = true
        let session = DisplayRestrictionSession(backend: backend, store: store)
        XCTAssertEqual(restrictionError { try session.start() } != nil, true)
        XCTAssertEqual(session.permitsEnabling(displayID: 10), false)
    }

    func testUncertainSaveIsReloadedBeforeChangingOtherSwitch() throws {
        let backend = RestrictionTestBackend()
        let store = RestrictionTestStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        store.failAfterSave = true
        XCTAssertEqual(restrictionError { try session.setRestricted(.hdmi, true) } != nil, true)
        XCTAssertEqual(session.needsReload, true)
        store.failAfterSave = false
        try session.setRestricted(.usbC, true)
        XCTAssertEqual(session.settings.hdmi, true)
        XCTAssertEqual(session.settings.usbC, true)
        XCTAssertEqual(backend.enabled("hdmi"), false)
        XCTAssertEqual(backend.enabled("usb"), false)
    }

    func testTargetIsRevalidatedImmediatelyBeforeDisable() throws {
        let backend = RestrictionTestBackend()
        let session = DisplayRestrictionSession(backend: backend, store: RestrictionTestStore())
        try session.start()
        // reconcile reads two snapshots before stop() takes its own fresh snapshot.
        let moveAt = backend.snapshotCount + 3
        backend.beforeSnapshot = { [weak backend] count in
            if count == moveAt { backend?.displays[1] = restrictionDisplay(99, "hdmi", .usbC) }
        }
        try session.setRestricted(.hdmi, true)
        XCTAssertEqual(backend.enabled("hdmi"), true)
        XCTAssertEqual(backend.writes.isEmpty, true)
    }

    func testMinimumBrightnessRequiresAnUnrestrictedExternalWhenPoliciesAreActive() throws {
        let backend = RestrictionTestBackend()
        let session = DisplayRestrictionSession(backend: backend, store: RestrictionTestStore())
        try session.start()
        try session.setRestricted(.hdmi, true)
        XCTAssertEqual(session.permitsMinimumBrightness(), true)
        try session.setRestricted(.usbC, true)
        XCTAssertEqual(session.permitsMinimumBrightness(), false)
        try session.setRestricted(.usbC, false)
        XCTAssertEqual(session.permitsMinimumBrightness(), true)
    }

    func testUnpluggedOwnedDisplayWaitsForFreshIdentityWithoutRestoringStaleID() throws {
        let backend = RestrictionTestBackend()
        let store = RestrictionTestStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        try session.setRestricted(.hdmi, true)
        backend.displays.removeAll { $0.uuid == "hdmi" }
        XCTAssertEqual(restrictionError { try session.setRestricted(.hdmi, false) } == nil, true)
        XCTAssertEqual(store.saved?.disabled.map(\.uuid), ["hdmi"])
        backend.displays.append(restrictionDisplay(99, "hdmi", .hdmi, enabled: false))
        try session.reconcile()
        XCTAssertEqual(backend.enabled("hdmi"), true)
        XCTAssertEqual(backend.writes.last?.id, 99)
        XCTAssertEqual(store.saved?.disabled.isEmpty, true)
    }

    func testLegacyInactiveUSBDisplayCanBeRecognizedWithoutBypassingRestriction() throws {
        let backend = RestrictionTestBackend()
        let session = DisplayRestrictionSession(backend: backend, store: RestrictionTestStore())
        try session.start()
        let identity = session.captureIdentity(displayID: 11)
        backend.hidden["usb"] = restrictionDisplay(11, "usb", .usbC, enabled: false)
        backend.displays.removeAll { $0.uuid == "usb" }
        try session.setRestricted(.hdmi, true)
        XCTAssertEqual(session.permitsEnabling(displayID: 11), false)
        XCTAssertEqual(session.permitsEnabling(displayID: 11, identity: identity), true)
        try session.setRestricted(.usbC, true)
        XCTAssertEqual(session.permitsEnabling(displayID: 11, identity: identity), false)
        // Reusing an old numeric ID for another display must not validate the old UUID.
        try session.setRestricted(.usbC, false)
        backend.displays[1] = restrictionDisplay(11, "different-display", .usbC)
        backend.displays.removeAll { $0.uuid == "usb" }
        XCTAssertEqual(session.permitsEnabling(displayID: 11, identity: identity), false)
    }

    func testLegacyModelCountsIncludeOnlyOwnedAndConfirmedDisabledDisplays() throws {
        let model = DisplayOutputModel(vendor: 10, product: 20)
        let backend = RestrictionTestBackend()
        backend.displays[1] = restrictionDisplay(10, "hdmi", .hdmi, model: model)
        backend.displays[2] = restrictionDisplay(11, "usb", .usbC, enabled: false, model: model)
        let session = DisplayRestrictionSession(backend: backend, store: RestrictionTestStore())
        try session.start()
        try session.setRestricted(.hdmi, true)
        XCTAssertEqual(session.ownedModels, [model: 1])
        try session.setRestricted(.hdmi, false)
        XCTAssertEqual(session.ownedModels.isEmpty, true)
        backend.displays[1] = restrictionDisplay(10, "hdmi", .hdmi, model: model)
        backend.ignoreWrites = true
        try session.setRestricted(.hdmi, true)
        // A durable journal entry alone is insufficient if output is still active.
        XCTAssertEqual(session.ownedModels.isEmpty, true)
    }
}

private func restrictionDisplay(_ id: UInt32, _ uuid: String, _ port: DisplayOutputPort?, builtin: Bool = false,
                                enabled: Bool = true, model: DisplayOutputModel? = nil) -> DisplayOutputSnapshot {
    DisplayOutputSnapshot(id: id, uuid: uuid, name: uuid, isBuiltin: builtin, isEnabled: enabled, port: port, model: model)
}
private func restrictionError(_ action: () throws -> Void) -> Error? {
    do { try action(); return nil } catch { return error }
}
private enum RestrictionTestError: Error { case unavailable }
private final class RestrictionTestBackend: DisplayOutputBackend {
    var displays = [restrictionDisplay(1, "internal", nil, builtin: true),
                    restrictionDisplay(10, "hdmi", .hdmi), restrictionDisplay(11, "usb", .usbC)]
    var writes: [(id: UInt32, uuid: String, enabled: Bool)] = []
    var failSnapshot = false
    var failRestore = false
    var ignoreWrites = false
    var afterDisable: ((String) -> Void)?
    var snapshotCount = 0
    var beforeSnapshot: ((Int) -> Void)?
    var hidden: [String: DisplayOutputSnapshot] = [:]
    func remember(_ records: [DisplayOutputSnapshot]) {
        for record in records {
            guard let known = hidden[record.uuid], known.id == record.id else { continue }
            displays.append(known)
            hidden.removeValue(forKey: record.uuid)
        }
    }
    func snapshot() throws -> [DisplayOutputSnapshot] {
        snapshotCount += 1
        beforeSnapshot?(snapshotCount)
        if failSnapshot { throw RestrictionTestError.unavailable }
        return displays
    }
    func setEnabled(_ enabled: Bool, for display: DisplayOutputSnapshot) throws {
        if enabled && failRestore { throw RestrictionTestError.unavailable }
        writes.append((display.id, display.uuid, enabled))
        if ignoreWrites { return }
        guard let index = displays.firstIndex(where: { $0.id == display.id && $0.uuid == display.uuid }) else {
            throw RestrictionTestError.unavailable
        }
        displays[index] = restrictionDisplay(display.id, display.uuid, display.port,
                                              builtin: display.isBuiltin, enabled: enabled, model: display.model)
        if !enabled { afterDisable?(display.uuid) }
    }
    func enabled(_ uuid: String) -> Bool { displays.first { $0.uuid == uuid }?.isEnabled ?? false }
}
private final class RestrictionTestStore: DisplayRestrictionStoring {
    var saved: DisplayRestrictionState?
    var failSave = false
    var failLoad = false
    var failAfterSave = false
    func load() throws -> DisplayRestrictionState? {
        if failLoad { throw RestrictionTestError.unavailable }
        return saved
    }
    func save(_ state: DisplayRestrictionState) throws {
        if failSave { throw RestrictionTestError.unavailable }
        saved = state
        if failAfterSave { throw RestrictionTestError.unavailable }
    }
}
