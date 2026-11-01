import Foundation
#if canImport(XCTest) && !DISPLAY_RESTORATION_STANDALONE
import XCTest
@testable import BatteryCycle
#else
private var restorationFailures = 0
private var restorationFailureDetails: [String] = []
private func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") {
    if actual != expected {
        restorationFailures += 1
        restorationFailureDetails.append("\(message) (\(actual) != \(expected))")
    }
}
class XCTestCase {}
@main struct DisplayRestorationTestRunner {
    static func main() {
        let tests = DisplayRestorationTests()
        let checks: [(String, () throws -> Void)] = [
            ("connected, hidden CG identity", tests.testConnectedDisplayRestoresAfterDisappearingFromCG),
            ("confirmed unplug and replug", tests.testPhysicallyDisconnectedDisplayWaitsWithoutUsingStaleID),
            ("unknown presence", tests.testMissingIdentityWithUnknownPresenceReportsPending),
            ("rejected restore", tests.testRejectedConnectedRestoreReportsFailureAndPreservesJournal),
            ("acknowledgement without output", tests.testAcceptedRestoreWaitsForConfirmedOutputBeforeForgetting),
            ("asleep is not confirmation", tests.testAsleepOnlyDisplayIsActivelyRestored),
            ("termination recovery", tests.testRestoreReleasedRecoversConnectedMissingIdentity),
            ("termination keeps restriction", tests.testRestoreReleasedKeepsActiveRestriction),
            ("off intent survives failure", tests.testPendingRestorationKeepsOffIntent),
            ("known ID reuse is rejected", tests.testReusedCGDisplayIDCannotBeRestoredAsOriginalDevice)
        ]
        for (name, check) in checks {
            let before = restorationFailures
            restorationFailureDetails = []
            do { try check() }
            catch { restorationFailures += 1; restorationFailureDetails.append("\(error)") }
            if restorationFailures > before {
                print("FAIL: \(name): \(restorationFailureDetails.first ?? "assertion failed")")
            }
        }
        print("Display restoration: \(checks.count) checks, \(restorationFailures) failures")
        if restorationFailures > 0 { exit(1) }
    }
}
#endif

/// These fixtures deliberately separate the CG/UUID view from physical connection
/// state. A display disappearing immediately after our own disable is not unplugging.
final class DisplayRestorationTests: XCTestCase {
    func testConnectedDisplayRestoresAfterDisappearingFromCG() throws {
        let backend = RestorationBackend()
        let store = RestorationStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        try session.setRestricted(.hdmi, true)
        XCTAssertEqual(backend.hasVisibleHDMI, false)
        XCTAssertEqual(backend.presence, .connected)
        try session.setRestricted(.hdmi, false)
        XCTAssertEqual(backend.enableAttempts.count, 1, "still-connected owned output must be restored")
        XCTAssertEqual(backend.confirmedHDMI, true)
        XCTAssertEqual(store.saved?.disabled.isEmpty, true)
        XCTAssertEqual(backend.forgotten, [RestorationBackend.hdmiUUID])
    }

    func testPhysicallyDisconnectedDisplayWaitsWithoutUsingStaleID() throws {
        let backend = RestorationBackend()
        let store = RestorationStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        try session.setRestricted(.hdmi, true)
        backend.presence = .disconnected
        try session.setRestricted(.hdmi, false)
        XCTAssertEqual(backend.enableAttempts.isEmpty, true)
        XCTAssertEqual(store.saved?.disabled.map(\.uuid), [RestorationBackend.hdmiUUID])
        backend.presence = .connected
        backend.publishHDMI(id: 99, enabled: false, confirmed: false)
        try session.reconcile()
        XCTAssertEqual(backend.enableAttempts.map(\.id), [99], "replug must use the fresh identified display ID")
        XCTAssertEqual(backend.confirmedHDMI, true)
        XCTAssertEqual(store.saved?.disabled.isEmpty, true)
        XCTAssertEqual(backend.forgotten, [RestorationBackend.hdmiUUID])
    }

    func testMissingIdentityWithUnknownPresenceReportsPending() throws {
        let backend = RestorationBackend()
        let store = RestorationStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        try session.setRestricted(.hdmi, true)
        backend.presence = .unknown
        let error = restorationError { try session.setRestricted(.hdmi, false) }
        XCTAssertEqual(error != nil, true, "missing CG identity is not evidence of unplugging")
        XCTAssertEqual(store.saved?.disabled.map(\.uuid), [RestorationBackend.hdmiUUID])
        XCTAssertEqual(backend.forgotten.isEmpty, true)
        XCTAssertEqual(backend.confirmedHDMI, false)
    }

