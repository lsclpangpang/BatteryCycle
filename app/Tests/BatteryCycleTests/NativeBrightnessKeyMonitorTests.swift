import AppKit
#if canImport(XCTest) && !BRIGHTNESS_KEY_STANDALONE
import XCTest
@testable import BatteryCycle
#elseif BRIGHTNESS_KEY_STANDALONE
private var keyFailures = 0
private func XCTAssertTrue(_ value: Bool) { if !value { keyFailures += 1; print("FAIL: expected brightness key") } }
private func XCTAssertFalse(_ value: Bool) { if value { keyFailures += 1; print("FAIL: unrelated input accepted") } }
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) { if lhs != rhs { keyFailures += 1; print("FAIL: \(lhs) != \(rhs)") } }
class XCTestCase {}
@main private struct BrightnessKeyTestRunner {
    static func main() {
        let tests = NativeBrightnessKeyMonitorTests()
        tests.testBothScreenBrightnessKeyDownsMatch()
        tests.testRepeatKeyDownMatches()
        tests.testKeyUpDoesNotMatch()
        tests.testWrongSubtypeDoesNotMatch()
        tests.testVolumeMediaAndKeyboardIlluminationDoNotMatch()
        tests.testOrdinaryLettersAndFunctionKeysDoNotMatch()
        tests.testOtherEventTypeDoesNotMatch()
        tests.testMalformedKeyStateDoesNotMatch()
        tests.testMetadataPreservesDirectionAndOriginalTimestamp()
        tests.testRepeatedDownKeyKeepsDirectionAndTimestamp()
        tests.testUnreliableTimestampDoesNotSuppressBrightnessKey()
        print("NativeBrightnessKeyMonitor: 11 checks, \(keyFailures) failures")
        if keyFailures > 0 { exit(1) }
    }
}
#endif

#if canImport(XCTest) || BRIGHTNESS_KEY_STANDALONE
final class NativeBrightnessKeyMonitorTests: XCTestCase {
    private func mediaEvent(key: Int, state: Int = 0xA, repeated: Bool = false,
                            type: NSEvent.EventType = .systemDefined, subtype: Int16 = 8,
                            timestamp: TimeInterval = 0) -> NSEvent {
        NSEvent.otherEvent(with: type, location: .zero, modifierFlags: [], timestamp: timestamp,
                          windowNumber: 0, context: nil, subtype: subtype,
                          data1: (key << 16) | (state << 8) | (repeated ? 1 : 0), data2: -1)!
    }

    func testBothScreenBrightnessKeyDownsMatch() {
        XCTAssertTrue(NativeBrightnessKeyMonitor.isBrightnessKey(mediaEvent(key: 2)))
        XCTAssertTrue(NativeBrightnessKeyMonitor.isBrightnessKey(mediaEvent(key: 3)))
    }

    func testRepeatKeyDownMatches() {
        XCTAssertTrue(NativeBrightnessKeyMonitor.isBrightnessKey(mediaEvent(key: 2, repeated: true)))
        XCTAssertTrue(NativeBrightnessKeyMonitor.isBrightnessKey(mediaEvent(key: 3, repeated: true)))
    }

    func testKeyUpDoesNotMatch() {
        XCTAssertFalse(NativeBrightnessKeyMonitor.isBrightnessKey(mediaEvent(key: 2, state: 0xB)))
        XCTAssertFalse(NativeBrightnessKeyMonitor.isBrightnessKey(mediaEvent(key: 3, state: 0xB)))
    }

    func testWrongSubtypeDoesNotMatch() {
        XCTAssertFalse(NativeBrightnessKeyMonitor.isBrightnessKey(mediaEvent(key: 2, subtype: 0)))
        XCTAssertFalse(NativeBrightnessKeyMonitor.isBrightnessKey(mediaEvent(key: 3, subtype: 7)))
    }

    func testVolumeMediaAndKeyboardIlluminationDoNotMatch() {
        for code in [0, 1, 7, 16, 17, 18, 21, 22] {
            XCTAssertFalse(NativeBrightnessKeyMonitor.isBrightnessKey(mediaEvent(key: code)))
        }
    }

    func testOrdinaryLettersAndFunctionKeysDoNotMatch() {
        for code: UInt16 in [0, 11, 122, 120] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                         isARepeat: false, keyCode: code)!
            XCTAssertFalse(NativeBrightnessKeyMonitor.isBrightnessKey(event))
        }
    }

    func testOtherEventTypeDoesNotMatch() {
        XCTAssertFalse(NativeBrightnessKeyMonitor.isBrightnessKey(mediaEvent(key: 2, type: .applicationDefined)))
    }

    func testMalformedKeyStateDoesNotMatch() {
        for state in [0, 1, 9, 12, 255] {
            XCTAssertFalse(NativeBrightnessKeyMonitor.isBrightnessKey(mediaEvent(key: 2, state: state)))
        }
        XCTAssertFalse(NativeBrightnessKeyMonitor.isBrightnessKey(mediaEvent(key: 65535)))
    }

    func testMetadataPreservesDirectionAndOriginalTimestamp() {
        let up = NativeBrightnessKeyMonitor.brightnessKeyPress(mediaEvent(key: 2, timestamp: 123.25))
        let down = NativeBrightnessKeyMonitor.brightnessKeyPress(mediaEvent(key: 3, timestamp: 124.75))
        XCTAssertEqual(up, BrightnessKeyPress(direction: .increase, timestamp: 123.25))
        XCTAssertEqual(down, BrightnessKeyPress(direction: .decrease, timestamp: 124.75))
        XCTAssertEqual(NativeBrightnessKeyMonitor.brightnessKeyPress(mediaEvent(key: 3, state: 0xB)), nil)
    }

    func testRepeatedDownKeyKeepsDirectionAndTimestamp() {
        let repeated = NativeBrightnessKeyMonitor.brightnessKeyPress(
            mediaEvent(key: 3, repeated: true, timestamp: 901.125)
        )
        XCTAssertEqual(repeated, BrightnessKeyPress(direction: .decrease, timestamp: 901.125))
    }

    func testUnreliableTimestampDoesNotSuppressBrightnessKey() {
        for timestamp in [0.0, -1.0] {
            let key = NativeBrightnessKeyMonitor.brightnessKeyPress(mediaEvent(key: 2, timestamp: timestamp))
            XCTAssertEqual(key?.direction, .increase)
            XCTAssertEqual(key?.timestamp, timestamp)
        }
    }
}
#endif
