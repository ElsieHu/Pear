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
    private var stateCancellable: AnyCancellable?

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

        // Why a plain NSView container instead of the hosting view directly:
        // an NSHostingView as `contentView` resizes the *window* to its
        // intrinsic size the instant the lyric text changes — and it does so
        // immediately, with no animation to interrupt it. That snap was the
        // main reason line changes felt abrupt: the pill was already at its
        // new width before any animation could run, so `refit` found nothing
        // left to animate. A plain container has no intrinsic size, which
        // hands size control back to `refit`.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 56))
        let hosting = NSHostingView(rootView: KaraokeView().environmentObject(state))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        contentView = container
        self.hosting = hosting

        applyAppearance()
        restoreFrame()
        observeAppearanceChanges()
        observeResizes()
        // The window no longer sizes itself, so set the real size up front —
        // otherwise the pill appears at its 420×56 placeholder for a frame.
        refit(animated: false)
        startFittingLoop()
    }

    // MARK: - Re-centring on auto-resize

    private var lastKnownWidth: CGFloat = 0

    private func observeResizes() {
        lastKnownWidth = frame.width
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: self
        )
    }

    /// Diagnostic only.
    ///
    /// With the container in place the window should never resize itself —
    /// every size change is supposed to come from `refit`, animated. If this
    /// logs, the container has stopped insulating us and resizes are again
    /// cutting the animation short.
    @objc private func panelDidResize(_ note: Notification) {
        let width = frame.width
        let delta = width - lastKnownWidth
        guard abs(delta) > 0.5 else {
            lastKnownWidth = width
            return
        }
        lastKnownWidth = width
        if Date().timeIntervalSince(lastResizeLog) > 15.0 {
            lastResizeLog = Date()
            AppLog.info(String(format: "窗口尺寸变化 w=%+.0f (正常应由 refit 动画驱动)", delta))
        }
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
                // Polling is only the safety net — 10 Hz is plenty. Track and
                // appearance changes are pushed (see `observeStateChanges`),
                // so a new lyric line's width is picked up immediately instead
                // of waiting for the next tick.
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        observeStateChanges()
    }

    /// Re-measure the moment something changes, rather than at the next poll.
    private func observeStateChanges() {
        stateCancellable = state.objectWillChange.sink { [weak self] _ in
            // `objectWillChange` fires *before* the new value lands; hop once
            // so `fittingSize` reflects the change we were told about.
            Task { @MainActor in self?.refit(animated: true) }
        }
    }

    private func tick() {
        let shouldShow = state.panelContent != .hidden
        if shouldShow && !isVisible {
            // Settle the size *before* the first appearance: showing the
            // placeholder width first and animating to the real one looks
            // like the pill inflating on launch.
            refit(animated: false)
            orderFrontRegardless()
        } else if !shouldShow && isVisible {
            orderOut(nil)
            return
        }

        refit(animated: true)
    }

    /// Rate-limited note of how the pill is resizing, for the log.
    private var lastFitLog = Date.distantPast
    private var lastResizeLog = Date.distantPast
    /// Timestamp until which a resize animation is still in flight.
    private var animatingUntil = Date.distantPast
    /// Kept in step with the line-swap animation in `KaraokeView` so the pill
    /// and its text settle at the same moment.
    private static let resizeDuration: TimeInterval = 0.26

    private func refit(animated: Bool) {
        guard let hosting, state.panelContent != .hidden else { return }
        // Don't interrupt an in-flight resize: restarting from a halfway
        // frame makes the pill stutter instead of glide.
        if animated, Date() < animatingUntil { return }

        let target = hosting.fittingSize
        guard target.width >= 24, target.height >= 16, target.width.isFinite else { return }

        let current = frame.size
        guard abs(current.width - target.width) > 0.5 || abs(current.height - target.height) > 0.5 else { return }

        // Which edge stays put while the pill grows/shrinks. This is what
        // “对齐” actually means for a pill sized to its own text: there is no
        // slack inside the pill, so the only visible effect of alignment is
        // *where the pill expands from*.
        //
        // Anchor on the old frame, before it is replaced below.
        let oldFrame = frame
        let newX: CGFloat
        switch state.appearance.textAlignmentRaw {
        case "leading":  newX = oldFrame.minX
        case "trailing": newX = oldFrame.maxX - target.width
        default:         newX = oldFrame.midX - target.width / 2
        }

        var rect = NSRect(
            x: newX,
            y: oldFrame.maxY - target.height,
            width: target.width,
            height: target.height
        )
        rect = clamped(to: rect)

        if Date().timeIntervalSince(lastFitLog) > 0.4 {
            lastFitLog = Date()
            AppLog.info(String(format: "refit w %.0f→%.0f minX %.0f→%.0f midX %.0f→%.0f 对齐=%@",
                               current.width, target.width,
                               oldFrame.minX, rect.minX,
                               oldFrame.midX, rect.midX,
                               state.appearance.textAlignmentRaw))
        }

        if animated {
            animatingUntil = Date().addingTimeInterval(Self.resizeDuration)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.resizeDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(rect, display: true)
            }
        } else {
            setFrame(rect, display: true)
        }
        lastKnownWidth = target.width
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
