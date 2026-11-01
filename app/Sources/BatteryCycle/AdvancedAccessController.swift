import AppKit
import Combine

/// Authorization only reveals settings for the current panel session. Display policies live
/// independently of this object, so hiding or locking the panel cannot turn them off.
@MainActor
final class AdvancedAccessController: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var message: String?

    private let authorizer: any AdminAuthorizing
    private var requestID: UUID?
    private var terminating = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(authorizer: (any AdminAuthorizing)? = nil, observesSystemEvents: Bool = true,
         workspaceNotifications: NotificationCenter? = nil,
         applicationNotifications: NotificationCenter = .default,
         distributedNotifications: NotificationCenter? = nil) {
        self.authorizer = authorizer ?? AdminAuthorization()
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
    func requestUnlock() {
        guard !terminating, !isUnlocked, !isAuthenticating else { return }
        let id = UUID()
        requestID = id
        message = nil
        isAuthenticating = true
        authorizer.authorize { [weak self] result in
            guard let self, !self.terminating, self.requestID == id else { return }
            self.requestID = nil
            self.isAuthenticating = false
            switch result {
            case .authorized:
                self.isUnlocked = true
            case .cancelled:
                self.isUnlocked = false
            case let .failed(reason):
                self.isUnlocked = false
                self.message = reason
            }
        }
    }

    /// The owner must call this when its advanced settings window actually closes.
    /// Security Agent taking focus from the menu is not a new authorization session.
    func lock() {
        requestID = nil
        isUnlocked = false
        isAuthenticating = false
        message = nil
        authorizer.cancel()
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
