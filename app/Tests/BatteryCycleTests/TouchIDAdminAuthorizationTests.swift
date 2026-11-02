import Foundation
import LocalAuthentication
#if canImport(XCTest) && !TOUCH_ID_ADMIN_STANDALONE
import XCTest
@testable import BatteryCycle
#else
private var touchIDFailures = 0
class XCTestCase {}
private func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) {
    if actual != expected { touchIDFailures += 1; print("FAIL: \(actual) != \(expected)") }
}
private func XCTAssertTrue(_ value: Bool) { if !value { touchIDFailures += 1; print("FAIL: expected true") } }
private func XCTAssertNil<T>(_ value: T?) { if value != nil { touchIDFailures += 1; print("FAIL: expected nil") } }
@main private struct TouchIDAdminAuthorizationRunner {
    @MainActor static func main() {
        let tests = TouchIDAdminAuthorizationTests()
        tests.testEligibleIdentityRequiresConsoleAdministratorAndMatchingUIDs()
        tests.testTouchIDSuccessRechecksSameAdministratorBeforeAuthorizing()
        tests.testNonAdministratorAndUnconfirmedIdentityUsePasswordDirectly()
        tests.testUnavailableAndExplicitFallbackUseAdministratorPassword()
        tests.testBiometricCancellationDoesNotOpenPassword()
        tests.testBiometricFailureDoesNotAuthorizeOrOpenPassword()
        tests.testIdentityChangeAfterTouchIDFailsClosed()
        tests.testDuplicateRequestsDoNotStartAnotherAuthentication()
        tests.testCancelDuringIdentityLookupIgnoresLateResult()
        tests.testCancelDuringTouchIDIgnoresLateSuccess()
        tests.testCancelDuringIdentityRecheckCannotAuthorize()
        tests.testCancelDuringPasswordIgnoresLateSuccess()
        tests.testPreviousRequestCannotCompleteNewRequest()
        tests.testDuplicateBiometricReplyCannotCompletePasswordFallback()
        tests.testPasswordCancellationAndFailureArePreserved()
        tests.testEachNewRequestChecksIdentityAgain()
        tests.testNativePolicyUsesOnlyBiometricsAndDisablesReuse()
        tests.testNativeCancellationErrorsNeverRequestPassword()
        tests.testNativeUnavailableFallbackAndFailedMatchErrorsRequestPassword()
        tests.testUnknownErrorsFailClosed()
        tests.testFailedPreflightNeverShowsTouchIDPrompt()
        print("TouchIDAdminAuthorization: 21 checks, \(touchIDFailures) failures")
        if touchIDFailures > 0 { exit(1) }
    }
}
#endif

final class TouchIDAdminAuthorizationTests: XCTestCase {
    private func identity(uid: UInt32 = 501, effectiveUID: UInt32? = nil,
                          consoleUID: UInt32? = 501, isAdministrator: Bool? = true) -> AdministratorIdentity {
        .init(realUID: uid, effectiveUID: effectiveUID ?? uid, consoleUID: consoleUID,
              isAdministrator: isAdministrator)
    }

    func testEligibleIdentityRequiresConsoleAdministratorAndMatchingUIDs() {
        XCTAssertEqual(identity().eligibleUID, 501)
        for invalid in [identity(uid: 0, consoleUID: 0), identity(effectiveUID: 0),
                        identity(consoleUID: nil), identity(consoleUID: 502),
                        identity(isAdministrator: false), identity(isAdministrator: nil)] {
            XCTAssertNil(invalid.eligibleUID)
        }
    }

    @MainActor func testTouchIDSuccessRechecksSameAdministratorBeforeAuthorizing() {
        let fixture = TouchIDFixture()
        fixture.start()
        XCTAssertEqual(fixture.identity.requests, 1)
        XCTAssertEqual(fixture.biometric.requests, 0)
        fixture.identity.finish(0, identity())
        XCTAssertEqual(fixture.biometric.requests, 1)
        fixture.biometric.finish(0, .authorized)
        XCTAssertEqual(fixture.identity.requests, 2)
        XCTAssertTrue(fixture.results.isEmpty)
        fixture.identity.finish(1, identity())
        XCTAssertEqual(fixture.results, [.authorized])
        XCTAssertEqual(fixture.password.requests, 0)
    }

