import Foundation

extension Notification.Name {
    /// Appearance settings changed — the floating panel should re-fit.
    static let appearanceDidChange = Notification.Name("LyricFeverDirect.appearanceDidChange")
    /// Move the floating panel back to its default spot.
    static let resetPanelPosition = Notification.Name("LyricFeverDirect.resetPanelPosition")
    /// Open the preferences window (posted from the menu-bar panel).
    static let openSettings = Notification.Name("LyricFeverDirect.openSettings")
}
