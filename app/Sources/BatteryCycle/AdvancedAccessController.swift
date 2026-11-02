import AppKit
import Combine

/// Authorization only reveals settings for the current panel session. Display policies live
/// independently of this object, so hiding or locking the panel cannot turn them off.
@MainActor
final class AdvancedAccessController: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var message: String?
    /// Explicit revocation events, sent only after the gate is fully locked. Consumers must
    /// not infer revocation from isAuthenticating's normal transition to false on success.
    let lockEvents = PassthroughSubject<Void, Never>()

    private let authorizer: any AdminAuthorizing
    private var requestID: UUID?
    private var authorizationGeneration = UUID()
    private var terminating = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(authorizer: (any AdminAuthorizing)? = nil, observesSystemEvents: Bool = true,
         workspaceNotifications: NotificationCenter? = nil,
         applicationNotifications: NotificationCenter = .default,
         distributedNotifications: NotificationCenter? = nil) {
        self.authorizer = authorizer ?? TouchIDAdminAuthorization()
        guard observesSystemEvents else { return }
        let workspace = workspaceNotifications ?? NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name: name) { $0.lock() }
        }
        let distributed = distributedNotifications ?? DistributedNotificationCenter.default()
        observe(distributed, name: .init("com.apple.screenIsLocked")) { $0.lock() }
        observe(applicationNotifications, name: NSApplication.willTerminateNotification) { $0.prepareForTermination() }
    }

    /// Called by a deliberate click on Advanced Features, never by hover or app launch.
    @discardableResult
    func requestUnlock(isSessionValid: @escaping @MainActor () -> Bool = { true },
                       completion: AdminAuthorizationCompletion? = nil) -> Bool {
        guard !terminating, !isUnlocked, !isAuthenticating else { return false }
        guard isSessionValid() else { completion?(.cancelled); return false }
        let id = UUID()
        requestID = id
        authorizationGeneration = id
        message = nil
        isAuthenticating = true
        authorizer.authorize { [weak self] result in
            guard let self, !self.terminating, self.requestID == id else { return }
            self.requestID = nil
            self.isAuthenticating = false
            // Publishing authentication's end may synchronously close the host. Check the
            // owner again before publishing any unlocked state, never after showing settings.
            guard !self.terminating, self.authorizationGeneration == id else { return }
            let sessionValid = isSessionValid()
            guard !self.terminating, self.authorizationGeneration == id else { return }
            let effectiveResult: AdminAuthorizationResult = sessionValid ? result : .cancelled
            switch effectiveResult {
            case .authorized:
                self.isUnlocked = true
            case .cancelled:
                self.isUnlocked = false
            case let .failed(reason):
                self.isUnlocked = false
                self.message = reason
            }
            completion?(effectiveResult)
        }
        return true
    }

    /// The owner must call this when the hosting panel actually closes or returns to main.
    /// Security Agent taking focus while the controlled popover stays shown is not a close.
    func lock() {
        requestID = nil
        authorizationGeneration = UUID()
        isUnlocked = false
        isAuthenticating = false
        message = nil
        authorizer.cancel()
        lockEvents.send()
    }

    func prepareForTermination() {
        terminating = true
        lock()
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name,
                         action: @escaping @MainActor (AdvancedAccessController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }
}
