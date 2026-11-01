import AppKit
import Combine
#if canImport(XCTest) && !MENU_NAVIGATION_STANDALONE
import XCTest
@testable import BatteryCycle
#elseif MENU_NAVIGATION_STANDALONE
private var navigationFailures = 0
private func XCTAssertTrue(_ value: Bool) { if !value { navigationFailures += 1; print("FAIL: expected true") } }
private func XCTAssertFalse(_ value: Bool) { if value { navigationFailures += 1; print("FAIL: expected false") } }
private func XCTAssertNil<T>(_ value: T?) { if value != nil { navigationFailures += 1; print("FAIL: expected nil") } }
private func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T) { if left != right { navigationFailures += 1; print("FAIL: \(left) != \(right)") } }
class XCTestCase {}
@main private struct MenuNavigationTestRunner {
    @MainActor static func main() {
        let tests = MenuNavigationTests()
        tests.testStartsOnMainWithoutOpeningOrAuthenticating()
        tests.testAuthenticationPinsHostBeforeRequestAndAdvancesSamePresentation()
        tests.testFocusLossWithHostStillShownDoesNotInvalidateAuthentication()
        tests.testExplicitCloseRejectsLateSuccessBeforeUnlockIsPublished()
        tests.testOldSuccessCannotUnlockReopenedHost()
        tests.testNoAuthenticationWhenHostIsNotShown()
        tests.testRepeatedClicksStartOnlyOneRequest()
        tests.testCancellationAndFailureRestoreNormalModeAndStayOnMain()
        tests.testRestoringNormalModeCanSynchronouslyCloseWithoutEnteringAdvanced()
        tests.testBackLocksAndNextEntryAuthenticatesAgain()
        tests.testExternalLockRestoresHostModeAndRejectsPendingSuccess()
        tests.testExternalLockReturnsAdvancedPageToMain()
        tests.testCloseIsIdempotentDuringReentrantHostCallbacks()
        tests.testHostDisappearingWithoutCloseNotificationCannotUnlock()
        tests.testCloseDuringPinningPreventsRequest()
        tests.testTerminationInvalidatesAndPreventsNewPresentation()
        print("MenuNavigation: 16 checks, \(navigationFailures) failures")
        if navigationFailures > 0 { exit(1) }
    }
}
#endif

final class MenuNavigationTests: XCTestCase {
    @MainActor func testStartsOnMainWithoutOpeningOrAuthenticating() {
        let fixture = NavigationFixture()
        XCTAssertEqual(fixture.navigation.page, .main)
        XCTAssertFalse(fixture.navigation.isPresented)
        XCTAssertEqual(fixture.authorizer.requests, 0)
    }

    @MainActor func testAuthenticationPinsHostBeforeRequestAndAdvancesSamePresentation() {
        let fixture = NavigationFixture()
        fixture.show()
        fixture.navigation.openAdvanced()
        XCTAssertEqual(fixture.host.events, ["mode:true", "authorize"])
        XCTAssertEqual(fixture.navigation.page, .main)
        XCTAssertTrue(fixture.access.isAuthenticating)
        fixture.authorizer.finish(0, .authorized)
        XCTAssertEqual(fixture.navigation.page, .advanced)
        XCTAssertTrue(fixture.access.isUnlocked)
        XCTAssertEqual(fixture.host.modes, [true, false])
    }

    @MainActor func testFocusLossWithHostStillShownDoesNotInvalidateAuthentication() {
        let fixture = NavigationFixture()
        fixture.show()
        fixture.navigation.openAdvanced()
        fixture.host.isKey = false
        fixture.authorizer.finish(0, .authorized)
        XCTAssertTrue(fixture.navigation.isPresented)
        XCTAssertEqual(fixture.navigation.page, .advanced)
        XCTAssertTrue(fixture.access.isUnlocked)
    }

    @MainActor func testExplicitCloseRejectsLateSuccessBeforeUnlockIsPublished() {
        let fixture = NavigationFixture()
        var sawUnlock = false
        let subscription = fixture.access.$isUnlocked.sink { if $0 { sawUnlock = true } }
        defer { subscription.cancel() }
        fixture.show()
        fixture.navigation.openAdvanced()
        fixture.close()
        fixture.authorizer.finish(0, .authorized)
        XCTAssertFalse(sawUnlock)
        XCTAssertFalse(fixture.access.isUnlocked)
        XCTAssertFalse(fixture.navigation.isPresented)
        XCTAssertEqual(fixture.navigation.page, .main)
        XCTAssertEqual(fixture.host.modes, [true, false])
    }