    @MainActor func testNonAdministratorAndUnconfirmedIdentityUsePasswordDirectly() {
        for status in [nil, identity(isAdministrator: false), identity(consoleUID: nil),
                       identity(uid: 0, consoleUID: 0), identity(effectiveUID: 502)] {
            let fixture = TouchIDFixture()
            fixture.start()
            fixture.identity.finish(0, status)
            XCTAssertEqual(fixture.biometric.requests, 0)
            XCTAssertEqual(fixture.password.requests, 1)
            fixture.password.finish(0, .authorized)
            XCTAssertEqual(fixture.results, [.authorized])
        }
    }

    @MainActor func testUnavailableAndExplicitFallbackUseAdministratorPassword() {
        for outcome: TouchIDAuthenticationResult in [.unavailable, .usePassword] {
            let fixture = TouchIDFixture()
            fixture.start()
            fixture.identity.finish(0, identity())
            fixture.biometric.finish(0, outcome)
            XCTAssertEqual(fixture.password.requests, 1)
            XCTAssertTrue(fixture.results.isEmpty)
            fixture.password.finish(0, .authorized)
            XCTAssertEqual(fixture.results, [.authorized])
        }
    }

    @MainActor func testBiometricCancellationDoesNotOpenPassword() {
        let fixture = TouchIDFixture()
        fixture.start()
        fixture.identity.finish(0, identity())
        fixture.biometric.finish(0, .cancelled)
        XCTAssertEqual(fixture.results, [.cancelled])
        XCTAssertEqual(fixture.password.requests, 0)
    }

    @MainActor func testBiometricFailureDoesNotAuthorizeOrOpenPassword() {
        let fixture = TouchIDFixture()
        fixture.start()
        fixture.identity.finish(0, identity())
        fixture.biometric.finish(0, .failed("Touch ID 验证未通过"))
        XCTAssertEqual(fixture.results, [.failed("Touch ID 验证未通过")])
        XCTAssertEqual(fixture.password.requests, 0)
    }

    @MainActor func testIdentityChangeAfterTouchIDFailsClosed() {
        for status in [nil, identity(uid: 502, consoleUID: 502), identity(isAdministrator: false),
                       identity(consoleUID: 502), identity(effectiveUID: 502)] {
            let fixture = TouchIDFixture()
            fixture.start()
            fixture.identity.finish(0, identity())
            fixture.biometric.finish(0, .authorized)
            fixture.identity.finish(1, status)
            XCTAssertEqual(fixture.results.count, 1)
            XCTAssertTrue(!fixture.results.contains(.authorized))
            XCTAssertEqual(fixture.password.requests, 0)
        }
    }

    @MainActor func testDuplicateRequestsDoNotStartAnotherAuthentication() {
        let fixture = TouchIDFixture()
        fixture.start()
        fixture.start()
        XCTAssertEqual(fixture.identity.requests, 1)
        fixture.identity.finish(0, identity())
        XCTAssertEqual(fixture.biometric.requests, 1)
        fixture.biometric.finish(0, .authorized)
        fixture.identity.finish(1, identity())
        XCTAssertEqual(fixture.results, [.authorized])
    }

    @MainActor func testCancelDuringIdentityLookupIgnoresLateResult() {
        let fixture = TouchIDFixture()
        fixture.start()
        fixture.authorizer.cancel()
        fixture.identity.finish(0, identity())
        XCTAssertEqual(fixture.results, [.cancelled])
        XCTAssertEqual(fixture.biometric.requests, 0)
        XCTAssertEqual(fixture.password.requests, 0)
    }

