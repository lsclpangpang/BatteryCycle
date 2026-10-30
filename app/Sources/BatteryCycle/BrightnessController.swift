import AppKit
import Combine

/// Lives with the app, not the menu. Closing the popover must not restore brightness.
@MainActor
final class BrightnessController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsRecovery = false
    @Published private(set) var message: String?
    @Published private(set) var needsKeyboardPermission = false

    private let backend: any BrightnessBackend
    private let session: MinimumBrightnessSession
    private let lease: (any BrightnessControlLeasing)?
    private var ownsControl = false
    private let events = NativeBrightnessEvents()
    private let restoreShortcut: (any BrightnessRestoreShortcutHandling)?
    private var shortcutReady = false
    private let keyboard: (any BrightnessKeyMonitoring)?
    private var keyboardReady = false
    private var manualAdjustmentPending = false
    private var pendingManualFinish: DispatchWorkItem?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var pendingCheck: DispatchWorkItem?
    private var systemAsleep = false
    private var screensAsleep = false
    private var wakeDeadline: Date?
    private var observingChanges = false
    private var terminating = false
    private let observesSystemEvents: Bool

    init(backend: any BrightnessBackend = NativeBrightnessBackend(),
         store: any BrightnessRecoveryStore = FileBrightnessRecoveryStore(),
         observesSystemEvents: Bool = true,
         shortcut: (any BrightnessRestoreShortcutHandling)? = nil,
         keyboard: (any BrightnessKeyMonitoring)? = nil,
         lease: (any BrightnessControlLeasing)? = nil,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.backend = backend
        self.session = MinimumBrightnessSession(backend: backend, store: store, uptime: uptime)
        self.lease = lease ?? (observesSystemEvents ? FileBrightnessControlLease() : nil)
        self.observesSystemEvents = observesSystemEvents
        self.restoreShortcut = shortcut ?? (observesSystemEvents ? BrightnessRestoreShortcut() : nil)
        self.keyboard = keyboard ?? (observesSystemEvents ? NativeBrightnessKeyMonitor() : nil)
        // A previous crash is recovered before accepting a new activation. Never auto-enable.
        recover()
        guard observesSystemEvents else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.setSleeping(system: true, asleep: true) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.setSleeping(system: true, asleep: false) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.setSleeping(system: false, asleep: true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.setSleeping(system: false, asleep: false) }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { controller in
            controller.restartObservation()
            controller.wakeDeadline = Date().addingTimeInterval(3)
            controller.scheduleCheck()
        }
        observe(.default, NSApplication.willTerminateNotification) { $0.prepareForTermination() }
        observe(.default, NSApplication.didBecomeActiveNotification) { $0.refreshKeyboardPermission() }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setEnabled(_ enabled: Bool) {
        guard !terminating else { return }
        guard acquireControl() else { return }
        if manualAdjustmentPending { finishManualAdjustment() }
        message = nil
        if enabled, !ensureKeyboardMonitor() {
            refreshKeyboardPermission()
            message = needsKeyboardPermission
                ? "请先允许输入监控，以便直接按亮度键退出最低亮度模式"
                : "无法识别亮度按键，未调整屏幕；请稍后重试"
            return
        }
        do {
            if enabled { try session.enable() } else { try session.disable() }
        } catch {
            message = error.localizedDescription
        }
        publishState()
    }

    func recover() {
        guard !terminating, acquireControl() else { return }
        cancelManualFinish()
        message = nil
        do { try session.recover() } catch { message = error.localizedDescription }
        publishState()
    }

    /// Synchronous: a Task created by willTerminate may never execute before process exit.
    func prepareForTermination() {
        terminating = true
        pendingCheck?.cancel()
        cancelManualFinish()
        timer?.invalidate()
        stopObservation()
        stopRestoreShortcut()
        stopKeyboardMonitor()
        if ownsControl {
            do { try session.disable() } catch { message = error.localizedDescription }
            lease?.release()
            ownsControl = false
        }
        isEnabled = session.isEnabled
        needsRecovery = false
    }

    func setSleeping(system: Bool, asleep: Bool) {
        if system { systemAsleep = asleep } else { screensAsleep = asleep }
        if asleep {
            pendingCheck?.cancel()
            pendingCheck = nil
            stopObservation()
        } else {
            wakeDeadline = Date().addingTimeInterval(3)
            scheduleCheck()
        }
    }

    private func scheduleCheck() {
        guard !terminating, !systemAsleep, !screensAsleep else { return }
        // Coalesce our own write notifications and bursts of display reconfiguration.
        guard pendingCheck == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingCheck = nil
                self?.check(afterEvent: true)
            }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func check(afterEvent: Bool = false) {
        refreshKeyboardPermission()
        guard !terminating, ownsControl, !manualAdjustmentPending, !systemAsleep, !screensAsleep,
              isEnabled || (needsRecovery && (afterEvent || wakeDeadline != nil)) else { return }
        if let deadline = wakeDeadline, Date() < deadline {
            // A panel can be temporarily absent while waking. Do not abandon the session then.
            guard (try? backend.snapshot()) != nil else { return }
        }
        wakeDeadline = nil
        do {
            if session.isEnabled { try session.enforce() } else { try session.recover() }
            message = nil
        } catch {
            message = error.localizedDescription
        }
        publishState()
    }

    private func publishState() {
        isEnabled = session.isEnabled
        needsRecovery = ownsControl && !manualAdjustmentPending && session.needsRecovery
        needsKeyboardPermission = keyboard?.requiresPermission ?? false
        if !isEnabled, !manualAdjustmentPending { stopKeyboardMonitor() }
        if !isEnabled, !needsRecovery {
            stopRestoreShortcut()
        } else if !terminating {
            // Brightness keys are the primary exit. A reserved optional shortcut must not
            // prevent activation when the physical key monitor is available.
            _ = ensureRestoreShortcut()
        }
        if isEnabled, !terminating, !systemAsleep, !screensAsleep {
            startObservation()
        } else {
            stopObservation()
        }
    }

    private func startObservation() {
        guard observesSystemEvents, !observingChanges else { return }
        observingChanges = events.start { [weak self] in
            // Native callbacks may arrive on a display service thread.
            Task { @MainActor in self?.scheduleCheck() }
        }
    }

    func requestKeyboardPermission() {
        keyboard?.requestPermission()
        refreshKeyboardPermission()
    }

    /// Access granted in System Settings takes effect without relaunching; the panel
    /// rechecks on open so the permission button disappears.
    func refreshKeyboardPermission() {
        needsKeyboardPermission = keyboard?.requiresPermission ?? false
        if isEnabled, needsKeyboardPermission { keyboardUnavailable() }
    }

    private func ensureKeyboardMonitor() -> Bool {
        guard !keyboardReady, let keyboard else { return true }
        keyboardReady = keyboard.start(onKey: { [weak self] key in
            MainActor.assumeIsolated { self?.brightnessKeyPressed(key) }
        }, onUnavailable: { [weak self] in
            MainActor.assumeIsolated { self?.keyboardUnavailable() }
        })
        return keyboardReady
    }

    private func stopKeyboardMonitor() {
        keyboard?.stop()
        keyboardReady = false
    }

    private func keyboardUnavailable() {
        guard !terminating else { return }
        setEnabled(false)
        message = "亮度按键监听已停止，已退出最低亮度模式" + (message.map { "；" + $0 } ?? "")
    }

    private func brightnessKeyPressed(_ key: BrightnessKeyPress) {
        guard !terminating, isEnabled || manualAdjustmentPending else { return }
        pendingCheck?.cancel()
        pendingCheck = nil
        pendingManualFinish?.cancel()
        manualAdjustmentPending = true
        message = nil
        do {
            try session.beginManualAdjustment(keyTimestamp: key.timestamp,
                                              increasesBrightness: key.direction == .increase)
        } catch {
            message = error.localizedDescription
            manualAdjustmentPending = false
            publishState()
            return
        }
        publishState()
        // Do not consume or replay the key. Let macOS perform this press (including repeats)
        // before restoring the user's automatic-brightness preference.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finishManualAdjustment() }
        }
        pendingManualFinish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func finishManualAdjustment() {
        guard manualAdjustmentPending else { return }
        cancelManualFinish()
        do { try session.finishManualAdjustment() } catch { message = error.localizedDescription }
        publishState()
    }

    private func cancelManualFinish() {
        pendingManualFinish?.cancel()
        pendingManualFinish = nil
        manualAdjustmentPending = false
    }

    /// Ownership precedes all journal reads as well as hardware writes. Keep it even while
    /// idle so a second app cannot cache an empty journal and overwrite a later active one.
    private func acquireControl() -> Bool {
        if ownsControl { return true }
        do {
            try lease?.acquire()
            ownsControl = true
            return true
        } catch {
            message = error.localizedDescription
            publishState()
            return false
        }
    }

    private func ensureRestoreShortcut() -> Bool {
        guard !shortcutReady, let restoreShortcut else { return true }
        shortcutReady = restoreShortcut.start { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isEnabled { self.setEnabled(false) } else { self.recover() }
            }
        }
        return shortcutReady
    }

    private func stopRestoreShortcut() {
        restoreShortcut?.stop()
        shortcutReady = false
    }

    private func stopObservation() {
        events.stop()
        observingChanges = false
    }

    private func restartObservation() {
        stopObservation()
        if isEnabled, !systemAsleep, !screensAsleep { startObservation() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (BrightnessController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        observers.append((center, token))
    }

    deinit {
        lease?.release()
        timer?.invalidate()
        pendingCheck?.cancel()
        pendingManualFinish?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
    }
}
