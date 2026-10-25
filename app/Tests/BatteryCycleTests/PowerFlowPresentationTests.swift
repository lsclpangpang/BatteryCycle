import Foundation
import CoreGraphics
#if canImport(XCTest) && !POWER_FLOW_STANDALONE
import XCTest
@testable import BatteryCycle
#else
private var flowFailures = 0
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) {
    if lhs != rhs { flowFailures += 1; print("FAIL: \(lhs) != \(rhs)") }
}
class XCTestCase {}
@main struct PowerFlowTestRunner {
    static func main() {
        let tests = PowerFlowPresentationTests()
        tests.testChargingHasTwoIndependentRoutes()
        tests.testExternalSupplyDoesNotFlowThroughBattery()
        tests.testBatteryAndUnknownCollapseTheBypassSpace()
        tests.testHybridHasTwoSourcesButNeverChargesBattery()
        tests.testConnectedUSBDeviceIsNotProofOfACharger()
        tests.testMissingAndInvalidPowerAreNotZero()
        tests.testMissingVisibilityMeasurementDoesNotDisableAnimation()
        tests.testKnownOffscreenFrameAndClosedMenuDisableAnimation()
        print("PowerFlowPresentation: 8 checks, \(flowFailures) failures")
        if flowFailures > 0 { exit(1) }
    }
}
#endif

final class PowerFlowPresentationTests: XCTestCase {
    private func presentation(_ source: PowerFlowState) -> PowerFlowPresentation {
        PowerFlowPresentation(telemetry: PowerTelemetry(source: source), ports: [])
    }
    func testChargingHasTwoIndependentRoutes() {
        XCTAssertEqual(presentation(.charging).routes, [.direct, .charge])
    }
    func testExternalSupplyDoesNotFlowThroughBattery() {
        XCTAssertEqual(presentation(.external).routes, [.direct])
        XCTAssertEqual(presentation(.external).batteryText, "待命")
    }
    func testBatteryAndUnknownCollapseTheBypassSpace() {
        XCTAssertEqual(presentation(.battery).showsBypass, false)
        XCTAssertEqual(presentation(.battery).routes, [.discharge])
        XCTAssertEqual(presentation(.unknown).showsBypass, false)
        XCTAssertEqual(presentation(.unknown).routes, [])
    }
    func testHybridHasTwoSourcesButNeverChargesBattery() {
        XCTAssertEqual(presentation(.hybrid).routes, [.direct, .discharge])
    }
    func testConnectedUSBDeviceIsNotProofOfACharger() {
        let usb = PortStatus(id: "usbC:1", kind: .usbC, label: "左上 USB-C", location: "left-back", connection: .connected)
        let result = PowerFlowPresentation(telemetry: PowerTelemetry(source: .battery), ports: [usb])
        XCTAssertEqual(result.chargerText, "未使用外接")
    }
    func testMissingAndInvalidPowerAreNotZero() {
        XCTAssertEqual(PowerFlowPresentation.watts(nil), "暂不可用")
        XCTAssertEqual(PowerFlowPresentation.watts(.nan), "暂不可用")
        XCTAssertEqual(PowerFlowPresentation.watts(-1), "暂不可用")
        XCTAssertEqual(PowerFlowPresentation.watts(0), "0 W")
        XCTAssertEqual(PowerFlowPresentation.watts(14.21), "约 14.2 W")
    }
    func testMissingVisibilityMeasurementDoesNotDisableAnimation() {
        // Actual MenuBarExtra trace: menuVisible=true, viewVisible=true, but
        // the frame preference remained its default zero rectangle throughout.
        XCTAssertEqual(PowerFlowAnimationVisibility.isVisible(menuVisible: true, frame: .zero, viewportHeight: 650), true)
        XCTAssertEqual(PowerFlowAnimationVisibility.isVisible(menuVisible: true, frame: .null, viewportHeight: 650), true)
    }
    func testKnownOffscreenFrameAndClosedMenuDisableAnimation() {
        XCTAssertEqual(PowerFlowAnimationVisibility.isVisible(menuVisible: false, frame: .zero, viewportHeight: 650), false)
        XCTAssertEqual(PowerFlowAnimationVisibility.isVisible(menuVisible: true,
            frame: CGRect(x: 16, y: -110, width: 268, height: 100), viewportHeight: 650), false)
        XCTAssertEqual(PowerFlowAnimationVisibility.isVisible(menuVisible: true,
            frame: CGRect(x: 16, y: 660, width: 268, height: 100), viewportHeight: 650), false)
        XCTAssertEqual(PowerFlowAnimationVisibility.isVisible(menuVisible: true,
            frame: CGRect(x: 16, y: -50, width: 268, height: 100), viewportHeight: 650), true)
    }
}