    @MainActor func testCancelDuringTouchIDIgnoresLateSuccess() {
        let fixture = TouchIDFixture()
        fixture.start()
        fixture.identity.finish(0, identity())
        fixture.authorizer.cancel()
        fixture.biometric.finish(0, .authorized)
        XCTAssertEqual(fixture.results, [.cancelled])
        XCTAssertEqual(fixture.biometric.cancellations, 1)
        XCTAssertEqual(fixture.identity.requests, 1)
        XCTAssertEqual(fixture.password.requests, 0)
    }

    @MainActor func testCancelDuringIdentityRecheckCannotAuthorize() {
        let fixture = TouchIDFixture()
        fixture.start()
        fixture.identity.finish(0, identity())
        fixture.biometric.finish(0, .authorized)
        fixture.authorizer.cancel()
        fixture.identity.finish(1, identity())
        XCTAssertEqual(fixture.results, [.cancelled])
    }

    @MainActor func testCancelDuringPasswordIgnoresLateSuccess() {
        let fixture = TouchIDFixture()
        fixture.start()
        fixture.identity.finish(0, nil)
        fixture.authorizer.cancel()
        fixture.password.finish(0, .authorized)
        XCTAssertEqual(fixture.results, [.cancelled])
        XCTAssertEqual(fixture.password.cancellations, 1)
    }

    @MainActor func testPreviousRequestCannotCompleteNewRequest() {
        let fixture = TouchIDFixture()
        fixture.start()
        fixture.identity.finish(0, identity())
        fixture.authorizer.cancel()
        fixture.start()
        fixture.biometric.finish(0, .authorized)
        XCTAssertEqual(fixture.identity.requests, 2)
        fixture.identity.finish(1, identity())
        fixture.biometric.finish(1, .authorized)
        fixture.identity.finish(2, identity())
        XCTAssertEqual(fixture.results, [.cancelled, .authorized])
    }

    @MainActor func testDuplicateBiometricReplyCannotCompletePasswordFallback() {
        let fixture = TouchIDFixture()
        fixture.start()
        fixture.identity.finish(0, identity())
        fixture.biometric.finish(0, .usePassword)
        fixture.biometric.finish(0, .authorized)
        XCTAssertEqual(fixture.identity.requests, 1)
        XCTAssertTrue(fixture.results.isEmpty)
        fixture.password.finish(0, .authorized)
        fixture.password.finish(0, .authorized)
        XCTAssertEqual(fixture.results, [.authorized])
    }

    @MainActor func testPasswordCancellationAndFailureArePreserved() {
        for outcome: AdminAuthorizationResult in [.cancelled, .failed("密码验证失败")] {
            let fixture = TouchIDFixture()
            fixture.start()
            fixture.identity.finish(0, nil)
            fixture.password.finish(0, outcome)
            XCTAssertEqual(fixture.results, [outcome])
        }
    }

    @MainActor func testEachNewRequestChecksIdentityAgain() {
        let fixture = TouchIDFixture()
        fixture.start()
        fixture.identity.finish(0, identity())
        fixture.biometric.finish(0, .authorized)
        fixture.identity.finish(1, identity())
        fixture.start()
        XCTAssertEqual(fixture.identity.requests, 3)
        XCTAssertEqual(fixture.biometric.requests, 1)
        fixture.identity.finish(2, identity())
        XCTAssertEqual(fixture.biometric.requests, 2)
    }

    func testNativePolicyUsesOnlyBiometricsAndDisablesReuse() {
        XCTAssertEqual(TouchIDAuthenticationPolicy.policy, .deviceOwnerAuthenticationWithBiometrics)
        XCTAssertEqual(TouchIDAuthenticationPolicy.reuseDuration, 0)
        XCTAssertEqual(TouchIDAuthenticationPolicy.fallbackTitle, "使用管理员密码")
    }

