import AppKit
import Combine
import SwiftUI

/// A normal panel survives Security Agent taking focus. Its lifetime, rather than the
/// menu popover's focus, owns authorization, so a later menu opening cannot inherit it.
@MainActor
final class AdvancedFeaturesWindow: NSObject, ObservableObject, NSWindowDelegate {
    private let access: AdvancedAccessController
    private let restrictions: DisplayOutputRestrictionController
    private var panel: NSPanel?
    private var hosting: NSHostingView<AdvancedFeaturesView>?
    private var updates: AnyCancellable?

    init(access: AdvancedAccessController, restrictions: DisplayOutputRestrictionController) {
        self.access = access
        self.restrictions = restrictions
        super.init()
        updates = access.objectWillChange.merge(with: restrictions.objectWillChange).sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitContent() }
        }
    }

    func show() {
        if let panel, panel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        access.lock()
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 140),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "高级功能"
        window.hidesOnDeactivate = false
        window.isFloatingPanel = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSHostingView(rootView: AdvancedFeaturesView(access: access, restrictions: restrictions))
        window.contentView = content
        hosting = content
        panel = window
        fitContent()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, window?.isVisible == true, self.panel === window else { return }
            self.access.requestUnlock()
        }
    }

    func windowWillClose(_ notification: Notification) {
        access.lock()
        panel = nil
        hosting = nil
    }

    private func fitContent() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 300, height: max(100, hosting.fittingSize.height)))
    }
}

private struct AdvancedFeaturesView: View {
    @ObservedObject var access: AdvancedAccessController
    @ObservedObject var restrictions: DisplayOutputRestrictionController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if access.isUnlocked {
                SwitchRow(title: "禁止 HDMI 显示输出", isOn: Binding(
                    get: { restrictions.settings.hdmi },
                    set: { restrictions.setRestricted(.hdmi, $0) }
                ))
                SwitchRow(title: "禁止 USB-C / 雷雳显示输出", isOn: Binding(
                    get: { restrictions.settings.usbC },
                    set: { restrictions.setRestricted(.usbC, $0) }
                ))
                if let message = restrictions.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试") { restrictions.retry() }
                        .font(.caption)
                }
            } else if access.isAuthenticating {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在验证管理员身份…")
                }
            } else {
                Text(access.message ?? "需要管理员密码")
                    .font(.caption)
                    .foregroundStyle(access.message == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("解锁高级功能") { access.requestUnlock() }
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }
}
