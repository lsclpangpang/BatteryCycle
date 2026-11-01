import AppKit
import Security
#if canImport(XCTest) && !ADVANCED_ACCESS_STANDALONE
import XCTest
@testable import BatteryCycle
#elseif ADVANCED_ACCESS_STANDALONE
private var accessFailures = 0
private func XCTAssertTrue(_ value: Bool) { if !value { accessFailures += 1; print("FAIL: expected true") } }
private func XCTAssertFalse(_ value: Bool) { if value { accessFailures += 1; print("FAIL: expected false") } }
private func XCTAssertNil<T>(_ value: T?) { if value != nil { accessFailures += 1; print("FAIL: expected nil") } }
private func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T) { if left != right { accessFailures += 1; print("FAIL: \(left) != \(right)") } }
class XCTestCase {}
@main private struct AdvancedAccessTestRunner {
    @MainActor static func main() {
        let tests = AdvancedAccessTests()
        tests.testStartsLockedWithoutRequestingAuthentication()
        tests.testSuccessUnlocksOnlyCurrentSession()
        tests.testCancellationAndFailureKeepSettingsHidden()
        tests.testDuplicateClicksDoNotStartDuplicateRequests()
        tests.testLateSuccessAfterPanelClosesCannotUnlock()
        tests.testOldCompletionCannotUnlockNewPanelRequest()
        tests.testEachPanelSessionRequiresFreshAuthentication()
        tests.testTerminationCancelsAndPreventsFurtherRequests()
        tests.testSessionAndSleepNotificationsLockWithoutChangingSettings()
        tests.testPasswordPolicyRejectsWeakerOrUnsupportedRules()
        tests.testPasswordPolicyRejectsAuthenticationBypassFields()
        tests.testGrantMustBeForExactRightAndActuallyAuthorized()
        tests.testInvalidHostPreventsAuthenticationRequest()
        tests.testHostValidationRunsBeforePublishingUnlocked()
        tests.testCompletionReportsCancellationAndFailureWithoutUnlocking()
        tests.testLockEventsAreSynchronousAndObserveLockedState()
        print("AdvancedAccess: 16 checks, \(accessFailures) failures")
        if accessFailures > 0 { exit(1) }
    }
}
#endif

final class AdvancedAccessTests: XCTestCase {
    @MainActor func testStartsLockedWithoutRequestingAuthentication() {
        let backend = AccessTestAuthorizer()
        let controller = AdvancedAccessController(authorizer: backend, observesSystemEvents: false)
        XCTAssertFalse(controller.isUnlocked)
        XCTAssertFalse(controller.isAuthenticating)
        XCTAssertNil(controller.message)
        XCTAssertEqual(backend.requests, 0)
    }

    @MainActor func testSuccessUnlocksOnlyCurrentSession() {
        let backend = AccessTestAuthorizer()
        let controller = AdvancedAccessController(authorizer: backend, observesSystemEvents: false)
        controller.requestUnlock()
        XCTAssertTrue(controller.isAuthenticating)
        XCTAssertFalse(controller.isUnlocked)
        backend.finish(0, .authorized)
        XCTAssertTrue(controller.isUnlocked)
        XCTAssertFalse(controller.isAuthenticating)
        controller.lock()
        XCTAssertFalse(controller.isUnlocked)
        XCTAssertNil(controller.message)
    }

    @MainActor func testCancellationAndFailureKeepSettingsHidden() {
        let backend = AccessTestAuthorizer()
        let controller = AdvancedAccessController(authorizer: backend, observesSystemEvents: false)
        controller.requestUnlock()
        backend.finish(0, .cancelled)
        XCTAssertFalse(controller.isUnlocked)
        XCTAssertFalse(controller.isAuthenticating)
        XCTAssertNil(controller.message)
        controller.requestUnlock()
        backend.finish(1, .failed("管理员验证未通过"))
        XCTAssertFalse(controller.isUnlocked)
        XCTAssertFalse(controller.isAuthenticating)
        XCTAssertEqual(controller.message, "管理员验证未通过")
    }

