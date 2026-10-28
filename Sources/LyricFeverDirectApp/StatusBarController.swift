import AppKit
import SwiftUI
import AppleMusicBridge

/// Menu-bar control. Clicking the icon opens a now-playing panel
/// (artwork / title / transport / progress + action rows).
@MainActor
final class StatusBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let state: AppState
    private weak var panel: KaraokePanel?
    private var nowPlayingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var outsideMonitor: Any?

    init(state: AppState, panel: KaraokePanel) {
        self.state = state
        self.panel = panel
        configure()
        observeNotifications()
        installHotKeys()
    }

    private func configure() {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "music.note",
                accessibilityDescription: "歌词浮窗"
            )
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(toggleNowPlaying)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(forName: .resetPanelPosition, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panel?.resetPosition() }
        }
        NotificationCenter.default.addObserver(forName: .openSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.closeNowPlaying()
                self?.openSettings()
            }
        }
    }

    private func installHotKeys() {
        let center = HotKeyCenter.shared
        center.install()
        center.onToggleLyrics = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.state.windowEnabled.toggle()
                if !self.state.windowEnabled { self.panel?.orderOut(nil) }
            }
        }
        center.onToggleLock = { [weak self] in
            Task { @MainActor in self?.state.appearance.lockPosition.toggle() }
        }
    }

    // MARK: - Now-playing panel

    @objc private func toggleNowPlaying() {
        if let win = nowPlayingWindow, win.isVisible {
            closeNowPlaying()
        } else {
            openNowPlaying()
        }
    }

    private func openNowPlaying() {
        let win = ensureNowPlayingWindow()
        state.monitor.refreshNowPlaying()

        // Let SwiftUI lay out once so we can size/position correctly.
        DispatchQueue.main.async {
            if let hosting = win.contentView {
                let fit = hosting.fittingSize
                win.setContentSize(NSSize(width: 320, height: max(fit.height, 120)))
            }
            self.position(win)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.installOutsideClickMonitor()
        }
    }

    private func ensureNowPlayingWindow() -> NSWindow {
        if let win = nowPlayingWindow { return win }
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 320),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.level = .popUpMenu
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isMovable = false
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.transient, .canJoinAllSpaces]
        win.contentView = NSHostingView(rootView: NowPlayingView())
        win.isReleasedWhenClosed = false
        nowPlayingWindow = win
        return win
    }

    private func position(_ win: NSWindow) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let rect = buttonWindow.convertToScreen(button.frame)
        var frame = win.frame
        frame.origin = NSPoint(x: rect.midX - frame.width / 2, y: rect.minY - frame.height - 4)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX + 4),
                                 visible.maxX - frame.width - 4)
        }
        win.setFrameOrigin(frame.origin)
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        // Defer slightly so the click that opened the panel doesn't close it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let win = self.nowPlayingWindow, win.isVisible else { return }
                    if !win.frame.contains(NSEvent.mouseLocation) {
                        self.closeNowPlaying()
                    }
                }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideMonitor {
            NSEvent.removeMonitor(m)
            outsideMonitor = nil
        }
    }

    private func closeNowPlaying() {
        removeOutsideClickMonitor()
        nowPlayingWindow?.orderOut(nil)
    }

    // MARK: - Settings window

    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 700),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "歌词浮窗偏好设置"
            let hosting = NSHostingView(rootView: SettingsView().environmentObject(state))
            // Layer-backing removes the repaint stutter when scrolling a
            // vibrancy-backed SwiftUI Form in a non-layered window.
            hosting.wantsLayer = true
            hosting.layerContentsRedrawPolicy = .onSetNeedsDisplay
            window.contentView = hosting
            window.backgroundColor = .windowBackgroundColor
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
