import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var karaokePanel: KaraokePanel?
    /// `Any?` keeps this class available on macOS 13; the concrete helper
    /// window is gated on the Translation framework (macOS 15+).
    private var translationHost: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState.shared

        if #available(macOS 15.0, *) {
            // Always present so `.translationTask` stays alive even while the
            // lyrics panel is hidden. It is 2×2 and fully transparent.
            translationHost = TranslationHostWindow()
        }

        let panel = KaraokePanel(state: state)
        karaokePanel = panel
        // Visibility is decided by KaraokePanel.tick() from panelContent:
        // the pill only appears with a track, lyrics and active playback.
        // Showing it here would make it flash at launch with no music playing.

        statusBar = StatusBarController(state: state, panel: panel)

        state.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.karaokePanel?.saveFrame()
                AppState.shared.monitor.stop()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        karaokePanel?.saveFrame()
        AppState.shared.monitor.stop()
    }

    /// Keep the app running even when all windows are closed (menu-bar app).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