    @MainActor func testOldSuccessCannotUnlockReopenedHost() {
        let fixture = NavigationFixture()
        fixture.show()
        fixture.navigation.openAdvanced()
        fixture.close()
        fixture.show()
        fixture.navigation.openAdvanced()
        fixture.authorizer.finish(0, .authorized)
        XCTAssertFalse(fixture.access.isUnlocked)
        XCTAssertTrue(fixture.access.isAuthenticating)
        XCTAssertEqual(fixture.navigation.page, .main)
        fixture.authorizer.finish(1, .authorized)
        XCTAssertTrue(fixture.access.isUnlocked)
        XCTAssertEqual(fixture.navigation.page, .advanced)
    }

    @MainActor func testNoAuthenticationWhenHostIsNotShown() {
        let fixture = NavigationFixture()
        fixture.navigation.openAdvanced()
        fixture.show()
        fixture.host.shown = false
        fixture.navigation.openAdvanced()
        XCTAssertEqual(fixture.authorizer.requests, 0)
        XCTAssertEqual(fixture.host.modes, [])
        XCTAssertFalse(fixture.navigation.isPresented)
    }

    @MainActor func testRepeatedClicksStartOnlyOneRequest() {
        let fixture = NavigationFixture()
        fixture.show()
        fixture.navigation.openAdvanced()
        fixture.navigation.openAdvanced()
        XCTAssertEqual(fixture.authorizer.requests, 1)
        XCTAssertEqual(fixture.host.modes, [true])
    }

    @MainActor func testCancellationAndFailureRestoreNormalModeAndStayOnMain() {
        let fixture = NavigationFixture()
        fixture.show()
        fixture.navigation.openAdvanced()
        fixture.authorizer.finish(0, .cancelled)
        XCTAssertEqual(fixture.navigation.page, .main)
        XCTAssertFalse(fixture.access.isUnlocked)
        XCTAssertEqual(fixture.host.modes, [true, false])
        fixture.navigation.openAdvanced()
        fixture.authorizer.finish(1, .failed("管理员验证未通过"))
        XCTAssertEqual(fixture.navigation.page, .main)
        XCTAssertFalse(fixture.access.isUnlocked)
        XCTAssertEqual(fixture.access.message, "管理员验证未通过")
        XCTAssertEqual(fixture.host.modes, [true, false, true, false])
    }

    @MainActor func testRestoringNormalModeCanSynchronouslyCloseWithoutEnteringAdvanced() {
        let fixture = NavigationFixture()
        var sawAdvanced = false
        let subscription = fixture.navigation.$page.sink { if $0 == .advanced { sawAdvanced = true } }
        defer { subscription.cancel() }
        fixture.host.onModeChange = { [weak fixture] enabled in
            if !enabled { fixture?.close() }
        }
        fixture.show()
        fixture.navigation.openAdvanced()
        fixture.authorizer.finish(0, .authorized)
        XCTAssertFalse(sawAdvanced)
        XCTAssertEqual(fixture.navigation.page, .main)
        XCTAssertFalse(fixture.access.isUnlocked)
        XCTAssertFalse(fixture.navigation.isPresented)
    }

    @MainActor func testBackLocksAndNextEntryAuthenticatesAgain() {
        let fixture = NavigationFixture()
        fixture.show()
        fixture.navigation.openAdvanced()
        fixture.authorizer.finish(0, .authorized)
        fixture.navigation.back()
        XCTAssertTrue(fixture.navigation.isPresented)
        XCTAssertEqual(fixture.navigation.page, .main)
        XCTAssertFalse(fixture.access.isUnlocked)
        fixture.navigation.openAdvanced()
        XCTAssertEqual(fixture.authorizer.requests, 2)
        XCTAssertFalse(fixture.access.isUnlocked)
        fixture.authorizer.finish(1, .authorized)
        XCTAssertEqual(fixture.navigation.page, .advanced)
    }

    @MainActor func testExternalLockRestoresHostModeAndRejectsPendingSuccess() {
        let fixture = NavigationFixture()
        fixture.show()
        fixture.navigation.openAdvanced()
        fixture.access.lock()
        XCTAssertEqual(fixture.host.modes, [true, false])
        fixture.authorizer.finish(0, .authorized)
        XCTAssertFalse(fixture.access.isUnlocked)
        XCTAssertEqual(fixture.navigation.page, .main)
        fixture.navigation.openAdvanced()
        XCTAssertEqual(fixture.authorizer.requests, 2)
    }

