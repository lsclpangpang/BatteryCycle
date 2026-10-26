import Foundation
#if canImport(XCTest) && !BRIGHTNESS_STANDALONE
import XCTest
@testable import BatteryCycle
#elseif BRIGHTNESS_STANDALONE
private var brightnessFailures = 0
private func XCTAssertTrue(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value() { brightnessFailures += 1; print("FAIL \(file):\(line): expected true") }
}
private func XCTAssertFalse(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(!value(), file: file, line: line)
}
private func XCTAssertEqual<T: Equatable>(_ left: @autoclosure () -> T, _ right: @autoclosure () -> T,
                                          file: StaticString = #filePath, line: UInt = #line) {
    let a = left(), b = right()
    if a != b { brightnessFailures += 1; print("FAIL \(file):\(line): \(a) != \(b)") }
}
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T,
                                     file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); brightnessFailures += 1; print("FAIL \(file):\(line): expected error") }
    catch {}
}
class XCTestCase {}

@main
private struct BrightnessTestRunner {
    static func main() throws {
        let tests = BrightnessSessionTests()
        try tests.testEnableVerifiesAutoOffBeforeSettingMinimumAndRestoresOriginal()
        try tests.testOriginallyDisabledAutomaticBrightnessStaysDisabled()
        try tests.testRepeatedEnableAndEnforcementNeverReplaceOriginal()
        try tests.testExternalBrightnessAndAutoChangesAreCorrected()
        try tests.testQuietEnforcementDoesNotWriteHardware()
        try tests.testEnableWritesExactMinimumEvenWithinReadbackTolerance()
        try tests.testStoreFailureNeverWritesHardware()
        try tests.testUnreadableJournalBlocksEnable()
        try tests.testPendingRecoveryBlocksNewEnable()
        try tests.testStaleDisplayIdentityNeverWritesHardware()
        try tests.testAutomaticBrightnessRefusesToDisableAndRollsBack()
        try tests.testBrightnessWriteFailureRollsBackAutomaticBrightness()
        try tests.testSuccessfulSetterWithWrongReadbackIsNotAccepted()
        try tests.testEnforcementFailureTurnsOffAndRestores()
        try tests.testRestoreFailureAttemptsBothSettingsAndKeepsJournal()
        try tests.testRestoreAutoFailureKeepsJournalForRetry()
        try tests.testJournalClearFailureCanBeRetried()
        try tests.testStartupRecoversWithoutReenablingMinimum()
        try tests.testNoJournalRecoveryDoesNotTouchHardware()
        try tests.testAutomaticBrightnessMayAdjustImmediatelyAfterRestore()
        try tests.testInvalidSnapshotsNeverWriteHardware()
        try tests.testCorruptSavedSnapshotBlocksNewEnable()
        try tests.testTransientRecoveryReadFailureCanBeRetried()
        try tests.testDisplayDisappearingDuringLockRetainsRecovery()
        try tests.testJournalRemovalRetryDoesNotOverwriteLaterUserAdjustment()
        try tests.testUncertainSaveOutcomeIsRecoveredBeforeAnotherEnable()
        try tests.testAutoBrightnessReenabledDuringMinimumWriteFailsClosed()
        try tests.testIgnoredRestoreKeepsJournalAndStillRestoresAuto()
        try tests.testManualHandoffDoesNotWriteBrightness()
        try tests.testManualHandoffCrashRecoveryKeepsNewBrightness()
        try tests.testManualHandoffKeepsOriginallyDisabledAutoBrightness()
        try tests.testManualHandoffClearFailureRetryKeepsNewBrightness()
        try tests.testManualHandoffSaveFailureStopsEnforcementAndRestoresAutoBrightness()
        try tests.testManualHandoffSaveAndClearFailureNeverRestoresBrightnessInProcess()
        try tests.testManualHandoffAutoRestoreFailureKeepsHandoffRecord()
        try tests.testLateManualFinishDoesNotCancelNewLock()
        try tests.testRepeatedManualBeginPreservesHandoffRecord()
        try tests.testDelayedKeyRecoversOnlyTheOverwrittenKeyValue()
        try tests.testLaterSystemKeyValueWinsOverCompensation()
        try tests.testDecreaseAfterIncreaseCancelsCompensation()
        try tests.testOldDriftIsNotMistakenForTheNewKey()
        try tests.testKeyInsideReadWriteGapDoesNotUsePreKeyValue()
        try tests.testCompensationDoesNotSurviveNewSession()
        try tests.testFailedHandoffSaveDoesNotCompensate()
        try tests.testCompensationFailureDoesNotReplayAfterUserAdjustment()
        try tests.testFailedInitialCorrectionReadIsNotRetried()
        try tests.testExpiredKeyDoesNotCompensate()
        try tests.testAutomaticBrightnessValueIsNeverAKeyCompensation()
        try tests.testCompensationExpiresBeforeDelayedFinish()
        print("BrightnessSession: 49 checks, \(brightnessFailures) failures")
        if brightnessFailures > 0 { exit(1) }
    }
}
#endif

