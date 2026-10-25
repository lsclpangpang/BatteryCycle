import Foundation
#if canImport(XCTest) && !BATTERY_READINGS_STANDALONE
import XCTest
@testable import BatteryCycle
#else
private var readingFailures = 0
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) {
    if lhs != rhs { readingFailures += 1; print("FAIL: \(lhs) != \(rhs)") }
}
class XCTestCase {}
@main struct BatteryReadingsTestRunner {
    static func main() throws {
        let tests = BatteryReadingsTests()
        tests.testCapacityRatioDoesNotOverflow()
        tests.testInvalidHealthCannotTrapIntegerConversion()
        tests.testExtremeTimestampsCannotTrapIntegerConversion()
        try tests.testStatusReadRejectsOversizedFile()
        print("BatteryReadings: 4 checks, \(readingFailures) failures")
        if readingFailures > 0 { exit(1) }
    }
}
#endif

final class BatteryReadingsTests: XCTestCase {
    func testCapacityRatioDoesNotOverflow() {
        XCTAssertEqual(BatteryReadings.capacityPercent(current: 40, maximum: 100), 40)
        XCTAssertEqual(BatteryReadings.capacityPercent(current: Int.max, maximum: Int.max), 100)
        XCTAssertEqual(BatteryReadings.capacityPercent(current: Int.max, maximum: 100), nil)
        XCTAssertEqual(BatteryReadings.capacityPercent(current: -1, maximum: 100), nil)
        XCTAssertEqual(BatteryReadings.capacityPercent(current: 1, maximum: 0), nil)
    }

    func testInvalidHealthCannotTrapIntegerConversion() {
        XCTAssertEqual(BatteryReadings.healthPercent(full: 4_100, design: 5_000), 82)
        XCTAssertEqual(BatteryReadings.healthPercent(full: 5_100, design: 5_000), 102)
        XCTAssertEqual(BatteryReadings.healthPercent(full: Int.max, design: 1), nil)
        XCTAssertEqual(BatteryReadings.healthPercent(full: Int.min, design: 1), nil)
        XCTAssertEqual(BatteryReadings.healthPercent(full: 1, design: 0), nil)
    }

    func testExtremeTimestampsCannotTrapIntegerConversion() {
        XCTAssertEqual(BatteryReadings.elapsedSeconds(since: 1_000, now: 1_020.9), 20)
        for updated in [1e308, -1e308, Double.nan, .infinity, -.infinity, 0, 2_000] {
            XCTAssertEqual(BatteryReadings.elapsedSeconds(since: updated, now: 1_000), nil)
        }
        XCTAssertEqual(BatteryReadings.elapsedSeconds(since: 1, now: 1e308), nil)
    }

    func testStatusReadRejectsOversizedFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let normal = Data("{\"pct\":40}".utf8)
        try normal.write(to: url)
        XCTAssertEqual(try BatteryReadings.readSmallFile(at: url), normal)
        try Data(repeating: 32, count: 65_536).write(to: url)
        XCTAssertEqual(try BatteryReadings.readSmallFile(at: url).count, 65_536)
        try Data(repeating: 32, count: 65_537).write(to: url)
        var rejected = false
        do { _ = try BatteryReadings.readSmallFile(at: url) }
        catch { rejected = true }
        XCTAssertEqual(rejected, true)
    }
}
