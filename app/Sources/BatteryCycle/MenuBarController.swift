import AppKit
import SwiftUI

/// Owns one anchored menu. Authentication may temporarily take focus without
/// changing the lifetime of the menu's authorization session.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let navigation: MenuNavigationController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var escapeMonitor: Any?
    private var authenticationMode = false
    private var modeRevision: UInt64 = 0
    private var requestedHeight: CGFloat = 650
    private var resizeScheduled = false
    private var isClosing = false
    private var isStopped = false

    init(navigation: MenuNavigationController, image: NSImage,
         makeContent: (@escaping (CGFloat) -> Void) -> AnyView) {
        self.navigation = navigation
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.delegate = self
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 300, height: requestedHeight)
        popover.contentViewController = NSHostingController(rootView: makeContent { [weak self] height in
            self?.requestHeight(height)
        })

        if let button = statusItem.button {
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.target = self
            button.action = #selector(toggleMenu(_:))
            button.setAccessibilityLabel("BatteryCycle")
        }
        navigation.bindHost(
            isShown: { [weak self] in
                guard let self else { return false }
                return !self.isStopped && !self.isClosing && self.popover.isShown
            },
            setAuthenticationMode: { [weak self] enabled in
                self?.setAuthenticationMode(enabled)
            }
        )
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown, event.keyCode == 53 else { return event }
            self.popover.performClose(nil)
            return nil
        }
    }

    func updateImage(_ image: NSImage) {
        guard !isStopped else { return }
        statusItem.button?.image = image
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        isClosing = true
        modeRevision &+= 1
        authenticationMode = false
        navigation.prepareForTermination()
        if popover.isShown { popover.performClose(nil) }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func toggleMenu(_ sender: Any?) {
        guard !isStopped else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem.button else { return }
        isClosing = false
        authenticationMode = false
        modeRevision &+= 1
        popover.behavior = .transient
        applyRequestedHeight()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if popover.isShown {
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        guard !isStopped, !isClosing, popover.isShown else { return }
        navigation.didShow()
    }

    func popoverWillClose(_ notification: Notification) {
        // Revoke access before any closing animation or late authorization result.
        isClosing = true
        modeRevision &+= 1
        authenticationMode = false
        navigation.didClose()
    }

    func popoverDidClose(_ notification: Notification) {
        if !popover.isShown { popover.behavior = .transient }
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }

    private func setAuthenticationMode(_ enabled: Bool) {
        modeRevision &+= 1
        let revision = modeRevision
        authenticationMode = enabled
        guard !isStopped, !isClosing, popover.isShown else { return }
        if enabled {
            popover.behavior = .applicationDefined
            return
        }

        // SecurityAgent can still be resigning key status when its completion
        // arrives. Focus the existing menu, then restore automatic dismissal.
        // Neither operation is allowed to reopen a closed menu.
        popover.contentViewController?.view.window?.makeKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped, !self.isClosing,
                  self.popover.isShown, !self.authenticationMode,
                  self.modeRevision == revision else { return }
            self.popover.behavior = .transient
        }
    }

    private func requestHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0, !isStopped else { return }
        requestedHeight = ceil(height)
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            guard !self.isStopped else { return }
            self.applyRequestedHeight()
        }
    }

    private func applyRequestedHeight() {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let availableHeight = max(1, (screen?.visibleFrame.height ?? 766) - 16)
        let size = NSSize(width: 300, height: min(requestedHeight, floor(availableHeight)))
        guard abs(popover.contentSize.height - size.height) >= 1
                || popover.contentSize.width != size.width else { return }
        popover.contentSize = size
    }
}