#if canImport(XCTest) || BRIGHTNESS_STANDALONE
final class BrightnessSessionTests: XCTestCase {
    private func fixture(auto: Bool = true) -> (MinimumBrightnessSession, FakeBrightnessBackend, FakeBrightnessStore) {
        let backend = FakeBrightnessBackend(automatic: auto)
        let store = FakeBrightnessStore()
        return (MinimumBrightnessSession(backend: backend, store: store), backend, store)
    }

    func testEnableVerifiesAutoOffBeforeSettingMinimumAndRestoresOriginal() throws {
        let (session, backend, store) = fixture()
        backend.beforeWrite = { XCTAssertTrue(store.saved != nil) }
        try session.enable()
        XCTAssertTrue(session.isEnabled)
        XCTAssertFalse(session.needsRecovery)
        XCTAssertEqual(backend.brightness, 0)
        XCTAssertFalse(backend.automatic)
        XCTAssertEqual(backend.writes, ["auto:false", "brightness:0.0"])
        XCTAssertTrue(backend.sawAutoDisabledBeforeMinimum)
        try session.disable()
        XCTAssertFalse(session.isEnabled)
        XCTAssertFalse(session.needsRecovery)
        XCTAssertEqual(backend.brightness, 0.65)
        XCTAssertTrue(backend.automatic)
        XCTAssertEqual(store.saved, nil)
    }

    func testOriginallyDisabledAutomaticBrightnessStaysDisabled() throws {
        let (session, backend, _) = fixture(auto: false)
        try session.enable()
        try session.disable()
        XCTAssertFalse(backend.automatic)
        XCTAssertEqual(backend.brightness, 0.65)
    }

