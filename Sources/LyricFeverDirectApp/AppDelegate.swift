import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var karaokePanel: KaraokePanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState.shared

        let panel = KaraokePanel(state: state)
        karaokePanel = panel
        panel.orderFrontRegardless()

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
