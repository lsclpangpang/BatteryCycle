import Foundation
#if canImport(XCTest) && !MENU_SIZING_STANDALONE
import XCTest
@testable import BatteryCycle
#else
private var sizingFailures = 0
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) {
    if lhs != rhs { sizingFailures += 1; print("FAIL: \(lhs) != \(rhs)") }
}
class XCTestCase {}
@main struct MenuSizingTestRunner {
    static func main() {
        let tests = MenuSizingTests()
        tests.testContentCanGrowPastOldHeightLimitAndShrink()
        tests.testOnlyScreenSpaceLimitsHeight()
        tests.testInvalidMeasurementsCannotCollapseTheMenu()
        tests.testScreenChangeRecomputesHeightFromFullContent()
        print("MenuSizing: 4 checks, \(sizingFailures) failures")
        if sizingFailures > 0 { exit(1) }
    }
}
#endif

final class MenuSizingTests: XCTestCase {
    func testContentCanGrowPastOldHeightLimitAndShrink() {
        var sizing = MenuSizing()
        sizing.updateScreenHeight(944)
        sizing.measureContent(720)
        XCTAssertEqual(sizing.viewportHeight, 720)
        sizing.measureContent(857.25)
        XCTAssertEqual(sizing.viewportHeight, 858)
        sizing.measureContent(710)
        XCTAssertEqual(sizing.viewportHeight, 710)
    }

    func testOnlyScreenSpaceLimitsHeight() {
        var sizing = MenuSizing()
        sizing.updateScreenHeight(944)
        sizing.measureContent(1_100)
        XCTAssertEqual(sizing.viewportHeight, 928)
        sizing.updateScreenHeight(1_440)
        XCTAssertEqual(sizing.viewportHeight, 1_100)
    }

    func testInvalidMeasurementsCannotCollapseTheMenu() {
        var sizing = MenuSizing()
        let initialHeight = sizing.viewportHeight
        for height: CGFloat in [0, -1, .nan, .infinity] {
            sizing.measureContent(height)
            sizing.updateScreenHeight(height)
        }
        XCTAssertEqual(sizing.viewportHeight, initialHeight)
        sizing.measureContent(730)
        for height: CGFloat in [0, -1, .nan, .infinity] {
            sizing.measureContent(height)
        }
        XCTAssertEqual(sizing.viewportHeight, 730)
    }

    func testScreenChangeRecomputesHeightFromFullContent() {
        var sizing = MenuSizing()
        sizing.measureContent(900)
        sizing.updateScreenHeight(600)
        XCTAssertEqual(sizing.viewportHeight, 584)
        sizing.updateScreenHeight(1_000)
        XCTAssertEqual(sizing.viewportHeight, 900)
    }
}
