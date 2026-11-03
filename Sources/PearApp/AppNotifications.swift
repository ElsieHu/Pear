import Foundation

extension Notification.Name {
    /// Appearance settings changed — the floating panel should re-fit.
    static let appearanceDidChange = Notification.Name("Pear.appearanceDidChange")
    /// Move the floating panel back to its default spot.
    static let resetPanelPosition = Notification.Name("Pear.resetPanelPosition")
    /// Open the preferences window (posted from the menu-bar panel).
    static let openSettings = Notification.Name("Pear.openSettings")
}
