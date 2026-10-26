import Foundation
#if canImport(XCTest) && !BRIGHTNESS_STORE_STANDALONE
import XCTest
@testable import BatteryCycle
#else
private var failures = 0
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) {
    if lhs != rhs { failures += 1; print("FAIL: \(lhs) != \(rhs)") }
}
private func XCTFail(_ message: String) { failures += 1; print("FAIL: \(message)") }
class XCTestCase {}
@main struct BrightnessStoreTestRunner {
    static func main() throws {
        let tests = BrightnessRecoveryStoreTests()
        try tests.testRoundTripAndClear()
        try tests.testMalformedRecordIsPreserved()
        try tests.testUnreadableLocationIsNotTreatedAsNoRecord()
        try tests.testLegacySnapshotDefaultsToRestoringBrightness()
        try tests.testManualHandoffPolicySurvivesSerialization()
        try tests.testInvalidHandoffPolicyIsNotTreatedAsLegacyRecord()
        print("BrightnessRecoveryStore: 6 checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
#endif

final class BrightnessRecoveryStoreTests: XCTestCase {
    func testRoundTripAndClear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBrightnessRecoveryStore(url: directory.appendingPathComponent("nested/recovery.json"))
        XCTAssertEqual(try store.load(), nil)
        let original = BrightnessRecoveryRecord(displayID: "internal-screen", brightness: 0.73, automaticBrightness: true)
        try store.save(original)
        XCTAssertEqual(try store.load(), original)
        try store.clear()
        XCTAssertEqual(try store.load(), nil)
        try store.clear()
    }

    func testMalformedRecordIsPreserved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("not valid recovery data".utf8)
        try data.write(to: url)
        do {
            _ = try FileBrightnessRecoveryStore(url: url).load()
            XCTFail("Malformed recovery data must block activation")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testUnreadableLocationIsNotTreatedAsNoRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            _ = try FileBrightnessRecoveryStore(url: directory).load()
            XCTFail("A read failure must not discard recovery state")
        } catch { }
    }

    func testLegacySnapshotDefaultsToRestoringBrightness() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = Data(#"{"displayID":"internal-screen","brightness":0.73,"automaticBrightness":true}"#.utf8)
        try legacy.write(to: url)
        let record = try FileBrightnessRecoveryStore(url: url).load()
        XCTAssertEqual(record?.restoresBrightness, true)
        XCTAssertEqual(record?.brightness, 0.73)
        XCTAssertEqual(record?.automaticBrightness, true)
    }

    func testManualHandoffPolicySurvivesSerialization() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBrightnessRecoveryStore(url: directory.appendingPathComponent("recovery.json"))
        let record = BrightnessRecoveryRecord(
            snapshot: BrightnessSnapshot(displayID: "internal-screen", brightness: 0.73, automaticBrightness: true),
            restoresBrightness: false
        )
        try store.save(record)
        XCTAssertEqual(try store.load(), record)
        XCTAssertEqual(try store.load()?.restoresBrightness, false)
    }

    func testInvalidHandoffPolicyIsNotTreatedAsLegacyRecord() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let malformed = Data(#"{"displayID":"internal-screen","brightness":0.73,"automaticBrightness":true,"restoresBrightness":null}"#.utf8)
        try malformed.write(to: url)
        do {
            _ = try FileBrightnessRecoveryStore(url: url).load()
            XCTFail("An invalid handoff flag must not restore an old brightness")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: url), malformed)
    }
}