    func testRepeatedEnableAndEnforcementNeverReplaceOriginal() throws {
        let (session, backend, store) = fixture()
        try session.enable()
        try session.enable()
        backend.brightness = 0.8
        try session.enforce()
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.saved?.brightness, 0.65)
        try session.disable()
        XCTAssertEqual(backend.brightness, 0.65)
    }

    func testExternalBrightnessAndAutoChangesAreCorrected() throws {
        let (session, backend, _) = fixture()
        try session.enable()
        backend.brightness = 0.8
        backend.automatic = true
        try session.enforce()
        XCTAssertTrue(session.isEnabled)
        XCTAssertEqual(backend.brightness, 0)
        XCTAssertFalse(backend.automatic)
    }

    func testQuietEnforcementDoesNotWriteHardware() throws {
        let (session, backend, _) = fixture()
        try session.enable()
        let writes = backend.writes
        for _ in 0..<10 { try session.enforce() }
        XCTAssertEqual(backend.writes, writes)
    }

    func testEnableWritesExactMinimumEvenWithinReadbackTolerance() throws {
        let (session, backend, _) = fixture(auto: false)
        backend.brightness = 0.001
        try session.enable()
        XCTAssertTrue(session.isEnabled)
        XCTAssertEqual(backend.brightness, 0)
        XCTAssertEqual(backend.writes, ["brightness:0.0"])
        try session.disable()
        XCTAssertEqual(backend.brightness, 0.001)
    }

    func testStoreFailureNeverWritesHardware() throws {
        let (session, backend, store) = fixture()
        store.failSave = true
        XCTAssertThrowsError(try session.enable())
        XCTAssertEqual(backend.writes, [])
        XCTAssertFalse(session.isEnabled)
        store.failSave = false
        try session.recover()
        try session.enable()
        XCTAssertTrue(session.isEnabled)
    }

    func testUnreadableJournalBlocksEnable() throws {
        let (session, backend, store) = fixture()
        store.failLoad = true
        XCTAssertThrowsError(try session.enable())
        XCTAssertTrue(session.needsRecovery)
        XCTAssertEqual(backend.writes, [])
        XCTAssertEqual(store.saveCount, 0)
    }

    func testPendingRecoveryBlocksNewEnable() throws {
        let (session, backend, store) = fixture()
        store.saved = BrightnessRecoveryRecord(snapshot: backend.current)
        XCTAssertThrowsError(try session.enable())
        XCTAssertEqual(backend.writes, [])
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertTrue(session.needsRecovery)
    }

    func testStaleDisplayIdentityNeverWritesHardware() throws {
        let (session, backend, store) = fixture()
        store.saved = BrightnessRecoveryRecord(displayID: "another-panel", brightness: 0.4, automaticBrightness: true)
        XCTAssertThrowsError(try session.recover())
        XCTAssertEqual(backend.writes, [])
        XCTAssertTrue(session.needsRecovery)
        XCTAssertTrue(store.saved != nil)
    }

    func testAutomaticBrightnessRefusesToDisableAndRollsBack() throws {
        let (session, backend, store) = fixture()
        backend.ignoreAutoDisable = true
        XCTAssertThrowsError(try session.enable())
        XCTAssertFalse(session.isEnabled)
        XCTAssertFalse(backend.writes.contains("brightness:0.0"))
        XCTAssertTrue(backend.automatic)
        XCTAssertEqual(store.saved, nil)
    }

    func testBrightnessWriteFailureRollsBackAutomaticBrightness() throws {
        let (session, backend, store) = fixture()
        backend.failMinimum = true
        XCTAssertThrowsError(try session.enable())
        XCTAssertFalse(session.isEnabled)
        XCTAssertTrue(backend.automatic)
        XCTAssertEqual(backend.brightness, 0.65)
        XCTAssertEqual(store.saved, nil)
    }

    func testSuccessfulSetterWithWrongReadbackIsNotAccepted() throws {
        let (session, backend, _) = fixture()
        backend.ignoreMinimum = true
        XCTAssertThrowsError(try session.enable())
        XCTAssertFalse(session.isEnabled)
        XCTAssertTrue(backend.automatic)
    }

    func testEnforcementFailureTurnsOffAndRestores() throws {
        let (session, backend, _) = fixture()
        try session.enable()
        backend.brightness = 0.9
        backend.failMinimum = true
        XCTAssertThrowsError(try session.enforce())
        XCTAssertFalse(session.isEnabled)
        XCTAssertFalse(session.needsRecovery)
        XCTAssertEqual(backend.brightness, 0.65)
        XCTAssertTrue(backend.automatic)
    }

    func testRestoreFailureAttemptsBothSettingsAndKeepsJournal() throws {
        let (session, backend, store) = fixture()
        try session.enable()
        backend.failRestoreBrightness = true
        XCTAssertThrowsError(try session.disable())
        XCTAssertFalse(session.isEnabled)
        XCTAssertTrue(session.needsRecovery)
        XCTAssertTrue(backend.automatic)
        XCTAssertTrue(store.saved != nil)
        backend.failRestoreBrightness = false
        try session.recover()
        XCTAssertEqual(backend.brightness, 0.65)
        XCTAssertEqual(store.saved, nil)
    }

    func testRestoreAutoFailureKeepsJournalForRetry() throws {
        let (session, backend, store) = fixture()
        try session.enable()
        backend.failAutoEnable = true
        XCTAssertThrowsError(try session.disable())
        XCTAssertEqual(backend.brightness, 0.65)
        XCTAssertTrue(session.needsRecovery)
        XCTAssertTrue(store.saved != nil)
        backend.failAutoEnable = false
        try session.recover()
        XCTAssertTrue(backend.automatic)
        XCTAssertFalse(session.needsRecovery)
    }

    func testJournalClearFailureCanBeRetried() throws {
        let (session, backend, store) = fixture()
        try session.enable()
        store.failClear = true
        XCTAssertThrowsError(try session.disable())
        XCTAssertTrue(session.needsRecovery)
        XCTAssertEqual(backend.brightness, 0.65)
        XCTAssertTrue(backend.automatic)
        XCTAssertThrowsError(try session.enable())
        store.failClear = false
        try session.recover()
        XCTAssertFalse(session.needsRecovery)
    }

    func testStartupRecoversWithoutReenablingMinimum() throws {
        let backend = FakeBrightnessBackend()
        let store = FakeBrightnessStore()
        let first = MinimumBrightnessSession(backend: backend, store: store)
        try first.enable()
        let restarted = MinimumBrightnessSession(backend: backend, store: store)
        try restarted.recover()
        XCTAssertFalse(restarted.isEnabled)
        XCTAssertFalse(restarted.needsRecovery)
        XCTAssertEqual(backend.brightness, 0.65)
        XCTAssertTrue(backend.automatic)
    }

    func testNoJournalRecoveryDoesNotTouchHardware() throws {
        let (session, backend, _) = fixture()
        backend.failRead = true
        try session.recover()
        XCTAssertFalse(session.needsRecovery)
        XCTAssertEqual(backend.readCount, 0)
        XCTAssertEqual(backend.writes, [])
    }

    func testAutomaticBrightnessMayAdjustImmediatelyAfterRestore() throws {
        let (session, backend, store) = fixture()
        try session.enable()
        backend.adjustOnAutoEnable = true
        try session.disable()
        XCTAssertFalse(session.needsRecovery)
        XCTAssertEqual(store.saved, nil)
        XCTAssertEqual(backend.brightness, 0.88)
        XCTAssertTrue(backend.automatic)
    }

    func testInvalidSnapshotsNeverWriteHardware() throws {
        for invalid in [Float.nan, Float.infinity, -0.1, 1.1] {
            let (session, backend, store) = fixture()
            backend.brightness = invalid
            XCTAssertThrowsError(try session.enable())
            XCTAssertEqual(backend.writes, [])
            XCTAssertEqual(store.saveCount, 0)
        }
    }

    func testCorruptSavedSnapshotBlocksNewEnable() throws {
        let (session, backend, store) = fixture()
        store.saved = BrightnessRecoveryRecord(displayID: "", brightness: 0.5, automaticBrightness: true)
        XCTAssertThrowsError(try session.recover())
        XCTAssertThrowsError(try session.enable())
        XCTAssertTrue(session.needsRecovery)
        XCTAssertEqual(backend.writes, [])
        XCTAssertEqual(store.saveCount, 0)
    }

    func testTransientRecoveryReadFailureCanBeRetried() throws {
        let (session, backend, store) = fixture()
        store.failLoad = true
        XCTAssertThrowsError(try session.recover())
        store.failLoad = false
        try session.recover()
        try session.enable()
        XCTAssertTrue(session.isEnabled)
        XCTAssertEqual(backend.brightness, 0)
    }

    func testDisplayDisappearingDuringLockRetainsRecovery() throws {
        let (session, backend, store) = fixture()
        try session.enable()
        backend.failRead = true
        XCTAssertThrowsError(try session.enforce())
        XCTAssertFalse(session.isEnabled)
        XCTAssertTrue(session.needsRecovery)
        XCTAssertTrue(store.saved != nil)
        backend.failRead = false
        try session.recover()
        XCTAssertFalse(session.needsRecovery)
    }

    func testJournalRemovalRetryDoesNotOverwriteLaterUserAdjustment() throws {
        let (session, backend, store) = fixture()
        try session.enable()
        store.failClear = true
        XCTAssertThrowsError(try session.disable())
        let writes = backend.writes
        backend.brightness = 0.3
        store.failClear = false
        try session.recover()
        XCTAssertEqual(backend.brightness, 0.3)
        XCTAssertEqual(backend.writes, writes)
        XCTAssertFalse(session.needsRecovery)
    }

    func testUncertainSaveOutcomeIsRecoveredBeforeAnotherEnable() throws {
        let (session, backend, store) = fixture()
        store.saveThenThrow = true
        XCTAssertThrowsError(try session.enable())
        XCTAssertEqual(backend.writes, [])
        XCTAssertTrue(store.saved != nil)
        XCTAssertThrowsError(try session.enable())
        XCTAssertEqual(store.saveCount, 1)
        try session.recover()
        XCTAssertFalse(session.needsRecovery)
        XCTAssertEqual(store.saved, nil)
    }

    func testAutoBrightnessReenabledDuringMinimumWriteFailsClosed() throws {
        let (session, backend, store) = fixture()
        backend.reenableAutoOnMinimum = true
        XCTAssertThrowsError(try session.enable())
        XCTAssertFalse(session.isEnabled)
        XCTAssertEqual(backend.brightness, 0.65)
        XCTAssertTrue(backend.automatic)
        XCTAssertEqual(store.saved, nil)
    }

    func testIgnoredRestoreKeepsJournalAndStillRestoresAuto() throws {
        let (session, backend, store) = fixture()
        try session.enable()
        backend.ignoreRestoreBrightness = true
        XCTAssertThrowsError(try session.disable())
        XCTAssertFalse(session.isEnabled)
        XCTAssertTrue(session.needsRecovery)
        XCTAssertTrue(backend.automatic)
        XCTAssertTrue(store.saved != nil)
    }

    func testManualHandoffDoesNotWriteBrightness() throws {
        let (session, backend, store) = fixture()
        try session.enable()
        let writes = backend.writes
        try session.beginManualAdjustment()
        XCTAssertFalse(session.isEnabled)
        XCTAssertEqual(backend.writes, writes)
        XCTAssertEqual(store.saved?.restoresBrightness, false)
        backend.brightness = 0.15 // The system handles the actual brightness key.
        try session.enforce()
        XCTAssertEqual(backend.brightness, 0.15)
        try session.finishManualAdjustment()
        XCTAssertEqual(backend.brightness, 0.15)
        XCTAssertEqual(backend.writes, writes + ["auto:true"])
        XCTAssertEqual(store.saved, nil)
        XCTAssertFalse(session.needsRecovery)
    }

    func testManualHandoffCrashRecoveryKeepsNewBrightness() throws {
        let (session, backend, store) = fixture()
        try session.enable()
        try session.beginManualAdjustment()
        backend.brightness = 0.2
        let writes = backend.writes
        let restarted = MinimumBrightnessSession(backend: backend, store: store)
        try restarted.recover()
        XCTAssertEqual(backend.brightness, 0.2)
        XCTAssertEqual(backend.writes, writes + ["auto:true"])
        XCTAssertFalse(restarted.isEnabled)
        XCTAssertFalse(restarted.needsRecovery)
    }

    func testManualHandoffKeepsOriginallyDisabledAutoBrightness() throws {
        let (session, backend, store) = fixture(auto: false)
        try session.enable()
        try session.beginManualAdjustment()
        backend.brightness = 0.25
        let writes = backend.writes
        try session.finishManualAdjustment()
        XCTAssertFalse(backend.automatic)
        XCTAssertEqual(backend.brightness, 0.25)
        XCTAssertEqual(backend.writes, writes + ["auto:false"])
        XCTAssertEqual(store.saved, nil)
    }

    func testManualHandoffClearFailureRetryKeepsNewBrightness() throws {
        let (session, backend, store) = fixture()
        try session.enable()
        try session.beginManualAdjustment()
        backend.brightness = 0.3
        store.failClear = true
        XCTAssertThrowsError(try session.finishManualAdjustment())
        XCTAssertTrue(session.needsRecovery)
        XCTAssertEqual(store.saved?.restoresBrightness, false)
        let writes = backend.writes
        backend.brightness = 0.4
        store.failClear = false
        try session.recover()
        XCTAssertEqual(backend.brightness, 0.4)
        XCTAssertEqual(backend.writes, writes)
    }

    func testManualHandoffSaveFailureStopsEnforcementAndRestoresAutoBrightness() throws {
        let (session, backend, store) = fixture()
        try session.enable()
        let writes = backend.writes
        backend.brightness = 0.2
        store.failSave = true
        XCTAssertThrowsError(try session.beginManualAdjustment())
        XCTAssertFalse(session.isEnabled)
        XCTAssertTrue(backend.automatic)
        XCTAssertEqual(backend.brightness, 0.2)
        XCTAssertEqual(backend.writes, writes + ["auto:true"])
        XCTAssertEqual(store.saved, nil)
        try session.enforce()
        XCTAssertEqual(backend.brightness, 0.2)
    }

    func testManualHandoffSaveAndClearFailureNeverRestoresBrightnessInProcess() throws {
        let (session, backend, store) = fixture()
        try session.enable()
        let writes = backend.writes
        store.failSave = true
        store.failClear = true
        XCTAssertThrowsError(try session.beginManualAdjustment())
        XCTAssertFalse(session.isEnabled)
        XCTAssertTrue(session.needsRecovery)
        backend.brightness = 0.3
        XCTAssertThrowsError(try session.disable())
        XCTAssertEqual(backend.brightness, 0.3)
        store.failClear = false
        try session.recover()
        XCTAssertEqual(backend.brightness, 0.3)
        XCTAssertEqual(backend.writes, writes + ["auto:true"])
    }

    func testManualHandoffAutoRestoreFailureKeepsHandoffRecord() throws {
        let (session, backend, store) = fixture()
        try session.enable()
        try session.beginManualAdjustment()
        backend.brightness = 0.2
        backend.failAutoEnable = true
        XCTAssertThrowsError(try session.finishManualAdjustment())
        XCTAssertTrue(session.needsRecovery)
        XCTAssertEqual(store.saved?.restoresBrightness, false)
        XCTAssertEqual(backend.brightness, 0.2)
        backend.failAutoEnable = false
        try session.recover()
        XCTAssertEqual(backend.brightness, 0.2)
        XCTAssertTrue(backend.automatic)
    }

    func testLateManualFinishDoesNotCancelNewLock() throws {
        let (session, backend, _) = fixture()
        try session.enable()
        try session.beginManualAdjustment()
        try session.finishManualAdjustment()
        backend.brightness = 0.3
        try session.enable()
        let writes = backend.writes
        try session.finishManualAdjustment()
        XCTAssertTrue(session.isEnabled)
        XCTAssertEqual(backend.writes, writes)
        XCTAssertEqual(backend.brightness, 0)
    }

    func testRepeatedManualBeginPreservesHandoffRecord() throws {
        let (session, backend, store) = fixture()
        try session.enable()
        try session.beginManualAdjustment()
        backend.brightness = 0.2
        try session.beginManualAdjustment()
        XCTAssertEqual(store.saveCount, 2)
        XCTAssertEqual(store.saved?.brightness, 0.65)
        XCTAssertEqual(store.saved?.restoresBrightness, false)
    }
    private func raceFixture() throws -> (MinimumBrightnessSession, FakeBrightnessBackend, FakeBrightnessStore, TestUptime) {
        let backend = FakeBrightnessBackend()
        let store = FakeBrightnessStore()
        let time = TestUptime()
        let session = MinimumBrightnessSession(backend: backend, store: store, uptime: { time.value })
        try session.enable()
        time.value = 11
        backend.brightness = 0.0625
        try session.enforce()
        XCTAssertEqual(backend.brightness, 0)
        time.value = 11.1
        return (session, backend, store, time)
    }

    func testDelayedKeyRecoversOnlyTheOverwrittenKeyValue() throws {
        let (session, backend, store, _) = try raceFixture()
        try session.beginManualAdjustment(keyTimestamp: 10.99, increasesBrightness: true)
        XCTAssertEqual(backend.brightness, 0)
        backend.beforeWrite = { XCTAssertEqual(store.saved?.restoresBrightness, false) }
        try session.finishManualAdjustment()
        XCTAssertEqual(backend.brightness, 0.0625)
        XCTAssertEqual(backend.automatic, true)
        XCTAssertEqual(store.saved, nil)
        XCTAssertFalse(backend.writes.contains("brightness:0.65"))
    }

    func testLaterSystemKeyValueWinsOverCompensation() throws {
        let (session, backend, _, _) = try raceFixture()
        try session.beginManualAdjustment(keyTimestamp: 10.99, increasesBrightness: true)
        backend.brightness = 0.125
        let writes = backend.writes
        try session.finishManualAdjustment()
        XCTAssertEqual(backend.brightness, 0.125)
        XCTAssertEqual(backend.writes, writes + ["auto:true"])
    }

    func testDecreaseAfterIncreaseCancelsCompensation() throws {
        let (session, backend, _, _) = try raceFixture()
        try session.beginManualAdjustment(keyTimestamp: 10.99, increasesBrightness: true)
        try session.beginManualAdjustment(keyTimestamp: 11.1, increasesBrightness: false)
        try session.finishManualAdjustment()
        XCTAssertEqual(backend.brightness, 0)
        XCTAssertFalse(backend.writes.contains("brightness:0.0625"))
    }

    func testOldDriftIsNotMistakenForTheNewKey() throws {
        let (session, backend, _, _) = try raceFixture()
        try session.beginManualAdjustment(keyTimestamp: 11.05, increasesBrightness: true)
        try session.finishManualAdjustment()
        XCTAssertEqual(backend.brightness, 0)
        XCTAssertFalse(backend.writes.contains("brightness:0.0625"))
    }

    func testKeyInsideReadWriteGapDoesNotUsePreKeyValue() throws {
        let backend = FakeBrightnessBackend()
        let time = TestUptime()
        let session = MinimumBrightnessSession(backend: backend, store: FakeBrightnessStore(), uptime: { time.value })
        try session.enable()
        time.value = 11
        backend.brightness = 0.4
        backend.beforeWrite = { time.value = 11.02 }
        try session.enforce()
        time.value = 11.1
        try session.beginManualAdjustment(keyTimestamp: 11.01, increasesBrightness: true)
        try session.finishManualAdjustment()
        XCTAssertEqual(backend.brightness, 0)
        XCTAssertFalse(backend.writes.contains("brightness:0.4"))
    }

    func testCompensationDoesNotSurviveNewSession() throws {
        let (session, backend, _, time) = try raceFixture()
        try session.disable()
        time.value = 12
        try session.enable()
        try session.beginManualAdjustment(keyTimestamp: 10.99, increasesBrightness: true)
        try session.finishManualAdjustment()
        XCTAssertEqual(backend.brightness, 0)
    }

    func testFailedHandoffSaveDoesNotCompensate() throws {
        let (session, backend, store, _) = try raceFixture()
        store.failSave = true
        XCTAssertThrowsError(try session.beginManualAdjustment(keyTimestamp: 10.99, increasesBrightness: true))
        XCTAssertFalse(session.isEnabled)
        XCTAssertEqual(backend.brightness, 0)
        XCTAssertFalse(backend.writes.contains("brightness:0.0625"))
    }

    func testCompensationFailureDoesNotReplayAfterUserAdjustment() throws {
        let (session, backend, _, _) = try raceFixture()
        try session.beginManualAdjustment(keyTimestamp: 10.99, increasesBrightness: true)
        backend.failRestoreBrightness = true
        XCTAssertThrowsError(try session.finishManualAdjustment())
        backend.brightness = 0.3
        backend.failRestoreBrightness = false
        let writes = backend.writes
        try session.recover()
        XCTAssertEqual(backend.brightness, 0.3)
        XCTAssertEqual(backend.writes, writes + ["auto:true"])
    }

    func testFailedInitialCorrectionReadIsNotRetried() throws {
        let (session, backend, _, _) = try raceFixture()
        try session.beginManualAdjustment(keyTimestamp: 10.99, increasesBrightness: true)
        backend.failRead = true
        XCTAssertThrowsError(try session.finishManualAdjustment())
        backend.failRead = false
        backend.brightness = 0 // A later intentional down key, while monitoring has stopped.
        try session.recover()
        XCTAssertEqual(backend.brightness, 0)
        XCTAssertFalse(backend.writes.contains("brightness:0.0625"))
    }
    func testExpiredKeyDoesNotCompensate() throws {
        let (session, backend, _, time) = try raceFixture()
        time.value = 14
        try session.beginManualAdjustment(keyTimestamp: 10.99, increasesBrightness: true)
        try session.finishManualAdjustment()
        XCTAssertEqual(backend.brightness, 0)
    }

    func testAutomaticBrightnessValueIsNeverAKeyCompensation() throws {
        let (session, backend, _, time) = try raceFixture()
        time.value = 11.2
        backend.automatic = true
        backend.brightness = 0.8
        try session.enforce()
        time.value = 11.3
        try session.beginManualAdjustment(keyTimestamp: 11.19, increasesBrightness: true)
        try session.finishManualAdjustment()
        XCTAssertEqual(backend.brightness, 0)
        XCTAssertFalse(backend.writes.contains("brightness:0.8"))
    }

    func testCompensationExpiresBeforeDelayedFinish() throws {
        let (session, backend, _, time) = try raceFixture()
        try session.beginManualAdjustment(keyTimestamp: 10.99, increasesBrightness: true)
        time.value = 14
        try session.finishManualAdjustment()
        XCTAssertEqual(backend.brightness, 0)
    }
}

