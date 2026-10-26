import AppKit
import Carbon
#if canImport(XCTest) && !BRIGHTNESS_SHORTCUT_STANDALONE
import XCTest
@testable import BatteryCycle
#elseif BRIGHTNESS_SHORTCUT_STANDALONE
private var shortcutFailures = 0
private func XCTAssertTrue(_ value: Bool) { if !value { shortcutFailures += 1; print("FAIL: expected true") } }
private func XCTAssertFalse(_ value: Bool) { if value { shortcutFailures += 1; print("FAIL: expected false") } }
class XCTestCase {}
@main private struct BrightnessShortcutTestRunner {
    static func main() {
        let tests = BrightnessRestoreShortcutTests()
        tests.testExactRestorationChordMatches()
        tests.testMissingModifiersDoNotMatch()
        tests.testOtherKeyDoesNotMatch()
        tests.testAdditionalShiftOrFunctionDoesNotMatch()
        tests.testCapsLockDoesNotPreventRestoration()
        tests.testKeyUpAndRepeatDoNotMatch()
        print("BrightnessRestoreShortcut: 6 checks, \(shortcutFailures) failures")
        if shortcutFailures > 0 { exit(1) }
    }
}
#endif

#if canImport(XCTest) || BRIGHTNESS_SHORTCUT_STANDALONE
final class BrightnessRestoreShortcutTests: XCTestCase {
    private let chord: NSEvent.ModifierFlags = [.control, .option, .command]

    private func event(_ modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = UInt16(kVK_ANSI_B),
                       type: NSEvent.EventType = .keyDown, repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: "b", charactersIgnoringModifiers: "b",
                         isARepeat: repeated, keyCode: keyCode)!
    }

    func testExactRestorationChordMatches() {
        XCTAssertTrue(BrightnessRestoreShortcut.matches(event(chord)))
    }

    func testMissingModifiersDoNotMatch() {
        for modifier: NSEvent.ModifierFlags in [.control, .option, .command] {
            XCTAssertFalse(BrightnessRestoreShortcut.matches(event(chord.subtracting(modifier))))
        }
        XCTAssertFalse(BrightnessRestoreShortcut.matches(event([])))
    }

    func testOtherKeyDoesNotMatch() {
        XCTAssertFalse(BrightnessRestoreShortcut.matches(event(chord, keyCode: UInt16(kVK_ANSI_A))))
    }

    func testAdditionalShiftOrFunctionDoesNotMatch() {
        XCTAssertFalse(BrightnessRestoreShortcut.matches(event(chord.union(.shift))))
        XCTAssertFalse(BrightnessRestoreShortcut.matches(event(chord.union(.function))))
    }

    func testCapsLockDoesNotPreventRestoration() {
        XCTAssertTrue(BrightnessRestoreShortcut.matches(event(chord.union(.capsLock))))
    }

    func testKeyUpAndRepeatDoNotMatch() {
        XCTAssertFalse(BrightnessRestoreShortcut.matches(event(chord, type: .keyUp)))
        XCTAssertFalse(BrightnessRestoreShortcut.matches(event(chord, repeated: true)))
    }
}
#endif