    func testRejectedConnectedRestoreReportsFailureAndPreservesJournal() throws {
        let backend = RestorationBackend()
        let store = RestorationStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        try session.setRestricted(.hdmi, true)
        backend.result = .reject
        let error = restorationError { try session.setRestricted(.hdmi, false) }
        XCTAssertEqual(error != nil, true)
        XCTAssertEqual(backend.enableAttempts.count, 1)
        XCTAssertEqual(store.saved?.disabled.map(\.uuid), [RestorationBackend.hdmiUUID])
        XCTAssertEqual(backend.forgotten.isEmpty, true)
    }

    func testAcceptedRestoreWaitsForConfirmedOutputBeforeForgetting() throws {
        let backend = RestorationBackend()
        let store = RestorationStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        try session.setRestricted(.hdmi, true)
        backend.result = .acknowledgeWithoutOutput
        let error = restorationError { try session.setRestricted(.hdmi, false) }
        XCTAssertEqual(error != nil, true, "configuration acknowledgement is not recovered output")
        XCTAssertEqual(backend.enableAttempts.count, 1)
        XCTAssertEqual(store.saved?.disabled.map(\.uuid), [RestorationBackend.hdmiUUID])
        XCTAssertEqual(backend.forgotten.isEmpty, true)
        backend.publishHDMI(id: 10, enabled: true, confirmed: true)
        try session.reconcile()
        XCTAssertEqual(backend.enableAttempts.count, 1, "already-confirmed output must not be configured again")
        XCTAssertEqual(store.saved?.disabled.isEmpty, true)
        XCTAssertEqual(backend.forgotten, [RestorationBackend.hdmiUUID])
    }

    func testAsleepOnlyDisplayIsActivelyRestored() throws {
        let backend = RestorationBackend()
        backend.hideOnDisable = false
        let store = RestorationStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        try session.setRestricted(.hdmi, true)
        XCTAssertEqual(backend.hasVisibleHDMI, true)
        XCTAssertEqual(backend.confirmedHDMI, false)
        try session.setRestricted(.hdmi, false)
        XCTAssertEqual(backend.enableAttempts.count, 1, "asleep-only presence cannot skip the enable operation")
        XCTAssertEqual(backend.confirmedHDMI, true)
        XCTAssertEqual(store.saved?.disabled.isEmpty, true)
        XCTAssertEqual(backend.forgotten, [RestorationBackend.hdmiUUID])
    }

    func testRestoreReleasedRecoversConnectedMissingIdentity() throws {
        let backend = RestorationBackend()
        let store = RestorationStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        try session.setRestricted(.hdmi, true)
        backend.result = .reject
        XCTAssertEqual(restorationError { try session.setRestricted(.hdmi, false) } != nil, true)
        backend.result = .returnConfirmedOutput
        try session.restoreReleased()
        XCTAssertEqual(backend.enableAttempts.count, 2)
        XCTAssertEqual(backend.confirmedHDMI, true)
        XCTAssertEqual(store.saved?.disabled.isEmpty, true)
        XCTAssertEqual(backend.forgotten, [RestorationBackend.hdmiUUID])
    }

    func testRestoreReleasedKeepsActiveRestriction() throws {
        let backend = RestorationBackend()
        let store = RestorationStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        try session.setRestricted(.hdmi, true)
        try session.restoreReleased()
        XCTAssertEqual(backend.enableAttempts.isEmpty, true, "quitting must not lift an active restriction")
        XCTAssertEqual(store.saved?.disabled.map(\.uuid), [RestorationBackend.hdmiUUID])
        XCTAssertEqual(session.settings.hdmi, true, "normal exit preserves the next-launch preference")
    }

    func testPendingRestorationKeepsOffIntent() throws {
        let backend = RestorationBackend()
        let store = RestorationStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        try session.setRestricted(.hdmi, true)
        backend.result = .reject
        XCTAssertEqual(restorationError { try session.setRestricted(.hdmi, false) } != nil, true)
        XCTAssertEqual(session.settings.hdmi, false)
        XCTAssertEqual(store.saved?.settings.hdmi, false)
        XCTAssertEqual(session.hasRecovery, true)
        XCTAssertEqual(backend.forgotten.isEmpty, true)
    }

    func testReusedCGDisplayIDCannotBeRestoredAsOriginalDevice() throws {
        let backend = RestorationBackend()
        let store = RestorationStore()
        let session = DisplayRestrictionSession(backend: backend, store: store)
        try session.start()
        try session.setRestricted(.hdmi, true)
        backend.publishDifferentDisplayUsingOldID()
        let error = restorationError { try session.setRestricted(.hdmi, false) }
        XCTAssertEqual(error != nil, true, "a known different UUID at the old ID must not be enabled")
        XCTAssertEqual(backend.differentDisplayStillVisible, true)
        XCTAssertEqual(store.saved?.disabled.map(\.uuid), [RestorationBackend.hdmiUUID])
        XCTAssertEqual(backend.forgotten.isEmpty, true)
    }
}

