import AppKit
import Combine
import SwiftUI

@main
struct BatteryCycleApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = BatteryCycleAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class BatteryCycleAppDelegate: NSObject, NSApplicationDelegate {
    private var model: BatteryModel?
    private var displays: DisplayController?
    private var brightness: BrightnessController?
    private var access: AdvancedAccessController?
    private var restrictions: DisplayOutputRestrictionController?
    private var navigation: MenuNavigationController?
    private var menu: MenuBarController?
    private var imageUpdates: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = BatteryModel()
        let brightness = BrightnessController()
        let access = AdvancedAccessController()
        let restrictions = DisplayOutputRestrictionController(
            canChangeSettings: { [weak access] in access?.isUnlocked == true },
            isUsable: { [weak brightness] display in
                display.isEnabled && (!display.isBuiltin || brightness?.isEnabled != true)
            }
        )
        let displays = DisplayController(mayEnable: { [weak restrictions] id, identity in
            restrictions?.permitsLegacyEnabling(displayID: id, identity: identity) == true
        }, captureOutputIdentity: { [weak restrictions] id in
            restrictions?.captureLegacyIdentity(displayID: id)
        }, externalDisabledModels: { [weak restrictions] in
            restrictions?.ownedDisplayModels() ?? [:]
        })
        let navigation = MenuNavigationController(access: access)
        self.model = model
        self.displays = displays
        self.brightness = brightness
        self.access = access
        self.restrictions = restrictions
        self.navigation = navigation
        menu = MenuBarController(navigation: navigation, image: model.menuBarImage) { onHeightChange in
            AnyView(MenuView(onHeightChange: onHeightChange)
                .environmentObject(model)
                .environmentObject(displays)
                .environmentObject(brightness)
                .environmentObject(access)
                .environmentObject(navigation)
                .environmentObject(restrictions))
        }
        imageUpdates = model.objectWillChange.sink { [weak self] _ in
            // @Published sends before mutation; render the new value on the next turn.
            DispatchQueue.main.async {
                guard let self, let model = self.model else { return }
                self.menu?.updateImage(model.menuBarImage)
            }
        }
        let mainMenu = NSMenu()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "退出电池循环", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem()
        item.submenu = applicationMenu
        mainMenu.addItem(item)
        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        navigation?.prepareForTermination()
        menu?.stop()
        imageUpdates = nil
    }
}