    func testNativeCancellationErrorsNeverRequestPassword() {
        for code: LAError.Code in [.userCancel, .systemCancel, .appCancel, .invalidContext] {
            XCTAssertEqual(TouchIDAuthenticationPolicy.result(success: false,
                error: NSError(domain: LAError.errorDomain, code: code.rawValue)), .cancelled)
        }
    }

    func testNativeUnavailableFallbackAndFailedMatchErrorsRequestPassword() {
        for code: LAError.Code in [.biometryNotAvailable, .biometryNotEnrolled, .biometryLockout,
                                  .biometryDisconnected, .biometryNotPaired] {
            XCTAssertEqual(TouchIDAuthenticationPolicy.result(success: false,
                error: NSError(domain: LAError.errorDomain, code: code.rawValue)), .unavailable)
        }
        for code: LAError.Code in [.userFallback, .authenticationFailed] {
            XCTAssertEqual(TouchIDAuthenticationPolicy.result(success: false,
                error: NSError(domain: LAError.errorDomain, code: code.rawValue)), .usePassword)
        }
    }

    func testUnknownErrorsFailClosed() {
        for error in [nil, NSError(domain: "OtherError", code: LAError.userFallback.rawValue),
                      NSError(domain: LAError.errorDomain, code: LAError.notInteractive.rawValue)] {
            let outcome = TouchIDAuthenticationPolicy.result(success: false, error: error)
            if case .failed = outcome { } else { XCTAssertTrue(false) }
        }
    }

    func testFailedPreflightNeverShowsTouchIDPrompt() {
        XCTAssertTrue(TouchIDAuthenticationPolicy.canPrompt(canEvaluate: true, biometryType: .touchID))
        XCTAssertTrue(!TouchIDAuthenticationPolicy.canPrompt(canEvaluate: false, biometryType: .touchID))
        XCTAssertTrue(!TouchIDAuthenticationPolicy.canPrompt(canEvaluate: true, biometryType: .none))
    }
}

@MainActor private final class TouchIDFixture {
    let identity = TestAdministratorIdentityChecker()
    let biometric = TestTouchIDAuthenticator()
    let password = TestPasswordAuthorizer()
    lazy var authorizer = TouchIDAdminAuthorization(identityChecker: identity, touchID: biometric, password: password)
    var results: [AdminAuthorizationResult] = []
    func start() { authorizer.authorize { [weak self] in self?.results.append($0) } }
}

@MainActor private final class TestAdministratorIdentityChecker: AdministratorIdentityChecking {
    private var completions: [AdministratorIdentityCompletion] = []
    var requests: Int { completions.count }
    func check(completion: @escaping AdministratorIdentityCompletion) { completions.append(completion) }
    func finish(_ index: Int, _ result: AdministratorIdentity?) {
        guard completions.indices.contains(index) else { XCTAssertTrue(false); return }
        completions[index](result)
    }
}

@MainActor private final class TestTouchIDAuthenticator: TouchIDAuthenticating {
    private var completions: [TouchIDAuthenticationCompletion] = []
    var requests: Int { completions.count }
    private(set) var cancellations = 0
    func authenticate(completion: @escaping TouchIDAuthenticationCompletion) { completions.append(completion) }
    func cancel() { cancellations += 1 }
    func finish(_ index: Int, _ result: TouchIDAuthenticationResult) {
        guard completions.indices.contains(index) else { XCTAssertTrue(false); return }
        completions[index](result)
    }
}

@MainActor private final class TestPasswordAuthorizer: AdminAuthorizing {
    private var completions: [AdminAuthorizationCompletion] = []
    var requests: Int { completions.count }
    private(set) var cancellations = 0
    func authorize(completion: @escaping AdminAuthorizationCompletion) { completions.append(completion) }
    func cancel() { cancellations += 1 }
    func finish(_ index: Int, _ result: AdminAuthorizationResult) {
        guard completions.indices.contains(index) else { XCTAssertTrue(false); return }
        completions[index](result)
    }
}