private func restorationError(_ action: () throws -> Void) -> Error? {
    do { try action(); return nil } catch { return error }
}

private enum RestorationBackendError: Error {
    case notOwned, notConnected, rejected
}

private final class RestorationBackend: DisplayOutputBackend {
    static let hdmiUUID = "11111111-2222-3333-4444-555555555555"
    static let builtinUUID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    static let scope = "restoration-test-boot"
    enum Result { case returnConfirmedOutput, acknowledgeWithoutOutput, reject }

    var presence = DisplayRecoveryPresence.connected
    var result = Result.returnConfirmedOutput
    var hideOnDisable = true
    var enableAttempts: [DisplayOutputSnapshot] = []
    var forgotten: [String] = []
    private var owned: [String: DisplayOutputSnapshot] = [:]
    private var visible: [DisplayOutputSnapshot] = [
        .init(id: 1, uuid: builtinUUID, name: "Internal", isBuiltin: true, isEnabled: true,
              port: nil, isConfirmedEnabled: true),
        .init(id: 10, uuid: hdmiUUID, name: "HDMI", isBuiltin: false, isEnabled: true,
              port: .hdmi, model: .init(vendor: 1, product: 2), recoveryScope: scope,
              isConfirmedEnabled: true)
    ]

    var hasVisibleHDMI: Bool { visible.contains { $0.uuid == Self.hdmiUUID } }
    var confirmedHDMI: Bool { visible.first { $0.uuid == Self.hdmiUUID }?.isConfirmedEnabled == true }
    var differentDisplayStillVisible: Bool { visible.contains { $0.id == 10 && $0.uuid == "99999999-2222-3333-4444-555555555555" && $0.isConfirmedEnabled == true } }

    func snapshot() throws -> [DisplayOutputSnapshot] { visible }
    func recoveryPresence(for display: DisplayOutputSnapshot) throws -> DisplayRecoveryPresence { presence }
    func remember(_ displays: [DisplayOutputSnapshot]) {
        for display in displays { owned[display.uuid] = display }
    }
    func forgetRecovery(uuid: String) {
        forgotten.append(uuid)
        owned.removeValue(forKey: uuid)
    }

    func setEnabled(_ enabled: Bool, for display: DisplayOutputSnapshot) throws {
        if !enabled {
            guard let current = visible.first(where: { $0.id == display.id && $0.uuid == display.uuid }) else {
                throw RestorationBackendError.notOwned
            }
            owned[display.uuid] = current
            visible.removeAll { $0.uuid == display.uuid }
            if !hideOnDisable {
                // Some driver snapshots still report asleep=true after logical disable.
                publishHDMI(id: current.id, enabled: true, confirmed: false)
            }
            return
        }
        enableAttempts.append(display)
        guard presence == .connected else { throw RestorationBackendError.notConnected }
        guard let previous = owned[display.uuid], previous.uuid == display.uuid,
              display.recoveryScope == Self.scope else { throw RestorationBackendError.notOwned }
        guard !visible.contains(where: { $0.id == display.id && $0.uuid != display.uuid }) else {
            throw RestorationBackendError.notOwned
        }
        if let live = visible.first(where: { $0.uuid == display.uuid }) {
            guard live.id == display.id else { throw RestorationBackendError.notOwned }
        } else {
            guard previous.id == display.id else { throw RestorationBackendError.notOwned }
        }
        switch result {
        case .reject: throw RestorationBackendError.rejected
        case .acknowledgeWithoutOutput: return
        case .returnConfirmedOutput: publishHDMI(id: display.id, enabled: true, confirmed: true)
        }
    }

    func publishHDMI(id: UInt32, enabled: Bool, confirmed: Bool) {
        visible.removeAll { $0.uuid == Self.hdmiUUID }
        visible.append(.init(id: id, uuid: Self.hdmiUUID, name: "HDMI", isBuiltin: false,
            isEnabled: enabled, port: .hdmi, model: .init(vendor: 1, product: 2),
            recoveryScope: Self.scope, isConfirmedEnabled: confirmed))
    }

    func publishDifferentDisplayUsingOldID() {
        visible.append(.init(id: 10, uuid: "99999999-2222-3333-4444-555555555555", name: "Other USB-C",
            isBuiltin: false, isEnabled: true, port: .usbC, model: .init(vendor: 3, product: 4),
            recoveryScope: Self.scope, isConfirmedEnabled: true))
    }
}

private final class RestorationStore: DisplayRestrictionStoring {
    var saved: DisplayRestrictionState?
    func load() throws -> DisplayRestrictionState? { saved }
    func save(_ state: DisplayRestrictionState) throws { saved = state }
}
