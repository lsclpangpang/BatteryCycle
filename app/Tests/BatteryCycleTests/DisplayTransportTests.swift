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
        tests.testZeroSerialUsesCompleteTopLevelLinkEDID()
        tests.testZeroSerialUsesMetadataLinkEDID()
        tests.testMatchingTopAndMetadataEDIDAreAccepted()
        tests.testConflictingLinkEDIDSourcesRejectEvenSerialFallback()
        tests.testDifferentEDIDDisambiguatesSameModelAndSerial()
        tests.testIdenticalEDIDOnMultipleDisplaysRemainsUnknown()
        tests.testIdenticalEDIDOnMultipleLinksRemainsUnknown()
        tests.testEDIDMatchStillRejectsContradictoryNonzeroSerial()
        tests.testEDIDMatchAllowsOneMissingOrZeroSerial()
        tests.testConflictingValidEDIDRejectsSerialFallback()
        tests.testZeroSerialRequiresCompleteValidEDIDOnBothSides()
        tests.testEDIDCannotAuthorizeInactiveOrUntrustedPort()
        tests.testEDIDRequiresMatchingVendorAndProduct()
        tests.testEDIDRequiresTargetDisplayToBePresent()
        tests.testNonzeroSerialFallbackSupportsMissingEDID()
        tests.testSerialFallbackDoesNotDisambiguateDisplaysWithoutLinkEDID()
        tests.testFramebufferEDIDUUIDMatchesZeroSerialLink()
        tests.testFramebufferEDIDUUIDRejectsDuplicatePrefixDisplays()
        tests.testFramebufferEDIDUUIDRejectsDuplicatePrefixLinks()
        tests.testFramebufferEDIDUUIDRejectsSerialAndModelContradictions()
        tests.testFramebufferEDIDUUIDRequiresCompleteValidLinkEDID()
        tests.testZeroSerialWithoutEDIDUUIDDoesNotUseModelOnly()
        tests.testFramebufferEDIDUUIDCannotOverrideFullEDIDConflict()
        tests.testFramebufferEDIDUUIDRejectsUnidentifiedSameModelPeers()
        tests.testRegistryPathDoesNotTreatOpaqueEDIDUUIDAsNegativeEvidence()
        tests.testUSBSerialMatchSurvivesUnrelatedFramebufferUUID()
        tests.testFullEDIDRejectsUnidentifiedSameModelDisplay()
        tests.testFramebufferEDIDUUIDRejectsOpaqueSameModelPeer()
        print("DisplayTransport: 45 checks, \(failures) failures")
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
    private func edid(seed: UInt8, extensionBlocks: Int = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: (extensionBlocks + 1) * 128)
        bytes[0...7] = [0, 255, 255, 255, 255, 255, 255, 0][...]
        bytes[12] = seed
        bytes[126] = UInt8(extensionBlocks)
        for start in stride(from: 0, to: bytes.count, by: 128) {
            bytes[start + 127] = 0 &- bytes[start..<(start + 127)].reduce(0, &+)
        }
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

    private func linkedIdentity(serial: UInt32 = 0, edid: Data?, vendor: UInt32 = 1507,
                                product: UInt32 = 9987, path: String = "IOService:/native/framebuffer",
                                edidUUID: UUID? = nil) -> DisplayTransportIdentity {
        .init(registryPath: path, edid: edid, vendor: vendor, product: product, serial: serial, edidUUID: edidUUID)
    }

    private func edidLinkProperties(type: String = "HDMI", serial: UInt32 = 0,
                                    topEDID: Data? = nil, metadataEDID: Data? = nil) -> [String: Any] {
        var properties = linkProperties(type: type, serial: serial)
        properties["EDID"] = topEDID
        var metadata = properties["Metadata"] as! [String: Any]
        metadata["EDID"] = metadataEDID
        properties["Metadata"] = metadata
        return properties
    }

    func testZeroSerialUsesCompleteTopLevelLinkEDID() {
        let data = edid(seed: 11, extensionBlocks: 1)
        let display = linkedIdentity(edid: data)
        let link = DisplayPortLinkEvidence(properties: edidLinkProperties(topEDID: data))
        XCTAssertEqual(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link]), .hdmi)
    }

    func testZeroSerialUsesMetadataLinkEDID() {
        let data = edid(seed: 12, extensionBlocks: 1)
        let display = linkedIdentity(edid: data)
        let link = DisplayPortLinkEvidence(properties: edidLinkProperties(metadataEDID: data))
        XCTAssertEqual(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link]), .hdmi)
    }

    func testMatchingTopAndMetadataEDIDAreAccepted() {
        let data = edid(seed: 13)
        let display = linkedIdentity(edid: data)
        let link = DisplayPortLinkEvidence(properties: edidLinkProperties(type: "USB-C", topEDID: data, metadataEDID: data))
        XCTAssertEqual(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link]), .usbC)
    }

    func testConflictingLinkEDIDSourcesRejectEvenSerialFallback() {
        let data = edid(seed: 14), other = edid(seed: 15)
        let display = linkedIdentity(serial: 393, edid: data)
        for conflicting in [other, Data(data.prefix(64))] {
            let link = DisplayPortLinkEvidence(properties: edidLinkProperties(serial: 393,
                topEDID: data, metadataEDID: conflicting))
            XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link]))
        }
    }

    func testDifferentEDIDDisambiguatesSameModelAndSerial() {
        for serial: UInt32 in [0, 393] {
            let firstData = edid(seed: 16), secondData = edid(seed: 17)
            let first = linkedIdentity(serial: serial, edid: firstData, path: "IOService:/first")
            let second = linkedIdentity(serial: serial, edid: secondData, path: "IOService:/second")
            let links = [DisplayPortLinkEvidence(properties: edidLinkProperties(serial: serial, topEDID: firstData)),
                         DisplayPortLinkEvidence(properties: edidLinkProperties(type: "USB-C", serial: serial, topEDID: secondData))]
            XCTAssertEqual(DisplayPortLinkMatcher.port(for: first, among: [first, second], links: links), .hdmi)
            XCTAssertEqual(DisplayPortLinkMatcher.port(for: second, among: [first, second], links: links), .usbC)
        }
    }

    func testIdenticalEDIDOnMultipleDisplaysRemainsUnknown() {
        let data = edid(seed: 18)
        let display = linkedIdentity(serial: 393, edid: data)
        let link = DisplayPortLinkEvidence(properties: edidLinkProperties(serial: 393, topEDID: data))
        for otherSerial: UInt32 in [0, 393, 394] {
            let duplicate = linkedIdentity(serial: otherSerial, edid: data, path: "IOService:/other")
            XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display, duplicate], links: [link]))
        }
    }

    func testIdenticalEDIDOnMultipleLinksRemainsUnknown() {
        let data = edid(seed: 19)
        let display = linkedIdentity(serial: 393, edid: data)
        let first = DisplayPortLinkEvidence(properties: edidLinkProperties(serial: 393, topEDID: data))
        for otherSerial: UInt32 in [0, 393, 394] {
            let duplicate = DisplayPortLinkEvidence(properties: edidLinkProperties(type: "USB-C",
                serial: otherSerial, topEDID: data))
            XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display], links: [first, duplicate]))
        }
    }

    func testEDIDMatchStillRejectsContradictoryNonzeroSerial() {
        let data = edid(seed: 20)
        let display = linkedIdentity(serial: 393, edid: data)
        let link = DisplayPortLinkEvidence(properties: edidLinkProperties(serial: 394, topEDID: data))
        XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link]))
    }

    func testEDIDMatchAllowsOneMissingOrZeroSerial() {
        let data = edid(seed: 21)
        for (displaySerial, linkSerial): (UInt32, UInt32) in [(0, 393), (393, 0)] {
            let display = linkedIdentity(serial: displaySerial, edid: data)
            let link = DisplayPortLinkEvidence(properties: edidLinkProperties(serial: linkSerial, topEDID: data))
            XCTAssertEqual(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link]), .hdmi)
        }
        let display = linkedIdentity(serial: 393, edid: data)
        var properties = edidLinkProperties(topEDID: data)
        var metadata = properties["Metadata"] as! [String: Any]
        metadata.removeValue(forKey: "SerialNumber")
        properties["Metadata"] = metadata
        XCTAssertEqual(DisplayPortLinkMatcher.port(for: display, among: [display],
            links: [.init(properties: properties)]), .hdmi)
    }

    func testConflictingValidEDIDRejectsSerialFallback() {
        let display = linkedIdentity(serial: 393, edid: edid(seed: 22))
        let link = DisplayPortLinkEvidence(properties: edidLinkProperties(serial: 393, topEDID: edid(seed: 23)))
        XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link]))
    }

    func testZeroSerialRequiresCompleteValidEDIDOnBothSides() {
        let data = edid(seed: 24, extensionBlocks: 1)
        var badChecksum = data
        badChecksum[255] &+= 1
        var badHeader = data
        badHeader[0] = 1
        badHeader[127] &-= 1
        let invalid: [Data?] = [nil, Data(data.prefix(64)), Data(data.prefix(128)), badChecksum, badHeader]
        for broken in invalid {
            let display = linkedIdentity(edid: data)
            let brokenLink = DisplayPortLinkEvidence(properties: edidLinkProperties(topEDID: broken))
            XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display], links: [brokenLink]))
            let brokenDisplay = linkedIdentity(edid: broken)
            let validLink = DisplayPortLinkEvidence(properties: edidLinkProperties(topEDID: data))
            XCTAssertNil(DisplayPortLinkMatcher.port(for: brokenDisplay, among: [brokenDisplay], links: [validLink]))
            XCTAssertNil(DisplayPortLinkMatcher.port(for: brokenDisplay, among: [brokenDisplay], links: [brokenLink]))
        }
    }

    func testEDIDCannotAuthorizeInactiveOrUntrustedPort() {
        let data = edid(seed: 25)
        let display = linkedIdentity(edid: data)
        let properties = edidLinkProperties(topEDID: data)
        for (key, value): (String, Any) in [("Active", false), ("Active", 1), ("ParentPortBuiltIn", false),
                                          ("ParentPortBuiltIn", 1), ("ParentBuiltInPortNumber", 0),
                                          ("ParentPortTypeDescription", "USB-C"), ("TransportDescription", "Port-HDMI@2/DisplayPort@0")] {
            var untrusted = properties
            untrusted[key] = value
            XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display],
                links: [.init(properties: untrusted)]))
        }
    }

    func testEDIDRequiresMatchingVendorAndProduct() {
        let data = edid(seed: 26)
        let link = DisplayPortLinkEvidence(properties: edidLinkProperties(topEDID: data))
        for (vendor, product): (UInt32, UInt32) in [(0, 9987), (1507, 0), (1508, 9987), (1507, 9988)] {
            let display = linkedIdentity(edid: data, vendor: vendor, product: product)
            XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link]))
        }
    }

    func testEDIDRequiresTargetDisplayToBePresent() {
        let display = linkedIdentity(edid: edid(seed: 27))
        let other = linkedIdentity(edid: edid(seed: 28))
        let link = DisplayPortLinkEvidence(properties: edidLinkProperties(topEDID: display.edid))
        XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [], links: [link]))
        XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [other], links: [link]))
    }

    func testNonzeroSerialFallbackSupportsMissingEDID() {
        let data = edid(seed: 29)
        let withoutEDID = linkedIdentity
        let withEDID = linkedIdentity(serial: 393, edid: data)
        let legacyLink = DisplayPortLinkEvidence(properties: linkProperties(type: "HDMI"))
        let withEDIDLink = DisplayPortLinkEvidence(properties: edidLinkProperties(serial: 393, topEDID: data))
        XCTAssertEqual(DisplayPortLinkMatcher.port(for: withoutEDID, among: [withoutEDID], links: [legacyLink]), .hdmi)
        XCTAssertEqual(DisplayPortLinkMatcher.port(for: withEDID, among: [withEDID], links: [legacyLink]), .hdmi)
        XCTAssertEqual(DisplayPortLinkMatcher.port(for: withoutEDID, among: [withoutEDID], links: [withEDIDLink]), .hdmi)
    }

    func testSerialFallbackDoesNotDisambiguateDisplaysWithoutLinkEDID() {
        let first = linkedIdentity(serial: 393, edid: edid(seed: 30))
        let second = linkedIdentity(serial: 393, edid: edid(seed: 31), path: "IOService:/second")
        let link = DisplayPortLinkEvidence(properties: linkProperties(type: "HDMI"))
        XCTAssertNil(DisplayPortLinkMatcher.port(for: first, among: [first, second], links: [link]))
    }

    private func samePrefixEDID(_ data: Data) -> Data {
        var result = data
        result[32] &+= 1
        result[127] &-= 1
        return result
    }

    func testFramebufferEDIDUUIDMatchesZeroSerialLink() {
        let data = edid(seed: 31, extensionBlocks: 1)
        let fingerprint = DisplayTransportMatcher.edidUUID(data)
        XCTAssertEqual(fingerprint, UUID(uuidString: "00000000-1F00-0000-0000-000000000000"))
        let display = linkedIdentity(edid: nil, edidUUID: fingerprint)
        for (type, port): (String, DisplayOutputPort) in [("HDMI", .hdmi), ("USB-C", .usbC)] {
            let link = DisplayPortLinkEvidence(properties: edidLinkProperties(type: type, topEDID: data))
            XCTAssertEqual(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link]), port)
        }
    }

    func testFramebufferEDIDUUIDRejectsDuplicatePrefixDisplays() {
        let data = edid(seed: 32), other = samePrefixEDID(data)
        let display = linkedIdentity(edid: nil, edidUUID: DisplayTransportMatcher.edidUUID(data))
        let link = DisplayPortLinkEvidence(properties: edidLinkProperties(topEDID: data))
        for duplicate in [linkedIdentity(edid: nil, path: "IOService:/other", edidUUID: display.edidUUID),
                          linkedIdentity(edid: other, path: "IOService:/other")] {
            XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display, duplicate], links: [link]))
        }
    }

    func testFramebufferEDIDUUIDRejectsDuplicatePrefixLinks() {
        let data = edid(seed: 33), other = samePrefixEDID(data)
        let display = linkedIdentity(edid: nil, edidUUID: DisplayTransportMatcher.edidUUID(data))
        let links = [DisplayPortLinkEvidence(properties: edidLinkProperties(topEDID: data)),
                     DisplayPortLinkEvidence(properties: edidLinkProperties(type: "USB-C", topEDID: other))]
        XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display], links: links))
    }

    func testFramebufferEDIDUUIDRejectsSerialAndModelContradictions() {
        let data = edid(seed: 34), fingerprint = DisplayTransportMatcher.edidUUID(data)
        for display in [linkedIdentity(serial: 393, edid: nil, edidUUID: fingerprint),
                        linkedIdentity(edid: nil, vendor: 1508, edidUUID: fingerprint),
                        linkedIdentity(edid: nil, product: 9988, edidUUID: fingerprint)] {
            let link = DisplayPortLinkEvidence(properties: edidLinkProperties(serial: 394, topEDID: data))
            XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link]))
        }
        let display = linkedIdentity(serial: 393, edid: nil, edidUUID: fingerprint)
        let conflicting = DisplayPortLinkEvidence(properties: edidLinkProperties(serial: 393, topEDID: edid(seed: 35)))
        // The framebuffer UUID is not this EDID-derived format on every device.
        // Without a positive fingerprint match, preserve the serial-only path.
        XCTAssertEqual(DisplayPortLinkMatcher.port(for: display, among: [display], links: [conflicting]), .hdmi)
    }

    func testFramebufferEDIDUUIDRequiresCompleteValidLinkEDID() {
        let data = edid(seed: 36, extensionBlocks: 1)
        let display = linkedIdentity(edid: nil, edidUUID: DisplayTransportMatcher.edidUUID(data))
        var corrupt = data
        corrupt[255] &+= 1
        for invalid in [Data(data.prefix(128)), corrupt] {
            XCTAssertNil(DisplayTransportMatcher.edidUUID(invalid))
            let link = DisplayPortLinkEvidence(properties: edidLinkProperties(topEDID: invalid))
            XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link]))
        }
    }

    func testZeroSerialWithoutEDIDUUIDDoesNotUseModelOnly() {
        let display = linkedIdentity(edid: nil)
        let link = DisplayPortLinkEvidence(properties: edidLinkProperties(topEDID: edid(seed: 37)))
        XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link]))
    }

    func testFramebufferEDIDUUIDCannotOverrideFullEDIDConflict() {
        let data = edid(seed: 38), other = samePrefixEDID(data)
        let fingerprint = DisplayTransportMatcher.edidUUID(data)
        let display = linkedIdentity(serial: 393, edid: data, edidUUID: fingerprint)
        let link = DisplayPortLinkEvidence(properties: edidLinkProperties(serial: 393, topEDID: other))
        XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link]))
        let inconsistent = linkedIdentity(serial: 393, edid: data, edidUUID: DisplayTransportMatcher.edidUUID(edid(seed: 39)))
        let matchingLink = DisplayPortLinkEvidence(properties: edidLinkProperties(serial: 393, topEDID: data))
        XCTAssertEqual(DisplayPortLinkMatcher.port(for: inconsistent, among: [inconsistent], links: [matchingLink]), .hdmi)
    }

    func testFramebufferEDIDUUIDRejectsUnidentifiedSameModelPeers() {
        let data = edid(seed: 40)
        let display = linkedIdentity(edid: nil, edidUUID: DisplayTransportMatcher.edidUUID(data))
        let unknown = linkedIdentity(edid: nil, path: "IOService:/unknown")
        let link = DisplayPortLinkEvidence(properties: edidLinkProperties(topEDID: data))
        XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display, unknown], links: [link]))
        let unknownLink = DisplayPortLinkEvidence(properties: edidLinkProperties(type: "USB-C"))
        XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link, unknownLink]))
    }

    func testRegistryPathDoesNotTreatOpaqueEDIDUUIDAsNegativeEvidence() {
        let data = edid(seed: 41)
        let display = linkedIdentity(serial: 393, edid: data)
        let matching = linkedIdentity(serial: 393, edid: nil, edidUUID: DisplayTransportMatcher.edidUUID(data))
        XCTAssertEqual(DisplayTransportMatcher.match(display, candidates: [matching]), 0)
        let conflicting = linkedIdentity(serial: 393, edid: nil, edidUUID: DisplayTransportMatcher.edidUUID(edid(seed: 42)))
        XCTAssertEqual(DisplayTransportMatcher.match(display, candidates: [conflicting]), 0)
        let inconsistent = linkedIdentity(serial: 393, edid: data, edidUUID: conflicting.edidUUID)
        XCTAssertEqual(DisplayTransportMatcher.match(inconsistent, candidates: [matching]), 0)
        let contradictoryEDID = linkedIdentity(serial: 393, edid: edid(seed: 42), edidUUID: matching.edidUUID)
        XCTAssertNil(DisplayTransportMatcher.match(display, candidates: [contradictoryEDID]))
    }

    func testUSBSerialMatchSurvivesUnrelatedFramebufferUUID() {
        let display = linkedIdentity(serial: 393, edid: nil,
            edidUUID: UUID(uuidString: "AD58C864-F1C0-4DA2-B346-43CB95C51EDA"))
        let link = DisplayPortLinkEvidence(properties: edidLinkProperties(type: "USB-C", serial: 393,
            topEDID: edid(seed: 43, extensionBlocks: 1)))
        XCTAssertEqual(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link]), .usbC)
    }

    func testFullEDIDRejectsUnidentifiedSameModelDisplay() {
        let data = edid(seed: 44)
        let display = linkedIdentity(edid: data)
        let peer = linkedIdentity(edid: nil, path: "IOService:/unknown-peer")
        let link = DisplayPortLinkEvidence(properties: edidLinkProperties(topEDID: data))
        XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display, peer], links: [link]))
        let unknownLink = DisplayPortLinkEvidence(properties: edidLinkProperties(type: "USB-C"))
        XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display], links: [link, unknownLink]))
    }

    func testFramebufferEDIDUUIDRejectsOpaqueSameModelPeer() {
        let data = edid(seed: 45)
        let display = linkedIdentity(edid: nil, edidUUID: DisplayTransportMatcher.edidUUID(data))
        let peer = linkedIdentity(edid: nil, path: "IOService:/opaque-peer",
            edidUUID: UUID(uuidString: "AD58C864-F1C0-4DA2-B346-43CB95C51EDA"))
        let link = DisplayPortLinkEvidence(properties: edidLinkProperties(topEDID: data))
        XCTAssertNil(DisplayPortLinkMatcher.port(for: display, among: [display, peer], links: [link]))
    }
}
