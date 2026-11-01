import Foundation
#if canImport(XCTest) && !DISPLAY_RECOVERY_STANDALONE
import XCTest
@testable import BatteryCycle
#else
private var failures = 0
class XCTestCase {}
private func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) {
    if actual != expected { failures += 1; print("FAIL: unexpected recovery resolution") }
}
private func XCTAssertNil<T>(_ actual: T?) {
    if actual != nil { failures += 1; print("FAIL: unsafe recovery accepted") }
}
@main struct DisplayRecoveryResolverRunner {
    static func main() {
        let tests = DisplayRecoveryResolverTests()
        tests.testMissingCGUUIDCanRestoreInProcessOwnedDisplay()
        tests.testMatchingPersistentLoginScopeCanRestore()
        tests.testMissingOrDifferentLoginScopeCannotRestoreHistoricalID()
        tests.testDifferentUUIDOrUnidentifiedOnlineOccupantRejectsHistoricalID()
        tests.testDisableNeverUsesHistoricalID()
        tests.testVerifiedUUIDPathStillWorksWithoutOwnershipFallback()
        tests.testSubmittedOrSleepingDisplayIsNotConfirmedEnabled()
        tests.testDisconnectedRequiresEveryRelevantPortKnownDisconnected()
        print("DisplayRecoveryResolver: 8 checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
#endif

final class DisplayRecoveryResolverTests: XCTestCase {
    private func resolve(enabling: Bool = true, scope: String? = "boot:login-a",
                         current: String? = "boot:login-a", trusted: Bool = false,
                         remembered: Bool = true, verified: UInt32? = nil,
                         online: Set<UInt32> = [], occupied: [UInt32: String] = [:]) -> UInt32? {
        DisplayRecoveryResolver.resolve(enabling: enabling, previousID: 2, expectedUUID: "display-a",
            verifiedUUIDDisplayID: verified, knownUUIDs: occupied, onlineIDs: online,
            trustedInProcess: trusted, rememberedOwned: remembered,
            savedScope: scope, currentScope: current)
    }

    func testMissingCGUUIDCanRestoreInProcessOwnedDisplay() {
        XCTAssertEqual(resolve(scope: nil, current: nil, trusted: true), 2)
    }
    func testMatchingPersistentLoginScopeCanRestore() {
        XCTAssertEqual(resolve(), 2)
        XCTAssertNil(resolve(remembered: false))
    }
    func testMissingOrDifferentLoginScopeCannotRestoreHistoricalID() {
        XCTAssertNil(resolve(scope: nil))
        XCTAssertNil(resolve(current: nil))
        XCTAssertNil(resolve(current: "boot:login-b"))
        XCTAssertNil(resolve(current: "different-boot:login-a"))
    }
    func testDifferentUUIDOrUnidentifiedOnlineOccupantRejectsHistoricalID() {
        XCTAssertNil(resolve(trusted: true, occupied: [2: "another-display"]))
        XCTAssertNil(resolve(trusted: true, online: [2]))
        XCTAssertNil(resolve(trusted: true, online: [2], occupied: [2: "another-display"]))
    }
    func testDisableNeverUsesHistoricalID() {
        XCTAssertNil(resolve(enabling: false, trusted: true))
    }
    func testVerifiedUUIDPathStillWorksWithoutOwnershipFallback() {
        XCTAssertEqual(resolve(enabling: false, scope: nil, current: nil,
            remembered: false, verified: 7, online: [7], occupied: [7: "display-a"]), 7)
        XCTAssertNil(resolve(verified: 7, occupied: [7: "another-display"]))
    }
    func testSubmittedOrSleepingDisplayIsNotConfirmedEnabled() {
        XCTAssertEqual(DisplayRecoveryVerification.isConfirmed(active: false, mirrored: false,
            mirrorPrimaryActive: false, asleep: true), false)
        XCTAssertEqual(DisplayRecoveryVerification.isConfirmed(active: false, mirrored: true,
            mirrorPrimaryActive: false, asleep: true), false)
        XCTAssertEqual(DisplayRecoveryVerification.isConfirmed(active: false, mirrored: true,
            mirrorPrimaryActive: true, asleep: true), false)
        XCTAssertEqual(DisplayRecoveryVerification.isConfirmed(active: false, mirrored: true,
            mirrorPrimaryActive: true, asleep: false), true)
        XCTAssertEqual(DisplayRecoveryVerification.isConfirmed(active: true, mirrored: false,
            mirrorPrimaryActive: false, asleep: false), true)
    }
    func testDisconnectedRequiresEveryRelevantPortKnownDisconnected() {
        XCTAssertEqual(DisplayRecoveryVerification.presence([.disconnected, .disconnected], stable: true), .disconnected)
        XCTAssertEqual(DisplayRecoveryVerification.presence([.disconnected, .unknown], stable: true), .unknown)
        XCTAssertEqual(DisplayRecoveryVerification.presence([], stable: true), .unknown)
        XCTAssertEqual(DisplayRecoveryVerification.presence([.disconnected], stable: false), .unknown)
        XCTAssertEqual(DisplayRecoveryVerification.presence([.connected, .unknown], stable: true), .connected)
    }
}
