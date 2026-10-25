import Foundation

/// Keep the natural content height separate from the screen-limited viewport.
struct MenuSizing {
    private var contentHeight: CGFloat?
    private var availableHeight: CGFloat = 750

    var viewportHeight: CGFloat {
        min(contentHeight ?? 650, availableHeight)
    }

    mutating func measureContent(_ height: CGFloat) {
        // MenuBarExtra may initially propose zero while creating its window.
        // Retain the last valid height until natural layout is available.
        guard height.isFinite, height > 0 else { return }
        contentHeight = ceil(height)
    }

    mutating func updateScreenHeight(_ height: CGFloat) {
        // visibleFrame already excludes the menu bar and any persistent Dock.
        // Leave a little room for the menu window's top and bottom edges.
        guard height.isFinite, height > 16 else { return }
        availableHeight = floor(height - 16)
    }
}
