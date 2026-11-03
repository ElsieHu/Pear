import AppKit
import SwiftUI
import Combine
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
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState, panel: KaraokePanel) {
        self.state = state
        self.panel = panel
        configure()
        observeNotifications()
        observeState()
        installHotKeys()
    }

    private func configure() {
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggleNowPlaying)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItem()
    }

    // MARK: - Menu-bar item content

    /// Keep the status item in sync with both what the user chose to show and
    /// what is playing.
    ///
    /// Why the `Task` in the sinks: `objectWillChange` fires *before* the
    /// value lands (that is what "will" means), so reading `state` directly in
    /// the closure would render the previous track. Deferring one hop lets the
    /// assignment complete first.
    private func observeState() {
        state.$menuBarDisplay
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateStatusItem() }
            }
            .store(in: &cancellables)

        // Covers track changes — AppState relays its monitor's notifications.
        state.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateStatusItem() }
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let choice = state.menuBarDisplay
        let track = state.monitor.track
        let label = choice.label(title: track?.title, artist: track?.artist)

        // The icon is the floor. Whenever there is no text to render — no
        // track (Music not running / nothing playing), empty fields, or a
        // text-only configuration with nothing to show — keep the item
        // visible and clickable so Settings is always reachable.
        let useIcon = choice.showsIcon || label.isEmpty
        if useIcon {
            if button.image == nil {
                let image = NSImage(systemSymbolName: "music.note",
                                    accessibilityDescription: "歌词浮窗")
                image?.isTemplate = true
                button.image = image
            }
        } else {
            button.image = nil
        }
        button.imagePosition = useIcon ? .imageLeading : .noImage
        button.title = label

        if let track {
            button.toolTip = "《\(track.title)》- \(track.artist)"
        } else {
            button.toolTip = "歌词浮窗"
        }

        // Logged on change only, so it documents what the user configured
        // without filling the log on every track tick.
        let summary = "\(useIcon ? "[图标]" : "")\(button.title)"
        guard summary != lastMenuSummary else { return }
        lastMenuSummary = summary
        AppLog.info("菜单栏显示: \(summary.isEmpty ? "(空)" : summary)")
    }

    private var lastMenuSummary = ""

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
