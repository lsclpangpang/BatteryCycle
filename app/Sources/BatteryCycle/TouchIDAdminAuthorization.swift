import Darwin
import Foundation
import LocalAuthentication
import SystemConfiguration

struct AdministratorIdentity: Equatable, Sendable {
    let realUID: UInt32
    let effectiveUID: UInt32
    let consoleUID: UInt32?
    let isAdministrator: Bool?

    var eligibleUID: UInt32? {
        guard realUID != 0, realUID == effectiveUID, consoleUID == realUID,
              isAdministrator == true else { return nil }
        return realUID
    }
}

typealias AdministratorIdentityCompletion = @MainActor @Sendable (AdministratorIdentity?) -> Void

@MainActor protocol AdministratorIdentityChecking: AnyObject {
    func check(completion: @escaping AdministratorIdentityCompletion)
}

enum TouchIDAuthenticationResult: Equatable, Sendable {
    case authorized, unavailable, usePassword, cancelled
    case failed(String)
}

typealias TouchIDAuthenticationCompletion = @MainActor @Sendable (TouchIDAuthenticationResult) -> Void

@MainActor protocol TouchIDAuthenticating: AnyObject {
    func authenticate(completion: @escaping TouchIDAuthenticationCompletion)
    func cancel()
}

enum TouchIDAuthenticationPolicy {
    static let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
    static let reuseDuration: TimeInterval = 0
    static let fallbackTitle = "使用管理员密码"

    /// No prompt has been shown when preflight fails, so every reason means "use the password".
    static func canPrompt(canEvaluate: Bool, biometryType: LABiometryType) -> Bool {
        canEvaluate && biometryType == .touchID
    }

    static func result(success: Bool, error: NSError?) -> TouchIDAuthenticationResult {
        if success && error == nil { return .authorized }
        guard let error, error.domain == LAError.errorDomain, let code = LAError.Code(rawValue: error.code) else {
            return .failed("Touch ID 验证未通过，请重试")
        }
        switch code {
        case .userCancel, .systemCancel, .appCancel, .invalidContext: return .cancelled
        // Repeated non-matching fingers end LocalAuthentication's prompt. The password path still
        // requires an administrator, so offer it instead of making the user start over.
        case .userFallback, .authenticationFailed: return .usePassword
        case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout,
             .biometryDisconnected, .biometryNotPaired: return .unavailable
        default: return .failed("Touch ID 验证未通过，请重试")
        }
    }
}

/// Touch ID proves only the current user's presence. Eligibility and a fresh post-success
/// check supply the separate administrator requirement. Password fallback keeps its own
/// Authorization Services administrator policy and may authenticate another administrator.
@MainActor final class TouchIDAdminAuthorization: AdminAuthorizing {
    private enum Phase: Equatable {
        case initialIdentity, touchID(UInt32), verifyIdentity(UInt32), password
    }
    private struct Attempt {
        let id: UUID
        var phase: Phase
        let completion: AdminAuthorizationCompletion
    }
    private let identityChecker: any AdministratorIdentityChecking
    private let touchID: any TouchIDAuthenticating
    private let password: any AdminAuthorizing
    private var attempt: Attempt?

    init(identityChecker: (any AdministratorIdentityChecking)? = nil, touchID: (any TouchIDAuthenticating)? = nil,
         password: (any AdminAuthorizing)? = nil) {
        self.identityChecker = identityChecker ?? NativeAdministratorIdentityChecker()
        self.touchID = touchID ?? NativeTouchIDAuthenticator()
        self.password = password ?? AdminAuthorization()
    }

    func authorize(completion: @escaping AdminAuthorizationCompletion) {
        guard attempt == nil else { return }
        let id = UUID()
        attempt = Attempt(id: id, phase: .initialIdentity, completion: completion)
        identityChecker.check { [weak self] identity in
            guard let self, self.isCurrent(id, phase: .initialIdentity) else { return }
            guard let uid = identity?.eligibleUID else { self.requestPassword(id); return }
            self.attempt?.phase = .touchID(uid)
            self.touchID.authenticate { [weak self] result in self?.didAuthenticate(result, id: id, uid: uid) }
        }
    }

    func cancel() {
        let previous = attempt
        // Invalidate ownership before invalidating LAContext or AuthorizationRef, since their
        // cancellation replies may arrive synchronously or after a new request has started.
        attempt = nil
        guard let previous else { return }
        touchID.cancel()
        password.cancel()
        previous.completion(.cancelled)
    }

    private func didAuthenticate(_ result: TouchIDAuthenticationResult, id: UUID, uid: UInt32) {
        guard isCurrent(id, phase: .touchID(uid)) else { return }
        switch result {
        case .authorized:
            attempt?.phase = .verifyIdentity(uid)
            identityChecker.check { [weak self] identity in
                guard let self, self.isCurrent(id, phase: .verifyIdentity(uid)) else { return }
                guard identity?.eligibleUID == uid else {
                    self.finish(id, .failed("当前管理员身份已变更，未解锁高级功能，请重试"))
                    return
                }
                self.finish(id, .authorized)
            }
        case .unavailable, .usePassword: requestPassword(id)
        case .cancelled: finish(id, .cancelled)
        case let .failed(message): finish(id, .failed(message))
        }
    }

    private func requestPassword(_ id: UUID) {
        guard attempt?.id == id else { return }
        attempt?.phase = .password
        password.authorize { [weak self] result in
            guard let self, self.isCurrent(id, phase: .password) else { return }
            self.finish(id, result)
        }
    }

