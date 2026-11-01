import Foundation
#if canImport(XCTest) && !DISPLAY_TRANSPORT_STANDALONE
import XCTest
@testable import BatteryCycle
#else
private var failures = 0
class XCTestCase {}
private func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") {
    if actual != expected { failures += 1; print("FAIL: \(message)") }
}
private func XCTAssertNil<T>(_ actual: T?, _ message: String = "") {
    if actual != nil { failures += 1; print("FAIL: expected unknown \(message)") }
}
@main struct DisplayTransportRunner {
    static func main() {
        let tests = DisplayTransportTests()
        tests.testSinkHDMIIsNotProofOfChassisHDMI()
        tests.testExplicitPhysicalAncestorWinsOverSinkTransport()
        tests.testOnlyHDMISourceIsClassified()
        tests.testUSBAdapterAndDockRemainUSBSource()
        tests.testConcurrentOrUnknownPortsAreNotGuessed()
        tests.testIncompleteInventoryIsNotNegativeEvidence()
        tests.testVirtualAndUnmatchedDisplaysAreNeverClassified()
        tests.testModelOnlyAndDuplicateSerialAreAmbiguous()
        tests.testFullEDIDMustBeCompleteAndUnique()
        tests.testExactRegistryPathDisambiguatesIdenticalModels()
        tests.testContradictoryIdentityRejectsReusedPath()
        tests.testMirrorSecondaryAndSleepingScreenRemainEnabled()
        tests.testMissingHDMIControllerIsNotDisconnectedEvidence()
        tests.testActiveLinkReportsChassisSourceEvenThroughHDMIAdapter()
        tests.testInactiveOrUnidentifiedLinkDoesNotAuthorizeAChange()
        tests.testDuplicateDisplayOrLinkIdentityIsAmbiguous()
        tests.testDockOwnedHDMIPortIsNotChassisHDMI()
        print("DisplayTransport: 17 checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
#endif

final class DisplayTransportTests: XCTestCase {
    private let hdmi = DisplayPhysicalPort(kind: .hdmi, connection: .connected)
    private let hdmiOff = DisplayPhysicalPort(kind: .hdmi, connection: .disconnected)
    private let usb = DisplayPhysicalPort(kind: .usbC, connection: .connected)
    private let usbOff = DisplayPhysicalPort(kind: .usbC, connection: .disconnected)

    private func classify(_ ports: [DisplayPhysicalPort], complete: Bool = true,
                          ancestors: [DisplayOutputPort] = [], native: Bool = true,
                          virtual: Bool = false) -> DisplayOutputPort? {
        DisplayTransportClassifier.classify(DisplayTransportEvidence(
            isNativeDCP: native, isVirtual: virtual, ancestorPorts: ancestors,
            inventory: ports, inventoryComplete: complete,
            transportUpstream: "DP", transportDownstream: "HDMI")).port
    }

    func testSinkHDMIIsNotProofOfChassisHDMI() {
        XCTAssertNil(classify([]))
    }
    func testExplicitPhysicalAncestorWinsOverSinkTransport() {
        XCTAssertEqual(classify([hdmi, usb], ancestors: [.usbC]), .usbC)
        XCTAssertEqual(classify([hdmi, usb], ancestors: [.hdmi]), .hdmi)
        XCTAssertNil(classify([hdmi, usb], ancestors: [.hdmi, .usbC]))
    }
    func testOnlyHDMISourceIsClassified() {
        XCTAssertEqual(classify([hdmi, usbOff, usbOff, usbOff]), .hdmi)
    }
    func testUSBAdapterAndDockRemainUSBSource() {
        XCTAssertEqual(classify([hdmiOff, usb, usbOff]), .usbC)
    }
    func testConcurrentOrUnknownPortsAreNotGuessed() {
        XCTAssertNil(classify([hdmi, usb]))
        XCTAssertNil(classify([hdmi, DisplayPhysicalPort(kind: .usbC, connection: .unknown)]))
        XCTAssertNil(classify([DisplayPhysicalPort(kind: .hdmi, connection: .unknown), usb]))
    }
    func testIncompleteInventoryIsNotNegativeEvidence() {
        XCTAssertNil(classify([hdmi, usbOff], complete: false))
        XCTAssertNil(classify([hdmi]))
    }
    func testVirtualAndUnmatchedDisplaysAreNeverClassified() {
        XCTAssertNil(classify([hdmi, usbOff], virtual: true))
        XCTAssertNil(classify([hdmi, usbOff], native: false))
    }
    private func identity(path: String? = nil, serial: UInt32 = 0, edid: Data? = nil) -> DisplayTransportIdentity {
        DisplayTransportIdentity(registryPath: path, edid: edid, vendor: 7, product: 9, serial: serial)
    }
    func testModelOnlyAndDuplicateSerialAreAmbiguous() {
        XCTAssertNil(DisplayTransportMatcher.match(identity(), candidates: [identity()]))
        XCTAssertEqual(DisplayTransportMatcher.match(identity(serial: 10), candidates: [identity(serial: 10)]), 0)
        XCTAssertNil(DisplayTransportMatcher.match(identity(serial: 10), candidates: [identity(serial: 10), identity(serial: 10)]))
    }
    private func edid(seed: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes[0...7] = [0, 255, 255, 255, 255, 255, 255, 0][...]
        bytes[12] = seed
        bytes[127] = 0 &- bytes.prefix(127).reduce(0, &+)
        return Data(bytes)
    }
    func testFullEDIDMustBeCompleteAndUnique() {
        let first = identity(edid: edid(seed: 1)), second = identity(edid: edid(seed: 2))
        XCTAssertEqual(DisplayTransportMatcher.match(first, candidates: [second, first]), 1)
        XCTAssertNil(DisplayTransportMatcher.match(first, candidates: [first, first]))
        let partial = identity(edid: Data([1, 2, 3]))
        XCTAssertNil(DisplayTransportMatcher.match(partial, candidates: [partial]))
    }
    func testExactRegistryPathDisambiguatesIdenticalModels() {
        XCTAssertEqual(DisplayTransportMatcher.match(identity(path: "IOService:/framebuffer-b"),
            candidates: [identity(path: "IOService:/framebuffer-a"), identity(path: "IOService:/framebuffer-b")]), 1)
    }
    func testContradictoryIdentityRejectsReusedPath() {
        XCTAssertNil(DisplayTransportMatcher.match(identity(path: "IOService:/fb", serial: 3),
            candidates: [identity(path: "IOService:/fb", serial: 4)]))
    }
    func testMirrorSecondaryAndSleepingScreenRemainEnabled() {
        XCTAssertEqual(DisplayOutputPresence.isEnabled(active: false, mirrored: true, asleep: false), true)
        XCTAssertEqual(DisplayOutputPresence.isEnabled(active: false, mirrored: false, asleep: true), true)
        XCTAssertEqual(DisplayOutputPresence.isEnabled(active: false, mirrored: false, asleep: false), false)
    }

    func testMissingHDMIControllerIsNotDisconnectedEvidence() {
        XCTAssertNil(classify([usb]))
    }

    private func linkProperties(type: String = "USB-C", active: Bool = true, serial: UInt32 = 393) -> [String: Any] {
        ["ParentPortBuiltIn": true, "ParentBuiltInPortTypeDescription": type,
         "ParentBuiltInPortNumber": 1, "ParentPortTypeDescription": type,
         "TransportDescription": "Port-\(type)@1/DisplayPort@0", "Active": active,
         "Tunneled": true, "Metadata": ["ManufacturerName": "AOC", "ProductID": 9987, "SerialNumber": serial]]
    }

    private var linkedIdentity: DisplayTransportIdentity {
        .init(registryPath: "IOService:/native/framebuffer", edid: nil, vendor: 1507, product: 9987, serial: 393)
    }

    func testActiveLinkReportsChassisSourceEvenThroughHDMIAdapter() {
        let usbLink = DisplayPortLinkEvidence(properties: linkProperties())
        let hdmiLink = DisplayPortLinkEvidence(properties: linkProperties(type: "HDMI"))
        XCTAssertEqual(DisplayPortLinkMatcher.port(for: linkedIdentity, among: [linkedIdentity], links: [usbLink]), .usbC)
        XCTAssertEqual(DisplayPortLinkMatcher.port(for: linkedIdentity, among: [linkedIdentity], links: [hdmiLink]), .hdmi)
    }

    func testInactiveOrUnidentifiedLinkDoesNotAuthorizeAChange() {
        XCTAssertNil(DisplayPortLinkMatcher.port(for: linkedIdentity, among: [linkedIdentity],
            links: [.init(properties: linkProperties(active: false))]))
        XCTAssertNil(DisplayPortLinkMatcher.port(for: linkedIdentity, among: [linkedIdentity],
            links: [.init(properties: linkProperties(serial: 0))]))
        var malformed = linkProperties()
        malformed.removeValue(forKey: "Active")
        XCTAssertNil(DisplayPortLinkMatcher.port(for: linkedIdentity, among: [linkedIdentity],
            links: [.init(properties: malformed)]))
    }

    func testDuplicateDisplayOrLinkIdentityIsAmbiguous() {
        let link = DisplayPortLinkEvidence(properties: linkProperties())
        XCTAssertNil(DisplayPortLinkMatcher.port(for: linkedIdentity, among: [linkedIdentity, linkedIdentity], links: [link]))
        XCTAssertNil(DisplayPortLinkMatcher.port(for: linkedIdentity, among: [linkedIdentity], links: [link, link]))
    }

    func testDockOwnedHDMIPortIsNotChassisHDMI() {
        var dock = linkProperties(type: "HDMI")
        dock["ParentPortBuiltIn"] = false
        XCTAssertNil(DisplayPortLinkMatcher.port(for: linkedIdentity, among: [linkedIdentity], links: [.init(properties: dock)]))
        var conflicting = linkProperties()
        conflicting["ParentBuiltInPortTypeDescription"] = "HDMI"
        XCTAssertNil(DisplayPortLinkMatcher.port(for: linkedIdentity, among: [linkedIdentity], links: [.init(properties: conflicting)]))
    }
}
