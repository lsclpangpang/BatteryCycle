import AppKit
import Combine

@MainActor
final class DisplayOutputRestrictionController: ObservableObject {
    @Published private(set) var settings = DisplayRestrictionSettings()
    @Published private(set) var message: String?

    private let session: DisplayRestrictionSession
    private let lease: (any DisplayRestrictionLeasing)?
    private let canChangeSettings: () -> Bool
    private var ownsControl = false
    private var terminating = false
    private var systemAsleep = false
    private var screensAsleep = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var pendingCheck: DispatchWorkItem?
    private var lastCheckAt: TimeInterval = 0
    private var lastTriggerAt: TimeInterval = 0

    init(backend: any DisplayOutputBackend = NativeDisplayOutputBackend(),
         store: any DisplayRestrictionStoring = FileDisplayRestrictionStore(),
         lease: (any DisplayRestrictionLeasing)? = nil,
         canChangeSettings: @escaping () -> Bool,
         isUsable: @escaping (DisplayOutputSnapshot) -> Bool = { $0.isEnabled },
         observesSystemEvents: Bool = true) {
        self.session = DisplayRestrictionSession(backend: backend, store: store, isUsable: isUsable)
        self.lease = lease ?? (observesSystemEvents ? FileDisplayRestrictionLease() : nil)
        self.canChangeSettings = canChangeSettings
        _ = acquireControl()
        guard observesSystemEvents else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.setSleeping(system: true, asleep: true) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.setSleeping(system: true, asleep: false) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.setSleeping(system: false, asleep: true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.setSleeping(system: false, asleep: false) }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.scheduleCheck() }
        observe(.default, NSApplication.willTerminateNotification) { $0.prepareForTermination() }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setRestricted(_ port: DisplayOutputPort, _ restricted: Bool) {
        guard !terminating else { return }
        guard canChangeSettings() else { message = "请先验证管理员身份"; return }
        guard acquireControl() else { return }
        do { try session.setRestricted(port, restricted); message = nil }
        catch { message = error.localizedDescription }
        publish()
    }

    func retry() {
        guard canChangeSettings(), !terminating, acquireControl() else { return }
        check(force: true)
    }

    /// Without the lease another copy enforces the journal (or nothing can), so the
    /// legacy switch is not locked out by this copy.
    func permitsLegacyEnabling(displayID: UInt32, identity: DisplayRestrictionRecord? = nil) -> Bool {
        guard !terminating else { return false }
        guard ownsControl else { return true }
        return session.permitsEnabling(displayID: displayID, identity: identity)
    }

    func captureLegacyIdentity(displayID: UInt32) -> DisplayRestrictionRecord? {
        guard ownsControl, !terminating else { return nil }
        return session.captureIdentity(displayID: displayID)
    }

    func ownedDisplayModels() -> [DisplayOutputModel: Int] {
        guard ownsControl, !terminating else { return [:] }
        return session.ownedModels
    }

    func permitsMinimumBrightness() -> Bool {
        !terminating && (!ownsControl || session.permitsMinimumBrightness())
    }

    func check(force: Bool = false) {
        guard !terminating, !systemAsleep, !screensAsleep,
              ownsControl, force || settings.isActive || session.hasRecovery || session.needsReload else { return }
        lastCheckAt = ProcessInfo.processInfo.systemUptime
        do { try session.reconcile(); message = nil }
        catch { message = error.localizedDescription }
        publish()
    }

    func setSleeping(system: Bool, asleep: Bool) {
        if system { systemAsleep = asleep } else { screensAsleep = asleep }
        if asleep {
            pendingCheck?.cancel()
            pendingCheck = nil
        } else { scheduleCheck() }
    }

    /// Synchronous restoration: a Task queued during termination may never execute.
    func prepareForTermination() {
        guard !terminating else { return }
        terminating = true
        pendingCheck?.cancel()
        pendingCheck = nil
        timer?.invalidate()
        if ownsControl {
            do { try session.restoreReleased(); message = nil }
            catch { message = error.localizedDescription }
            lease?.release()
            ownsControl = false
        }
    }

    private func acquireControl() -> Bool {
        if ownsControl { return true }
        do { try lease?.acquire() }
        catch { message = error.localizedDescription; return false }
        ownsControl = true
        do { try session.start(); message = nil }
        catch { message = error.localizedDescription }
        publish()
        return true
    }

    private func publish() { settings = session.settings }

    /// Each check reads the IOKit registry several times on the main thread. Screen changes and
    /// wake already schedule one, so poll quickly only while an attempt awaits confirmation or a
    /// just-attached display's interface is still settling, every few seconds while a released
    /// display awaits replug or an error is shown, and otherwise as a rare safety net.
    private func pollIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        let settling = session.hasUncertainTransport && now - lastTriggerAt < 10
        let interval: TimeInterval = session.hasPendingAttempts || session.needsReload || settling ? 1
            : session.hasReleasedRecovery ? 3
            : message != nil ? 5 : 30
        guard now - lastCheckAt >= interval else { return }
        check()
    }

    private func scheduleCheck() {
        lastTriggerAt = ProcessInfo.processInfo.systemUptime
        guard pendingCheck == nil, !terminating, !systemAsleep, !screensAsleep else { return }
        let pending = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingCheck = nil
                self?.check()
            }
        }
        pendingCheck = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: pending)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (DisplayOutputRestrictionController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        observers.append((center, token))
    }

    deinit {
        for (center, observer) in observers { center.removeObserver(observer) }
        timer?.invalidate()
    }
}