private final class TestUptime { var value: TimeInterval = 10 }

private enum FakeBrightnessError: Error { case failed }

private final class FakeBrightnessBackend: BrightnessBackend {
    var brightness: Float = 0.65
    var automatic: Bool
    var writes: [String] = []
    var readCount = 0
    var beforeWrite: (() -> Void)?
    var failRead = false
    var failMinimum = false
    var ignoreMinimum = false
    var failRestoreBrightness = false
    var ignoreRestoreBrightness = false
    var ignoreAutoDisable = false
    var failAutoEnable = false
    var adjustOnAutoEnable = false
    var reenableAutoOnMinimum = false
    var sawAutoDisabledBeforeMinimum = false
    private var readAutoDisabled = false
    init(automatic: Bool = true) { self.automatic = automatic }
    var current: BrightnessSnapshot {
        BrightnessSnapshot(displayID: "built-in-panel", brightness: brightness, automaticBrightness: automatic)
    }
    func snapshot() throws -> BrightnessSnapshot {
        readCount += 1
        if failRead { throw FakeBrightnessError.failed }
        if !automatic { readAutoDisabled = true }
        return current
    }
    func setBrightness(_ value: Float, displayID: String) throws {
        beforeWrite?()
        XCTAssertEqual(displayID, "built-in-panel")
        writes.append("brightness:\(value)")
        if value == 0 {
            sawAutoDisabledBeforeMinimum = readAutoDisabled && !automatic
            if failMinimum { throw FakeBrightnessError.failed }
            if ignoreMinimum { return }
        } else {
            if failRestoreBrightness { throw FakeBrightnessError.failed }
            if ignoreRestoreBrightness { return }
        }
        brightness = value
        if value == 0 && reenableAutoOnMinimum { automatic = true }
    }
    func setAutomaticBrightness(_ enabled: Bool, displayID: String) throws {
        beforeWrite?()
        XCTAssertEqual(displayID, "built-in-panel")
        writes.append("auto:\(enabled)")
        if enabled && failAutoEnable { throw FakeBrightnessError.failed }
        if !enabled && ignoreAutoDisable { return }
        automatic = enabled
        if enabled && adjustOnAutoEnable { brightness = 0.88 }
    }
}

private final class FakeBrightnessStore: BrightnessRecoveryStore {
    var saved: BrightnessRecoveryRecord?
    var saveCount = 0
    var failLoad = false
    var failSave = false
    var failClear = false
    var saveThenThrow = false
    func load() throws -> BrightnessRecoveryRecord? {
        if failLoad { throw FakeBrightnessError.failed }
        return saved
    }
    func save(_ record: BrightnessRecoveryRecord) throws {
        if failSave { throw FakeBrightnessError.failed }
        saveCount += 1
        saved = record
        if saveThenThrow { throw FakeBrightnessError.failed }
    }
    func clear() throws {
        if failClear { throw FakeBrightnessError.failed }
        saved = nil
    }
}
#endif
