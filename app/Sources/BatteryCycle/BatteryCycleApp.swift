import SwiftUI

@main
struct BatteryCycleApp: App {
    @StateObject private var model = BatteryModel()
    @StateObject private var displays = DisplayController()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(displays)
        } label: {
            // 合成一张图，避免 SwiftUI 给图标和文字各自加留白
            Image(nsImage: model.menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }
}