    @MainActor func testExternalLockReturnsAdvancedPageToMain() {
        let fixture = NavigationFixture()
        fixture.show()
        fixture.navigation.openAdvanced()
        fixture.authorizer.finish(0, .authorized)
        fixture.access.lock()
        XCTAssertEqual(fixture.navigation.page, .main)
        XCTAssertFalse(fixture.access.isUnlocked)
    }

    @MainActor func testCloseIsIdempotentDuringReentrantHostCallbacks() {
        let fixture = NavigationFixture()
        fixture.show()
        fixture.navigation.openAdvanced()
        fixture.host.onModeChange = { [weak fixture] enabled in
            if !enabled { fixture?.navigation.didClose() }
        }
        fixture.close()
        let cancellations = fixture.authorizer.cancellations
        fixture.navigation.didClose()
        fixture.navigation.didClose()
        XCTAssertEqual(fixture.authorizer.cancellations, cancellations)
        XCTAssertEqual(fixture.host.modes, [true, false])
        XCTAssertFalse(fixture.access.isUnlocked)
    }

    @MainActor func testHostDisappearingWithoutCloseNotificationCannotUnlock() {
        let fixture = NavigationFixture()
        var sawUnlock = false
        let subscription = fixture.access.$isUnlocked.sink { if $0 { sawUnlock = true } }
        defer { subscription.cancel() }
        fixture.show()
        fixture.navigation.openAdvanced()
        fixture.host.shown = false
        fixture.authorizer.finish(0, .authorized)
        XCTAssertFalse(sawUnlock)
        XCTAssertFalse(fixture.access.isUnlocked)
        XCTAssertFalse(fixture.navigation.isPresented)
        XCTAssertEqual(fixture.navigation.page, .main)
        XCTAssertEqual(fixture.host.modes, [true, false])
    }

    @MainActor func testCloseDuringPinningPreventsRequest() {
        let fixture = NavigationFixture()
        fixture.show()
        fixture.host.onModeChange = { [weak fixture] enabled in
            if enabled { fixture?.close() }
        }
        fixture.navigation.openAdvanced()
        XCTAssertEqual(fixture.authorizer.requests, 0)
        XCTAssertFalse(fixture.access.isUnlocked)
        XCTAssertFalse(fixture.navigation.isPresented)
        XCTAssertEqual(fixture.host.modes, [true, false])
    }

    @MainActor func testTerminationInvalidatesAndPreventsNewPresentation() {
        let fixture = NavigationFixture()
        fixture.show()
        fixture.navigation.openAdvanced()
        fixture.navigation.prepareForTermination()
        fixture.authorizer.finish(0, .authorized)
        fixture.navigation.didShow()
        fixture.navigation.openAdvanced()
        XCTAssertFalse(fixture.access.isUnlocked)
        XCTAssertFalse(fixture.navigation.isPresented)
        XCTAssertEqual(fixture.navigation.page, .main)
        XCTAssertEqual(fixture.authorizer.requests, 1)
        XCTAssertEqual(fixture.host.modes, [true, false])
    }
}

@MainActor private final class NavigationFixture {
    let host = NavigationTestHost()
    let authorizer: NavigationTestAuthorizer
    let access: AdvancedAccessController
    let navigation: MenuNavigationController
    init() {
        let authorizer = NavigationTestAuthorizer()
        self.authorizer = authorizer
        access = AdvancedAccessController(authorizer: authorizer, observesSystemEvents: false)
        navigation = MenuNavigationController(access: access)
        navigation.bindHost(isShown: { [weak host] in host?.shown ?? false }, setAuthenticationMode: { [weak host] enabled in
            host?.modes.append(enabled)
            host?.events.append("mode:\(enabled)")
            host?.onModeChange?(enabled)
        })
        authorizer.onRequest = { [weak host] in host?.events.append("authorize") }
    }
    func show() { host.shown = true; navigation.didShow() }
    func close() { host.shown = false; navigation.didClose() }
}

@MainActor private final class NavigationTestHost {
    var shown = false
    var isKey = true
    var modes: [Bool] = []
    var events: [String] = []
    var onModeChange: ((Bool) -> Void)?
}

@MainActor private final class NavigationTestAuthorizer: AdminAuthorizing {
    private var completions: [AdminAuthorizationCompletion] = []
    private(set) var requests = 0
    private(set) var cancellations = 0
    var onRequest: (() -> Void)?
    func authorize(completion: @escaping AdminAuthorizationCompletion) {
        requests += 1
        completions.append(completion)
        onRequest?()
    }
    func cancel() { cancellations += 1 }
    func finish(_ index: Int, _ result: AdminAuthorizationResult) { completions[index](result) }
}
