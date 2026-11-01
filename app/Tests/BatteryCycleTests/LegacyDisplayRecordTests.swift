import Foundation
#if canImport(XCTest) && !LEGACY_DISPLAY_RECORD_STANDALONE
import XCTest
@testable import BatteryCycle
#else
private var failures = 0
private func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T) {
    if left != right { failures += 1; print("FAIL: \(left) != \(right)") }
}
class XCTestCase {}
@main struct LegacyDisplayRecordRunner {
    static func main() {
        let tests = LegacyDisplayRecordTests()
        do {
            try tests.testOldRecordDefaultsNewLifecycleFields()
            try tests.testPreviousFeatureRecordRetainsStableIdentity()
            try tests.testCurrentRecordRoundTripsLifecycleAndIdentity()
            tests.testRestrictedPeerDoesNotMaskLegacyUnplug()
            tests.testReplugAddsLegacySpareAfterExcludingRestrictedPeer()
            tests.testOtherModelsAndUnknownOwnershipAreNotSubtracted()
            tests.testStaleOwnershipCannotMakeNegativeHardwareCounts()
        } catch { failures += 1; print("FAIL: \(error)") }
        print("Legacy display records: 7 checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
#endif

final class LegacyDisplayRecordTests: XCTestCase {
    func testOldRecordDefaultsNewLifecycleFields() throws {
        let data = Data(#"{"name":"Display","model":{"vendor":1,"product":2},"confirmedAttached":true}"#.utf8)
        let record = try JSONDecoder().decode(DisabledDisplay.self, from: data)
        XCTAssertEqual(record.name, "Display")
        XCTAssertEqual(record.confirmedAttached, true)
        XCTAssertEqual(record.unplugged, false)
        XCTAssertEqual(record.absent, false)
        XCTAssertEqual(record.hidden, false)
        XCTAssertEqual(record.boot, "")
        XCTAssertEqual(record.outputIdentity, nil)
    }

    func testPreviousFeatureRecordRetainsStableIdentity() throws {
        let data = Data(#"{"name":"Display","model":{"vendor":1,"product":2},"confirmedAttached":false,"outputIdentity":{"id":99,"uuid":"stable-id","name":"Display","port":"usbC"}}"#.utf8)
        let record = try JSONDecoder().decode(DisabledDisplay.self, from: data)
        XCTAssertEqual(record.outputIdentity?.id, 99)
        XCTAssertEqual(record.outputIdentity?.uuid, "stable-id")
        XCTAssertEqual(record.outputIdentity?.port, .usbC)
        XCTAssertEqual(record.outputIdentity?.model, nil)
        XCTAssertEqual(record.unplugged, false)
        XCTAssertEqual(record.boot, "")
    }

    func testCurrentRecordRoundTripsLifecycleAndIdentity() throws {
        let identity = DisplayRestrictionRecord(.init(id: 99, uuid: "stable-id", name: "Display",
            isBuiltin: false, isEnabled: false, port: .hdmi,
            model: .init(vendor: 1, product: 2)), port: .hdmi)
        var record = DisabledDisplay(name: "Display", model: .init(vendor: 1, product: 2), outputIdentity: identity)
        record.confirmedAttached = true
        record.unplugged = true
        record.absent = true
        record.boot = "test-boot"
        let decoded = try JSONDecoder().decode(DisabledDisplay.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.outputIdentity, identity)
        XCTAssertEqual(decoded.outputIdentity?.model, .init(vendor: 1, product: 2))
        XCTAssertEqual(decoded.confirmedAttached, true)
        XCTAssertEqual(decoded.unplugged, true)
        XCTAssertEqual(decoded.absent, true)
        XCTAssertEqual(decoded.hidden, true)
        XCTAssertEqual(decoded.boot, "test-boot")
    }

    func testRestrictedPeerDoesNotMaskLegacyUnplug() {
        let model = DisplayOutputModel(vendor: 1, product: 2)
        let owned = [model: 1]
        let bothAttached = DisplayOutputModelCounts.excludingRestricted(owned, from: [model: 2])
        XCTAssertEqual(bothAttached[model], 1)
        let legacyUnplugged = DisplayOutputModelCounts.excludingRestricted(owned, from: [model: 1])
        XCTAssertEqual(legacyUnplugged[model], 0)
        XCTAssertEqual(legacyUnplugged[model, default: 0] < 1, true)
    }

    func testReplugAddsLegacySpareAfterExcludingRestrictedPeer() {
        let model = DisplayOutputModel(vendor: 1, product: 2)
        let available = DisplayOutputModelCounts.excludingRestricted([model: 1], from: [model: 2])
        XCTAssertEqual(available[model, default: 0] > 0, true)
        XCTAssertEqual(available[model], 1)
    }

    func testOtherModelsAndUnknownOwnershipAreNotSubtracted() {
        let legacy = DisplayOutputModel(vendor: 1, product: 2)
        let restricted = DisplayOutputModel(vendor: 3, product: 4)
        let unknown = DisplayOutputModel(vendor: 0, product: 0)
        let raw = [legacy: 1, restricted: 2]
        XCTAssertEqual(DisplayOutputModelCounts.excludingRestricted([restricted: 1], from: raw),
                       [legacy: 1, restricted: 1])
        XCTAssertEqual(DisplayOutputModelCounts.excludingRestricted([unknown: 1], from: raw), raw)
        let partiallyUnknown = [legacy: 1, unknown: 1]
        XCTAssertEqual(DisplayOutputModelCounts.excludingRestricted([unknown: 1], from: partiallyUnknown),
                       partiallyUnknown)
        XCTAssertEqual(DisplayOutputModelCounts.excludingRestricted([:], from: raw), raw)
        XCTAssertEqual(DisplayOutputModelCounts.excludingRestricted([legacy: 0, restricted: -1], from: raw), raw)
    }

    func testStaleOwnershipCannotMakeNegativeHardwareCounts() {
        let model = DisplayOutputModel(vendor: 1, product: 2)
        XCTAssertEqual(DisplayOutputModelCounts.excludingRestricted([model: 2], from: [model: 1]), [model: 0])
    }
}