    private func isCurrent(_ id: UUID, phase: Phase) -> Bool {
        attempt?.id == id && attempt?.phase == phase
    }

    private func finish(_ id: UUID, _ result: AdminAuthorizationResult) {
        guard let previous = attempt, previous.id == id else { return }
        attempt = nil
        previous.completion(result)
    }
}

/// Directory Services membership can contact a server. Keep it off the menu's main thread.
/// mbr_check_membership includes nested groups; process supplementary groups do not.
@MainActor private final class NativeAdministratorIdentityChecker: AdministratorIdentityChecking {
    func check(completion: @escaping AdministratorIdentityCompletion) {
        DispatchQueue.global(qos: .userInitiated).async {
            let identity = Self.readIdentity()
            Task { @MainActor in completion(identity) }
        }
    }

    nonisolated private static func consoleUID() -> UInt32? {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil),
              (name as String) != "loginwindow", uid != 0 else { return nil }
        return uid
    }

    nonisolated private static func readIdentity() -> AdministratorIdentity? {
        let realUID = getuid(), effectiveUID = geteuid(), console = consoleUID()
        guard realUID != 0, realUID == effectiveUID, console == realUID else { return nil }
        let administrator = isAdministrator(uid: realUID)
        // Do not return a stale mixed snapshot if a console or process identity changed
        // while Directory Services was answering the membership request.
        guard getuid() == realUID, geteuid() == effectiveUID, consoleUID() == console else { return nil }
        return .init(realUID: realUID, effectiveUID: effectiveUID, consoleUID: console,
                     isAdministrator: administrator)
    }

    nonisolated private static func isAdministrator(uid: uid_t) -> Bool? {
        // membership.h is public but is not exported by the Swift Darwin module. Resolve
        // its public libSystem symbols using their exact C declarations from that header.
        typealias UIDToUUID = @convention(c) (uid_t, UnsafeMutablePointer<UInt8>) -> Int32
        typealias IdentifierToUUID = @convention(c) (Int32, UnsafeRawPointer, size_t, UnsafeMutablePointer<UInt8>) -> Int32
        typealias CheckMembership = @convention(c) (UnsafePointer<UInt8>, UnsafePointer<UInt8>, UnsafeMutablePointer<Int32>) -> Int32
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let uidSymbol = dlsym(handle, "mbr_uid_to_uuid"),
              let groupSymbol = dlsym(handle, "mbr_identifier_to_uuid"),
              let checkSymbol = dlsym(handle, "mbr_check_membership") else { return nil }
        let uidToUUID = unsafeBitCast(uidSymbol, to: UIDToUUID.self)
        let identifierToUUID = unsafeBitCast(groupSymbol, to: IdentifierToUUID.self)
        let checkMembership = unsafeBitCast(checkSymbol, to: CheckMembership.self)
        var user = [UInt8](repeating: 0, count: 16)
        var group = [UInt8](repeating: 0, count: 16)
        let userStatus = user.withUnsafeMutableBufferPointer { uidToUUID(uid, $0.baseAddress!) }
        // ID_TYPE_GROUPNAME = 5; membership.h requires a NUL-terminated UTF-8 name.
        let groupName = Array("admin".utf8CString)
        let groupStatus = groupName.withUnsafeBufferPointer { name in
            group.withUnsafeMutableBufferPointer { identifierToUUID(5, name.baseAddress!, size_t(name.count), $0.baseAddress!) }
        }
        guard userStatus == 0, groupStatus == 0 else { return nil }
        var member: Int32 = 0
        let status = user.withUnsafeBufferPointer { user in
            group.withUnsafeBufferPointer { group in checkMembership(user.baseAddress!, group.baseAddress!, &member) }
        }
        guard status == 0, member == 0 || member == 1 else { return nil }
        return member == 1
    }
}

@MainActor private final class NativeTouchIDAuthenticator: TouchIDAuthenticating {
    private struct Attempt {
        let id: UUID
        let context: LAContext
        let completion: TouchIDAuthenticationCompletion
    }
    private var attempt: Attempt?

    func authenticate(completion: @escaping TouchIDAuthenticationCompletion) {
        guard attempt == nil else { return }
        // Never reuse a successfully evaluated context or a recent device-unlock grant.
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = TouchIDAuthenticationPolicy.reuseDuration
        context.localizedFallbackTitle = TouchIDAuthenticationPolicy.fallbackTitle
        context.localizedCancelTitle = "取消"
        let id = UUID()
        attempt = Attempt(id: id, context: context, completion: completion)
        // biometryType is set only by canEvaluatePolicy, so evaluate that first.
        let canEvaluate = context.canEvaluatePolicy(TouchIDAuthenticationPolicy.policy, error: nil)
        guard TouchIDAuthenticationPolicy.canPrompt(canEvaluate: canEvaluate, biometryType: context.biometryType) else {
            finish(id, .unavailable)
            return
        }
        context.evaluatePolicy(TouchIDAuthenticationPolicy.policy, localizedReason: "解锁高级功能") { [weak self] success, error in
            let result = TouchIDAuthenticationPolicy.result(success: success, error: error as NSError?)
            Task { @MainActor in self?.finish(id, result) }
        }
    }

    func cancel() {
        guard let previous = attempt else { return }
        attempt = nil
        previous.context.invalidate()
        previous.completion(.cancelled)
    }

    private func finish(_ id: UUID, _ result: TouchIDAuthenticationResult) {
        guard let previous = attempt, previous.id == id else { return }
        attempt = nil
        previous.context.invalidate()
        previous.completion(result)
    }
}
