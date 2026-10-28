import AppKit
import SwiftUI
import Combine

/// A borderless, always-on-top floating panel that shows **one** line of
/// synced lyrics, sized to the text itself.
///
/// Behaviour mirrors (and tightens up) Lyric Fever's karaoke mode:
/// - `.nonactivatingPanel` so it never steals focus from other apps.
/// - `.mainMenu` window level: above normal windows, below system alerts.
/// - `.canJoinAllSpaces` / `.fullScreenAuxiliary`: floats over every desktop.
/// - Draggable by its background; optionally click-through and lockable.
@MainActor
final class KaraokePanel: NSPanel {

    private let state: AppState
    private var hosting: NSView?
    private var cancellable: AnyCancellable?

    init(state: AppState) {
        self.state = state
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 56),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .mainMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        // The panel is transparent, so AppKit's own shadow would trace the
        // rectangular window edge; SwiftUI draws the pill shadow instead.
        hasShadow = false
        acceptsMouseMovedEvents = true

        let hosting = NSHostingView(rootView: KaraokeView().environmentObject(state))
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
        self.hosting = hosting

        applyAppearance()
        restoreFrame()
        observeAppearanceChanges()
        startFittingLoop()
    }

    // MARK: - Appearance / behaviour sync

    private func applyAppearance() {
        let ap = state.appearance
        isMovableByWindowBackground = !ap.lockPosition
        ignoresMouseEvents = ap.clickThrough
    }

    private func observeAppearanceChanges() {
        cancellable = NotificationCenter.default
            .publisher(for: .appearanceDidChange)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.applyAppearance()
                    self?.refit(animated: true)
                }
            }
    }

    // MARK: - Auto-fit

    /// Keeps the window exactly as wide as its content, so a short line
    /// produces a compact pill rather than a fixed-size box.
    private func startFittingLoop() {
        Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func tick() {
        let shouldShow = state.panelContent != .hidden
        if shouldShow && !isVisible {
            orderFrontRegardless()
        } else if !shouldShow && isVisible {
            orderOut(nil)
            return
        }
        refit(animated: true)
    }

    private func refit(animated: Bool) {
        guard let hosting, state.panelContent != .hidden else { return }
        let target = hosting.fittingSize
        guard target.width >= 24, target.height >= 16, target.width.isFinite else { return }

        let current = frame.size
        guard abs(current.width - target.width) > 0.5 || abs(current.height - target.height) > 0.5 else { return }

        // Keep the horizontal centre stable so the pill grows outward evenly.
        let centreX = frame.midX
        var rect = NSRect(
            x: centreX - target.width / 2,
            y: frame.maxY - target.height,
            width: target.width,
            height: target.height
        )
        rect = clamped(to: rect)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(rect, display: true)
            }
        } else {
            setFrame(rect, display: true)
        }
    }

    private func clamped(to rect: NSRect) -> NSRect {
        guard let screen = screen ?? NSScreen.main else { return rect }
        let bounds = screen.visibleFrame
        var r = rect
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
        if r.minY < bounds.minY { r.origin.y = bounds.minY }
        return r
    }

    // MARK: - Position persistence

    private static let originKey = "panelOrigin"

    private func restoreFrame() {
        if let s = UserDefaults.standard.string(forKey: Self.originKey) {
            let parts = s.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                setFrameOrigin(NSPoint(x: parts[0], y: parts[1]))
                return
            }
        }
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        setFrameOrigin(NSPoint(x: v.midX - frame.width / 2, y: v.minY + 120))
    }

    func saveFrame() {
        UserDefaults.standard.set("\(frame.origin.x),\(frame.origin.y)", forKey: Self.originKey)
    }

    func resetPosition() {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        setFrameOrigin(NSPoint(x: v.midX - frame.width / 2, y: v.minY + 120))
        saveFrame()
    }

    // MARK: - Window overrides

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
