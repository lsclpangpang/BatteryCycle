import SwiftUI

@main
struct BatteryCycleApp: App {
    @StateObject private var model = BatteryModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
            Text(model.percentText)
        }
        .menuBarExtraStyle(.window)
    }
}
