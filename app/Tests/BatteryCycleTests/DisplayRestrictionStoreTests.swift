import Foundation
#if canImport(XCTest) && !DISPLAY_RESTRICTION_STORE_STANDALONE
import XCTest
@testable import BatteryCycle
#else
private var failures = 0
private func XCTAssertTrue(_ value: Bool) { if !value { failures += 1; print("FAIL: expected true") } }
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) { if lhs != rhs { failures += 1; print("FAIL: \(lhs) != \(rhs)") } }
private func XCTAssertNil<T>(_ value: T?) { if value != nil { failures += 1; print("FAIL: expected nil") } }
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) {
    do { _ = try expression(); failures += 1; print("FAIL: expected error") } catch {}
}
class XCTestCase {}
@main struct DisplayRestrictionStoreTestRunner {
    static func main() {
        let tests = DisplayRestrictionStoreTests()
        do {
            try tests.testJournalRoundTripAndPermissions()
            try tests.testMalformedJournalIsNotTreatedAsEmpty()
            try tests.testExclusiveLeaseSurvivesOwnerChangeWithoutUnlinking()
        } catch { failures += 1; print("FAIL: \(error)") }
        print("Display restriction storage: 3 checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
#endif

final class DisplayRestrictionStoreTests: XCTestCase {
    func testJournalRoundTripAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDisplayRestrictionStore(url: directory.appendingPathComponent("recovery.json"))
        XCTAssertNil(try store.load())
        let state = DisplayRestrictionState(settings: .init(hdmi: true, usbC: false))
        try store.save(state)
        XCTAssertEqual(try store.load(), state)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMalformedJournalIsNotTreatedAsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.json")
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try FileDisplayRestrictionStore(url: url).load())
    }

    func testExclusiveLeaseSurvivesOwnerChangeWithoutUnlinking() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("control.lock")
        let first = FileDisplayRestrictionLease(url: url)
        let second = FileDisplayRestrictionLease(url: url)
        try first.acquire()
        XCTAssertThrowsError(try second.acquire())
        first.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try second.acquire()
        second.release()
    }
}