    @MainActor func testDuplicateClicksDoNotStartDuplicateRequests() {
        let backend = AccessTestAuthorizer()
        let controller = AdvancedAccessController(authorizer: backend, observesSystemEvents: false)
        controller.requestUnlock()
        controller.requestUnlock()
        XCTAssertEqual(backend.requests, 1)
        backend.finish(0, .authorized)
        controller.requestUnlock()
        XCTAssertEqual(backend.requests, 1)
    }

    @MainActor func testLateSuccessAfterPanelClosesCannotUnlock() {
        let backend = AccessTestAuthorizer()
        let controller = AdvancedAccessController(authorizer: backend, observesSystemEvents: false)
        controller.requestUnlock()
        controller.lock()
        backend.finish(0, .authorized)
        XCTAssertFalse(controller.isUnlocked)
        XCTAssertFalse(controller.isAuthenticating)
        XCTAssertTrue(backend.cancellations > 0)
    }

    @MainActor func testOldCompletionCannotUnlockNewPanelRequest() {
        let backend = AccessTestAuthorizer()
        let controller = AdvancedAccessController(authorizer: backend, observesSystemEvents: false)
        controller.requestUnlock()
        controller.lock()
        controller.requestUnlock()
        backend.finish(0, .authorized)
        XCTAssertFalse(controller.isUnlocked)
        XCTAssertTrue(controller.isAuthenticating)
        backend.finish(1, .authorized)
        XCTAssertTrue(controller.isUnlocked)
    }

    @MainActor func testEachPanelSessionRequiresFreshAuthentication() {
        let backend = AccessTestAuthorizer()
        let controller = AdvancedAccessController(authorizer: backend, observesSystemEvents: false)
        controller.requestUnlock()
        backend.finish(0, .authorized)
        controller.lock()
        controller.requestUnlock()
        XCTAssertEqual(backend.requests, 2)
        XCTAssertFalse(controller.isUnlocked)
        backend.finish(1, .cancelled)
        XCTAssertFalse(controller.isUnlocked)
    }

    @MainActor func testTerminationCancelsAndPreventsFurtherRequests() {
        let backend = AccessTestAuthorizer()
        let controller = AdvancedAccessController(authorizer: backend, observesSystemEvents: false)
        controller.requestUnlock()
        controller.prepareForTermination()
        backend.finish(0, .authorized)
        controller.requestUnlock()
        XCTAssertFalse(controller.isUnlocked)
        XCTAssertFalse(controller.isAuthenticating)
        XCTAssertEqual(backend.requests, 1)
    }

    @MainActor func testSessionAndSleepNotificationsLockWithoutChangingSettings() {
        let backend = AccessTestAuthorizer()
        let center = NotificationCenter()
        let controller = AdvancedAccessController(authorizer: backend, observesSystemEvents: true,
                                                   workspaceNotifications: center,
                                                   applicationNotifications: center,
                                                   distributedNotifications: center)
        let notifications: [Notification.Name] = [.init("com.apple.screenIsLocked"), NSWorkspace.sessionDidResignActiveNotification,
                                                   NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification]
        for notification in notifications {
            controller.requestUnlock()
            backend.finish(backend.requests - 1, .authorized)
            XCTAssertTrue(controller.isUnlocked)
            center.post(name: notification, object: nil)
            XCTAssertFalse(controller.isUnlocked)
        }
    }

    func testPasswordPolicyRejectsWeakerOrUnsupportedRules() {
        let definition = AdminAuthorizationPolicy.definition
        XCTAssertTrue(AdminAuthorizationPolicy.matches(definition))
        for (key, value) in [("password-only", false as Any), ("shared", true as Any), ("timeout", 300 as Any),
                             ("group", "staff" as Any), ("authenticate-user", false as Any),
                             ("class", "allow" as Any), ("allow-root", true as Any)] {
            var changed = definition
            changed[key] = value
            XCTAssertFalse(AdminAuthorizationPolicy.matches(changed))
        }
        var unsupported = definition
        unsupported.removeValue(forKey: "password-only")
        XCTAssertFalse(AdminAuthorizationPolicy.matches(unsupported))
        unsupported = definition
        unsupported["password-only"] = 1
        XCTAssertFalse(AdminAuthorizationPolicy.matches(unsupported))
    }

