import Foundation
import Security

/// The result contains no username, password, AuthorizationRef, or transferable credential.
enum AdminAuthorizationResult: Equatable, Sendable {
    case authorized
    case cancelled
    case failed(String)
}

typealias AdminAuthorizationCompletion = @MainActor @Sendable (AdminAuthorizationResult) -> Void

@MainActor
protocol AdminAuthorizing: AnyObject {
    func authorize(completion: @escaping AdminAuthorizationCompletion)
    func cancel()
}

/// App-specific, password-only administrator authorization. Only the system Security Agent
/// collects credentials; no password fields or credential retrieval APIs are used in the app.
///
/// `password-only` is an Apple authd policy field, not a stable public API. authd reads it in
/// rule.c and forces Security Agent's password-only UI in engine.m. Always verify it survives
/// registration/readback; unsupported systems fail closed instead of accepting biometrics.
/// https://github.com/apple-oss-distributions/Security/blob/main/OSX/authd/engine.m
/// https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_authorization/lib/AuthorizationTagsPriv.h
@MainActor
final class AdminAuthorization: AdminAuthorizing {
    private var attempt: NativeAdminAuthorizationAttempt?

    func authorize(completion: @escaping AdminAuthorizationCompletion) {
        cancel()
        let id = UUID()
        let request = NativeAdminAuthorizationAttempt(id: id) { [weak self] result in
            Task { @MainActor in
                if self?.attempt?.id == id { self?.attempt = nil }
                completion(result)
            }
        }
        attempt = request
        request.start()
    }

    func cancel() {
        let previous = attempt
        attempt = nil
        previous?.cancel()
    }
}

/// Kept separate from native API calls so permissive/cached/unsupported policies can be tested
/// without creating rights or requesting real authentication on the developer's machine.
enum AdminAuthorizationPolicy {
    static let rightName = "com.local.batterycycle.advanced-settings.password.v1"
    static let prompt = "解锁电池循环的高级功能"
    static var definition: [String: Any] {
        ["class": "user", "group": "admin", "authenticate-user": true,
         "shared": false, "timeout": 0, "allow-root": false, "session-owner": false,
         "password-only": true, "tries": 3,
         "comment": "Password-only administrator access to BatteryCycle advanced settings."]
    }

    static func matches(_ value: [String: Any]) -> Bool {
        guard value["class"] as? String == "user", value["group"] as? String == "admin",
              boolean(value["authenticate-user"]) == true,
              boolean(value["password-only"]) == true,
              boolean(value["shared"]) == false, boolean(value["allow-root"]) == false,
              boolean(value["session-owner"]) == false,
              let timeout = value["timeout"] as? NSNumber,
              CFGetTypeID(timeout) != CFBooleanGetTypeID(), timeout.doubleValue == 0,
              value["rule"] == nil, value["mechanisms"] == nil else { return false }
        for key in ["entitled", "entitled-and-group", "vpn-entitled-and-group", "extract-password"] {
            if let present = value[key], boolean(present) != false { return false }
        }
        return true
    }

