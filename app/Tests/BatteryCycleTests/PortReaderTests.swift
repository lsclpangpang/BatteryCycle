import Foundation
#if canImport(XCTest) && !PORT_READER_STANDALONE
import XCTest
@testable import BatteryCycle
#else
// Command Line Tools do not ship XCTest. Run these same checks with swiftc by
// compiling this file together with PortReader.swift (no test SDK required).
private var failures = 0
class XCTestCase {}
struct XCTSkip: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
private struct MissingValue: Error {}
func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw MissingValue() }
    return value
}
func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T, _ message: String = "") {
    if left != right { failures += 1; print("FAIL: \(left) != \(right) \(message)") }
}
func XCTAssertNotEqual<T: Equatable>(_ left: T, _ right: T) {
    if left == right { failures += 1; print("FAIL: unexpected equal values \(left)") }
}
func XCTAssertNil<T>(_ value: T?, _ message: String = "") {
    if value != nil { failures += 1; print("FAIL: expected nil \(message)") }
}
func XCTAssertFalse(_ value: Bool, _ message: String = "") { XCTAssertEqual(value, false, message) }

@main
struct PortReaderTestRunner {
    static func main() throws {
        let tests = PortReaderTests()
        try tests.testPhysicalLocationsAndAgreedOrder()
        try tests.testChargingOnlyConnectionDoesNotRequireUSBOrThunderboltDevice()
        try tests.testUnknownAndMalformedStatesAreNotDisconnected()
        try tests.testCCFallbackAndContradictorySnapshots()
        try tests.testNoPhysicalLocationIsInventedFromPortNumber()
        tests.testExternalPortsAndUnrelatedPortKindsAreExcluded()
        try tests.testMissingNumberUsesRegistryIdentityWithoutCollapsingPorts()
        try tests.testInvalidPortNumbersNeverAliasAnotherConnector()
        do { try tests.testLiveSnapshotWhenRequested() } catch is XCTSkip {}
        print("PortReader: 8 checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
#endif

final class PortReaderTests: XCTestCase {
    private func properties(type: String = "USB-C", number: Int = 1,
                            connected: Any? = true, builtIn: Bool = true) -> [String: Any] {
        var result: [String: Any] = [
            "PortTypeDescription": type, "PortNumber": number, "BuiltIn": builtIn,
        ]
        result["ConnectionActive"] = connected
        return result
    }

    func testPhysicalLocationsAndAgreedOrder() throws {
        let input: [(String, Int, String?)] = [
            ("HDMI", 1, nil), ("USB-C", 3, "right"), ("USB-C", 2, "left-front"),
            ("MagSafe 3", 1, nil), ("USB-C", 1, "left-back"),
        ]
        let ports = try input.map { type, number, location in
            try XCTUnwrap(PortReader.decode(properties: properties(type: type, number: number),
                                            registryID: UInt64(number), location: location, ccActive: nil))
        }
        XCTAssertEqual(PortReader.sorted(ports).map(\.label),
                       ["MagSafe", "左上 USB-C", "左下 USB-C", "右侧 USB-C", "HDMI"])
        XCTAssertEqual(Set(ports.map(\.id)).count, 5, "Different port types may share a number")
    }

    func testChargingOnlyConnectionDoesNotRequireUSBOrThunderboltDevice() throws {
        let port = try XCTUnwrap(PortReader.decode(properties: properties(), registryID: 1,
                                                  location: "right", ccActive: true))
        XCTAssertEqual(port.connection, .connected)
    }

    func testUnknownAndMalformedStatesAreNotDisconnected() throws {
        for value: Any? in [nil, "No", NSNumber(value: 0), NSNumber(value: 1)] {
            let port = try XCTUnwrap(PortReader.decode(properties: properties(connected: value),
                                                      registryID: 1, location: nil, ccActive: nil))
            XCTAssertEqual(port.connection, .unknown)
        }
        let disconnected = try XCTUnwrap(PortReader.decode(properties: properties(connected: false),
                                                          registryID: 1, location: nil, ccActive: nil))
        XCTAssertEqual(disconnected.connection, .disconnected)
    }

    func testCCFallbackAndContradictorySnapshots() throws {
        let fallback = try XCTUnwrap(PortReader.decode(properties: properties(connected: nil),
                                                      registryID: 1, location: nil, ccActive: true))
        XCTAssertEqual(fallback.connection, .connected)
        let contradictory = try XCTUnwrap(PortReader.decode(properties: properties(connected: false),
                                                           registryID: 1, location: nil, ccActive: true))
        XCTAssertEqual(contradictory.connection, .unknown)
    }

    func testNoPhysicalLocationIsInventedFromPortNumber() throws {
        let port = try XCTUnwrap(PortReader.decode(properties: properties(number: 2), registryID: 1,
                                                  location: nil, ccActive: nil))
        XCTAssertEqual(port.label, "USB-C 2")
        XCTAssertNil(port.location)
        let unknownLocation = try XCTUnwrap(PortReader.decode(properties: properties(number: 4),
                                                             registryID: 2, location: "internal", ccActive: nil))
        XCTAssertEqual(unknownLocation.label, "USB-C 4")
    }

    func testExternalPortsAndUnrelatedPortKindsAreExcluded() {
        XCTAssertNil(PortReader.decode(properties: properties(builtIn: false), registryID: 1,
                                       location: "left-back", ccActive: true))
        XCTAssertNil(PortReader.decode(properties: properties(type: "SD Card"), registryID: 1,
                                       location: nil, ccActive: nil))
        var unidentified = properties()
        unidentified.removeValue(forKey: "BuiltIn")
        XCTAssertNil(PortReader.decode(properties: unidentified, registryID: 1,
                                       location: nil, ccActive: true))
    }

    func testMissingNumberUsesRegistryIdentityWithoutCollapsingPorts() throws {
        var data = properties()
        data.removeValue(forKey: "PortNumber")
        let first = try XCTUnwrap(PortReader.decode(properties: data, registryID: 10, location: nil, ccActive: nil))
        let second = try XCTUnwrap(PortReader.decode(properties: data, registryID: 11, location: nil, ccActive: nil))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.label, "USB-C")
    }

    func testLiveSnapshotWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["BATTERYCYCLE_TEST_LIVE_PORTS"] == "1" else {
            throw XCTSkip("Set BATTERYCYCLE_TEST_LIVE_PORTS=1 for a read-only hardware sample")
        }
        var timings = [Double]()
        var ports = [PortStatus]()
        for _ in 0..<20 {
            let start = ProcessInfo.processInfo.systemUptime
            ports = PortReader.read()
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        XCTAssertFalse(ports.isEmpty, "This diagnostic expects a supported machine with built-in ports")
        print("PORT_READ milliseconds min=\(timings.min()!) avg=\(timings.reduce(0, +) / Double(timings.count)) max=\(timings.max()!)")
        for port in ports { print("PORT_SNAPSHOT \(port.id) \(port.label) \(port.connection.title)") }
    }

    func testInvalidPortNumbersNeverAliasAnotherConnector() throws {
        let invalid: [Any] = [1.9, Double.nan, Double.infinity, 0, -1, 256, UInt64.max, true]
        for number in invalid {
            var data = properties()
            data["PortNumber"] = number
            let port = try XCTUnwrap(PortReader.decode(properties: data, registryID: 77, location: nil, ccActive: nil))
            XCTAssertEqual(port.id, "usbC:registry-77")
            XCTAssertEqual(port.label, "USB-C")
        }
    }
}
