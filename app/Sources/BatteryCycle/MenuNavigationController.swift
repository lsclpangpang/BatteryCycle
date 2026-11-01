import Foundation
import Combine

enum MenuPage: Equatable {
    case main
    case advanced
}

/// A single anchored popover owns one authorization session. Native focus changes do not
/// navigate; an actual close, explicit Back, or an external security lock revokes access.
@MainActor
final class MenuNavigationController: ObservableObject {
    @Published private(set) var page: MenuPage = .main
    @Published private(set) var isPresented = false

    private let access: AdvancedAccessController
    private var hostIsShown: @MainActor () -> Bool = { false }
    private var hostSetAuthenticationMode: @MainActor (Bool) -> Void = { _ in }
    private var hasHost = false
    private var presentationNonce: UUID?
    private var authenticationNonce: UUID?
    private var authenticationMode = false
    private var handlingClose = false
    private var terminating = false
    private var lockSubscription: AnyCancellable?

    init(access: AdvancedAccessController) {
        self.access = access
        lockSubscription = access.lockEvents.sink { [weak self] in self?.accessDidLock() }
    }

    func bindHost(isShown: @escaping @MainActor () -> Bool,
                  setAuthenticationMode: @escaping @MainActor (Bool) -> Void) {
        if hasHost { didClose() }
        hostIsShown = isShown
        hostSetAuthenticationMode = setAuthenticationMode
        hasHost = true
    }

    func didShow() {
        guard !terminating, hasHost, hostIsShown(), !isPresented else { return }
        isPresented = true
        presentationNonce = UUID()
        authenticationNonce = nil
        page = .main
        access.lock()
    }

    /// Called from native willClose, before the popover's closing animation has finished.
    /// The guard also permits a synchronous close from restoring transient behavior.
    func didClose() {
        guard !handlingClose else { return }
        guard isPresented || authenticationNonce != nil || authenticationMode || page != .main
                || access.isUnlocked || access.isAuthenticating else { return }
        handlingClose = true
        defer { handlingClose = false }
        isPresented = false
        presentationNonce = nil
        authenticationNonce = nil
        page = .main
        setAuthenticationMode(false)
        access.lock()
    }

    func openAdvanced() {
        guard !terminating, hasHost, isPresented, page == .main,
              authenticationNonce == nil, !access.isAuthenticating else { return }
        guard hostIsShown() else { didClose(); return }
        // An unlock performed by another UI owner is never borrowed by this popover.
        if access.isUnlocked { access.lock() }
        guard let presentation = presentationNonce, isPresented, hostIsShown() else { return }
        let request = UUID()
        authenticationNonce = request
        setAuthenticationMode(true)
        // Pinning is native code and may itself close the host. Do not start a prompt then.
        guard sessionMatches(presentation: presentation, request: request) else {
            if authenticationNonce == request { didClose() }
            return
        }
        let started = access.requestUnlock(isSessionValid: { [weak self] in
            self?.sessionMatches(presentation: presentation, request: request) ?? false
        }, completion: { [weak self] result in
            self?.authenticationFinished(result, presentation: presentation, request: request)
        })
        if !started, authenticationNonce == request {
            authenticationFinished(.cancelled, presentation: presentation, request: request)
        }
    }

    func back() {
        authenticationNonce = nil
        page = .main
        setAuthenticationMode(false)
        access.lock()
    }

    func prepareForTermination() {
        guard !terminating else { return }
        terminating = true
        didClose()
        access.prepareForTermination()
    }

    private func sessionMatches(presentation: UUID, request: UUID) -> Bool {
        !terminating && isPresented && presentationNonce == presentation
            && authenticationNonce == request && hostIsShown()
    }

    private func authenticationFinished(_ result: AdminAuthorizationResult,
                                        presentation: UUID, request: UUID) {
        guard authenticationNonce == request, presentationNonce == presentation else { return }
        guard sessionMatches(presentation: presentation, request: request) else { didClose(); return }
        setAuthenticationMode(false)
        // Returning to transient may synchronously invoke native willClose. A result from
        // that closed session must not enter Advanced or reopen the status-item popover.
        guard sessionMatches(presentation: presentation, request: request) else {
            if authenticationNonce == request { didClose() }
            return
        }
        authenticationNonce = nil
        if result == .authorized, access.isUnlocked {
            page = .advanced
        } else {
            page = .main
        }
    }

    private func setAuthenticationMode(_ enabled: Bool) {
        guard authenticationMode != enabled else { return }
        authenticationMode = enabled
        hostSetAuthenticationMode(enabled)
    }

    private func accessDidLock() {
        authenticationNonce = nil
        page = .main
        if isPresented && hostIsShown() {
            presentationNonce = UUID()
        } else {
            isPresented = false
            presentationNonce = nil
        }
        setAuthenticationMode(false)
    }
}