    static func acceptsGrantedRight(name: String, flags: UInt32) -> Bool {
        name == rightName && flags & UInt32(kAuthorizationFlagCanNotPreAuthorize) == 0
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

/// Mutable native state is protected by the lock. The reference is published only after
/// registration finishes. CopyRightsAsync synchronously copies its input/reference blob
/// before returning (Apple's Authorization.c), so cancellation can then destroy that reference
/// without freeing memory used by an in-flight client call. No API call blocks the UI thread.
private final class NativeAdminAuthorizationAttempt: @unchecked Sendable {
    let id: UUID
    private let completion: @Sendable (AdminAuthorizationResult) -> Void
    private let mutex = NSLock()
    private var authorization: AuthorizationRef?
    private var finished = false

    init(id: UUID, completion: @escaping @Sendable (AdminAuthorizationResult) -> Void) {
        self.id = id
        self.completion = completion
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { self.prepareAndRequest() }
    }

    func cancel() { finish(.cancelled) }

    private func prepareAndRequest() {
        mutex.lock()
        let alreadyFinished = finished
        mutex.unlock()
        guard !alreadyFinished else { return }

        var created: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &created)
        guard status == errAuthorizationSuccess, let created else {
            finish(.failed("无法开始管理员验证，请稍后重试（\(status)）"))
            return
        }
        var transferred = false
        defer { if !transferred { _ = AuthorizationFree(created, [.destroyRights]) } }

        let policyResult = preparePolicy(authorization: created)
        guard policyResult == errAuthorizationSuccess else {
            finish(policyFailure(policyResult))
            return
        }

        AdminAuthorizationPolicy.rightName.withCString { rightName in
            var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
            withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                kAuthorizationEnvironmentPrompt.withCString { promptKey in
                    var prompt = Array(AdminAuthorizationPolicy.prompt.utf8)
                    prompt.withUnsafeMutableBytes { bytes in
                        var promptItem = AuthorizationItem(name: promptKey, valueLength: bytes.count,
                                                           value: bytes.baseAddress, flags: 0)
                        withUnsafeMutablePointer(to: &promptItem) { promptPointer in
                            var environment = AuthorizationEnvironment(count: 1, items: promptPointer)
                            mutex.lock()
                            guard !finished else { mutex.unlock(); return }
                            authorization = created
                            transferred = true
                            // No preAuthorize/partialRights/skipInternalAuth flags. A successful
                            // request must include the exact right, actually authorized.
                            AuthorizationCopyRightsAsync(created, &rights, &environment,
                                                         [.interactionAllowed, .extendRights]) { status, granted in
                                let grantedExactRight = Self.hasExactGrant(granted)
                                if let granted { _ = AuthorizationFreeItemSet(granted) }
                                DispatchQueue.global(qos: .userInitiated).async {
                                    let result: AdminAuthorizationResult
                                    if status == errAuthorizationCanceled {
                                        result = .cancelled
                                    } else if status == errAuthorizationSuccess && grantedExactRight {
                                        result = Self.policyIsExpected()
                                            ? .authorized
                                            : .failed("管理员授权规则已变更，未解锁高级功能")
                                    } else {
                                        result = .failed("管理员验证未通过，请重试（\(status)）")
                                    }
                                    self.finish(result)
                                }
                            }
                            mutex.unlock()
                        }
                    }
                }
            }
        }
    }

    private func finish(_ result: AdminAuthorizationResult) {
        mutex.lock()
        guard !finished else { mutex.unlock(); return }
        finished = true
        let reference = authorization
        authorization = nil
        mutex.unlock()
        // Authorize/Free can contact authd synchronously. Never make panel close wait on it.
        DispatchQueue.global(qos: .userInitiated).async {
            if let reference { _ = AuthorizationFree(reference, [.destroyRights]) }
            self.completion(result)
        }
    }

    private func preparePolicy(authorization: AuthorizationRef) -> OSStatus {
        var policy: CFDictionary?
        let read = AuthorizationRightGet(AdminAuthorizationPolicy.rightName, &policy)
        if read == errAuthorizationDenied {
            // Register this app's exact right only after a deliberate user unlock request.
            // Never modify built-in rules or silently replace an administrator's existing rule.
            let registration = AuthorizationRightSet(authorization, AdminAuthorizationPolicy.rightName,
                                                      AdminAuthorizationPolicy.definition as CFDictionary,
                                                      AdminAuthorizationPolicy.prompt as CFString, nil, nil)
            guard registration == errAuthorizationSuccess else { return registration }
        } else if read != errAuthorizationSuccess {
            return read
        }
        return Self.policyIsExpected() ? errAuthorizationSuccess : errAuthorizationDenied
    }

    private static func policyIsExpected() -> Bool {
        var policy: CFDictionary?
        guard AuthorizationRightGet(AdminAuthorizationPolicy.rightName, &policy) == errAuthorizationSuccess,
              let policy, let dictionary = policy as? [String: Any] else { return false }
        return AdminAuthorizationPolicy.matches(dictionary)
    }

    private func policyFailure(_ status: OSStatus) -> AdminAuthorizationResult {
        if status == errAuthorizationCanceled { return .cancelled }
        return .failed("无法确认管理员密码授权规则，未解锁高级功能（\(status)）")
    }

    private static func hasExactGrant(_ rights: UnsafeMutablePointer<AuthorizationRights>?) -> Bool {
        guard let rights, rights.pointee.count == 1, let items = rights.pointee.items else { return false }
        let item = items.pointee
        return AdminAuthorizationPolicy.acceptsGrantedRight(name: String(cString: item.name), flags: item.flags)
    }
}
