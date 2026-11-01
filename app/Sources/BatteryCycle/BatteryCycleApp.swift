import SwiftUI

@main
struct BatteryCycleApp: App {
    @StateObject private var model = BatteryModel()
    @StateObject private var displays: DisplayController
    @StateObject private var brightness: BrightnessController
    @StateObject private var access: AdvancedAccessController
    @StateObject private var restrictions: DisplayOutputRestrictionController
    @StateObject private var advancedFeatures: AdvancedFeaturesWindow

    init() {
        let brightness = BrightnessController()
        let access = AdvancedAccessController()
        let restrictions = DisplayOutputRestrictionController(
            canChangeSettings: { [weak access] in access?.isUnlocked == true },
            isUsable: { [weak brightness] display in
                display.isEnabled && (!display.isBuiltin || brightness?.isEnabled != true)
            }
        )
        _brightness = StateObject(wrappedValue: brightness)
        _access = StateObject(wrappedValue: access)
        _restrictions = StateObject(wrappedValue: restrictions)
        _displays = StateObject(wrappedValue: DisplayController(mayEnable: { [weak restrictions] id, identity in
            restrictions?.permitsLegacyEnabling(displayID: id, identity: identity) == true
        }, captureOutputIdentity: { [weak restrictions] id in
            restrictions?.captureLegacyIdentity(displayID: id)
        }, externalDisabledModels: { [weak restrictions] in
            restrictions?.ownedDisplayModels() ?? [:]
        }))
        _advancedFeatures = StateObject(wrappedValue: AdvancedFeaturesWindow(access: access, restrictions: restrictions))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(displays)
                .environmentObject(brightness)
                .environmentObject(advancedFeatures)
                .environmentObject(restrictions)
        } label: {
            // 合成一张图，避免 SwiftUI 给图标和文字各自加留白
            Image(nsImage: model.menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }
}