    func testPasswordPolicyRejectsAuthenticationBypassFields() {
        for (key, value) in [("entitled", true as Any), ("entitled-and-group", true as Any),
                             ("vpn-entitled-and-group", true as Any), ("session-owner", true as Any),
                             ("extract-password", true as Any), ("rule", "allow" as Any),
                             ("mechanisms", ["builtin:entitled,privileged"] as Any)] {
            var changed = AdminAuthorizationPolicy.definition
            changed[key] = value
            XCTAssertFalse(AdminAuthorizationPolicy.matches(changed))
        }
    }

    func testGrantMustBeForExactRightAndActuallyAuthorized() {
        XCTAssertTrue(AdminAuthorizationPolicy.acceptsGrantedRight(name: AdminAuthorizationPolicy.rightName, flags: 0))
        XCTAssertFalse(AdminAuthorizationPolicy.acceptsGrantedRight(name: "system.privilege.admin", flags: 0))
        XCTAssertFalse(AdminAuthorizationPolicy.acceptsGrantedRight(name: AdminAuthorizationPolicy.rightName, flags: UInt32(kAuthorizationFlagCanNotPreAuthorize)))
    }

    @MainActor func testInvalidHostPreventsAuthenticationRequest() {
        let backend = AccessTestAuthorizer()
        let controller = AdvancedAccessController(authorizer: backend, observesSystemEvents: false)
        var result: AdminAuthorizationResult?
        controller.requestUnlock(isSessionValid: { false }, completion: { result = $0 })
        XCTAssertEqual(backend.requests, 0)
        XCTAssertFalse(controller.isUnlocked)
        XCTAssertFalse(controller.isAuthenticating)
        XCTAssertEqual(result, .cancelled)
    }

    @MainActor func testHostValidationRunsBeforePublishingUnlocked() {
        let backend = AccessTestAuthorizer()
        let controller = AdvancedAccessController(authorizer: backend, observesSystemEvents: false)
        var hostShown = true
        var sawUnlock = false
        let subscription = controller.$isUnlocked.sink { if $0 { sawUnlock = true } }
        defer { subscription.cancel() }
        var result: AdminAuthorizationResult?
        controller.requestUnlock(isSessionValid: { hostShown }, completion: { result = $0 })
        hostShown = false
        backend.finish(0, .authorized)
        XCTAssertFalse(sawUnlock)
        XCTAssertFalse(controller.isUnlocked)
        XCTAssertFalse(controller.isAuthenticating)
        XCTAssertEqual(result, .cancelled)
    }

    @MainActor func testCompletionReportsCancellationAndFailureWithoutUnlocking() {
        let backend = AccessTestAuthorizer()
        let controller = AdvancedAccessController(authorizer: backend, observesSystemEvents: false)
        var results: [AdminAuthorizationResult] = []
        controller.requestUnlock(completion: { results.append($0) })
        backend.finish(0, .cancelled)
        controller.requestUnlock(completion: { results.append($0) })
        backend.finish(1, .failed("未通过管理员验证"))
        XCTAssertEqual(results, [.cancelled, .failed("未通过管理员验证")])
        XCTAssertFalse(controller.isUnlocked)
        XCTAssertEqual(controller.message, "未通过管理员验证")
    }

    @MainActor func testLockEventsAreSynchronousAndObserveLockedState() {
        let backend = AccessTestAuthorizer()
        let controller = AdvancedAccessController(authorizer: backend, observesSystemEvents: false)
        var events = 0
        var wasLocked = false
        let subscription = controller.lockEvents.sink {
            events += 1
            wasLocked = !controller.isUnlocked && !controller.isAuthenticating
        }
        defer { subscription.cancel() }
        controller.requestUnlock()
        controller.lock()
        XCTAssertEqual(events, 1)
        XCTAssertTrue(wasLocked)
    }
}

@MainActor private final class AccessTestAuthorizer: AdminAuthorizing {
    private var completions: [AdminAuthorizationCompletion] = []
    private(set) var requests = 0
    private(set) var cancellations = 0
    func authorize(completion: @escaping AdminAuthorizationCompletion) {
        requests += 1
        completions.append(completion)
    }
    func cancel() { cancellations += 1 }
    func finish(_ index: Int, _ result: AdminAuthorizationResult) { completions[index](result) }
}
