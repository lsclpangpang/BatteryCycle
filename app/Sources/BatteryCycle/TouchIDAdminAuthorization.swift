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
        // Match AdminAuthorization: a new request replaces the old one, whose caller is told
        // it was cancelled, so no completion is ever silently dropped.
        let id = UUID()
        replaceAttempt(with: Attempt(id: id, phase: .initialIdentity, completion: completion))
        // The old caller may have started yet another request, which replaced this one.
        guard attempt?.id == id else { return }
        identityChecker.check { [weak self] identity in
            guard let self, self.isCurrent(id, phase: .initialIdentity) else { return }
            guard let uid = identity?.eligibleUID else { self.requestPassword(id); return }
            self.attempt?.phase = .touchID(uid)
            self.touchID.authenticate { [weak self] result in self?.didAuthenticate(result, id: id, uid: uid) }
        }
    }

    func cancel() { replaceAttempt(with: nil) }

    private func replaceAttempt(with next: Attempt?) {
        let previous = attempt
        // Invalidate ownership before invalidating LAContext or AuthorizationRef, since their
        // cancellation replies may arrive synchronously or after a new request has started.
        // Install the next request before telling the old caller, so a request it starts from
        // its completion goes through this same path instead of being overwritten afterwards.
        attempt = next
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
        let administrator = DirectoryMembership.isAdministrator(uid: realUID)
        // Do not return a stale mixed snapshot if a console or process identity changed
        // while Directory Services was answering the membership request.
        guard getuid() == realUID, geteuid() == effectiveUID, consoleUID() == console else { return nil }
        return .init(realUID: realUID, effectiveUID: effectiveUID, consoleUID: console,
                     isAdministrator: administrator)
    }
}

/// membership.h is public but is not exported by the Swift Darwin module. Resolve its public
/// libSystem symbols once, using their exact C declarations from that header.
private enum DirectoryMembership {
    private typealias UIDToUUID = @convention(c) (uid_t, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias GIDToUUID = @convention(c) (gid_t, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias CheckMembership = @convention(c) (UnsafePointer<UInt8>, UnsafePointer<UInt8>, UnsafeMutablePointer<Int32>) -> Int32
    private struct Functions {
        let uidToUUID: UIDToUUID
        let gidToUUID: GIDToUUID
        let checkMembership: CheckMembership
    }

    /// macOS reserves gid 80 for the admin group.
    private static let adminGID: gid_t = 80

    /// The handle is never closed; libSystem stays loaded for the life of the process.
    private static let functions: Functions? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let uidSymbol = dlsym(handle, "mbr_uid_to_uuid"),
              let gidSymbol = dlsym(handle, "mbr_gid_to_uuid"),
              let checkSymbol = dlsym(handle, "mbr_check_membership") else { return nil }
        return Functions(uidToUUID: unsafeBitCast(uidSymbol, to: UIDToUUID.self),
                         gidToUUID: unsafeBitCast(gidSymbol, to: GIDToUUID.self),
                         checkMembership: unsafeBitCast(checkSymbol, to: CheckMembership.self))
    }()

    static func isAdministrator(uid: uid_t) -> Bool? {
        guard let functions = Self.functions else { return nil }
        var user = [UInt8](repeating: 0, count: 16)
        var group = [UInt8](repeating: 0, count: 16)
        let userStatus = user.withUnsafeMutableBufferPointer { functions.uidToUUID(uid, $0.baseAddress!) }
        let groupStatus = group.withUnsafeMutableBufferPointer { functions.gidToUUID(adminGID, $0.baseAddress!) }
        guard userStatus == 0, groupStatus == 0 else { return nil }
        var member: Int32 = 0
        let status = user.withUnsafeBufferPointer { user in
            group.withUnsafeBufferPointer { group in functions.checkMembership(user.baseAddress!, group.baseAddress!, &member) }
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
        // Never reuse a successfully evaluated context or a recent device-unlock grant.
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = TouchIDAuthenticationPolicy.reuseDuration
        context.localizedFallbackTitle = TouchIDAuthenticationPolicy.fallbackTitle
        context.localizedCancelTitle = "取消"
        let id = UUID()
        replaceAttempt(with: Attempt(id: id, context: context, completion: completion))
        guard attempt?.id == id else { return }
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

    func cancel() { replaceAttempt(with: nil) }

    private func replaceAttempt(with next: Attempt?) {
        let previous = attempt
        attempt = next
        guard let previous else { return }
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
