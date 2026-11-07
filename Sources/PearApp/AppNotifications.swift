import Foundation

extension Notification.Name {
    /// Appearance settings changed — the floating panel should re-fit.
    static let appearanceDidChange = Notification.Name("Pear.appearanceDidChange")
    /// Automatic album/artwork colours changed without the user touching
    /// settings. The pill's AppKit background layer must be repainted too:
    /// SwiftUI redraws the text on its own, but `chromeLayer` is not bound
    /// to any SwiftUI state and otherwise keeps the previous song's colour.
    static let effectiveAppearanceDidChange = Notification.Name("Pear.effectiveAppearanceDidChange")
    /// Move the floating panel back to its default spot.
    static let resetPanelPosition = Notification.Name("Pear.resetPanelPosition")
    /// Open the preferences window (posted from the menu-bar panel).
    static let openSettings = Notification.Name("Pear.openSettings")
    /// Open Pear's own About window (posted from the menu-bar panel).
    static let openAbout = Notification.Name("Pear.openAbout")
}
