import AppKit
import SwiftUI
import Combine
import CoreGraphics

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
    private var pill: NSView?
    private var containerView: PillContainerView?
    /// True while `performDrag` is tracking the mouse. Re-fitting the window
    /// in the middle of that tracking loop is what makes a drag feel like it
    /// "slipped out of your hand" — the frame moves under the cursor.
    private var isDragging = false
    /// The rounded, clipping inner view — separate from `pill` because a
    /// layer that masks to its bounds also clips away its own shadow.
    private var chrome: NSView?
    private var cancellable: AnyCancellable?
    private var stateCancellable: AnyCancellable?

    /// How much room the window keeps around the pill for its shadow. Only
    /// needed when there is a shadow: with it off, an inset would just be a
    /// ring of invisible window swallowing clicks that belong to whatever is
    /// underneath.
    ///
    /// The margin has to *contain* the whole blur (roughly 3 × radius). When
    /// the blur was 22pt and the margin only 24pt, the outer part of the halo
    /// was cut off by the window's rectangular edge — a straight, square
    /// boundary, exactly the artefact reported. Radius 9 / margin 30 leaves
    /// the whole halo intact and makes it much tighter around the pill.
    private var shadowRoom: CGFloat {
        state.effectiveAppearance.shadowEnabled ? LyricAppearance.shadowRoom : 0
    }

    private var pillLeading: NSLayoutConstraint?
    private var pillTrailing: NSLayoutConstraint?
    private var pillTop: NSLayoutConstraint?
    private var pillBottom: NSLayoutConstraint?

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
        let container = PillContainerView(frame: NSRect(x: 0, y: 0, width: 420, height: 56))
        // The pill proper: background, rounded corners and shadow. It is
        // inset inside the window because a shadow drawn outside the content
        // view is simply clipped away by the window edge — so the window has
        // to be a little bigger than the pill for the shadow to exist.
        //
        // The pill's shape is drawn here rather than in SwiftUI on purpose:
        // whatever the content does, it is the window that clips, so a shape
        // drawn *inside* the content gets squared off the moment content and
        // window disagree about size. Drawn here as the clip, it holds.
        // Two layers, not one: a layer that masks to its rounded bounds also
        // clips away its own shadow. So the outer one casts the shadow and
        // the inner one does the rounding and clipping.
        let pill = PillShadowView(frame: container.bounds)
        pill.wantsLayer = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pill)
        self.pill = pill
        container.pill = pill

        let chrome = NSView(frame: pill.bounds)
        chrome.wantsLayer = true
        chrome.layer?.masksToBounds = true
        chrome.autoresizingMask = [.width, .height]
        pill.addSubview(chrome)
        self.chrome = chrome

        let hosting = NSHostingView(rootView: KaraokeView().environmentObject(state))
        hosting.frame = chrome.bounds
        hosting.autoresizingMask = [.width, .height]
        chrome.addSubview(hosting)
        contentView = container
        self.hosting = hosting
        self.containerView = container

        // The container owns dragging now (see PillContainerView). Wiring the
        // state back lets `refit` hold still for the duration of a drag.
        container.canDrag = !state.appearance.lockPosition
        container.onDragStateChange = { [weak self] dragging in
            guard let self else { return }
            self.isDragging = dragging
            if !dragging { self.refit(animated: false) }
        }

        let leading = pill.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                    constant: shadowRoom)
        let trailing = pill.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                      constant: -shadowRoom)
        let top = pill.topAnchor.constraint(equalTo: container.topAnchor,
                                            constant: shadowRoom)
        let bottom = pill.bottomAnchor.constraint(equalTo: container.bottomAnchor,
                                                  constant: -shadowRoom)
        pillLeading = leading
        pillTrailing = trailing
        pillTop = top
        pillBottom = bottom
        NSLayoutConstraint.activate([leading, trailing, top, bottom])

        applyAppearance()
        restoreFrame()
        observeAppearanceChanges()
        observeResizes()
        // The window no longer sizes itself, so set the real size up front —
        // otherwise the pill appears at its 420×56 placeholder for a frame.
        refit(animated: false)
        startFittingLoop()
        startPassThroughLoop()
    }

    // MARK: - Re-centring on auto-resize

    /// The width `refit` last asked for.
    ///
    /// `didResize` is delivered asynchronously, so neither a flag set around
    /// the `setFrame` call nor a time window reliably tells our own resize
    /// apart from a foreign one. Comparing against what we actually asked for
    /// does.
    private var lastRefitWidth: CGFloat = 0

    private func observeResizes() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: self
        )
    }

    /// Diagnostic: the window's size must come from `refit` and nowhere else.
    /// A resize imposed from outside leaves the pill out of step with its own
    /// content, which is what clips the rounded corners — so report it.
    @objc private func panelDidResize(_ note: Notification) {
        // Mid-animation the width is legitimately still on its way to our
        // target, so only look once it has settled — and then only complain
        // if the window ended up somewhere we did not ask for.
        guard Date() >= animatingUntil, abs(frame.width - lastRefitWidth) > 0.5 else { return }
        if Date().timeIntervalSince(lastResizeLog) > 15.0 {
            lastResizeLog = Date()
            AppLog.warn(String(format: "窗口被外部改尺寸 w=%.0f (应由 refit 独占)", frame.width))
        }
    }

    // MARK: - Appearance / behaviour sync

    private func applyAppearance() {
        let ap = state.appearance
        // AppKit's "movable by window background" only fires on the parts of
        // the window where no subview accepts the click — here that was just
        // the thin padding ring around the text. Dragging is now owned by the
        // container (whole pill, text included), so turn the old path off.
        isMovableByWindowBackground = false
        containerView?.canDrag = !ap.lockPosition
        ignoresMouseEvents = ap.clickThrough
        if !ap.clickThrough { clearPassThroughHole() }
        applyChrome()
    }

    // MARK: - Pass-through "bubble" (v2s style)

    /// The window ignores all mouse events while click-through is on, so the
    /// pointer can only be observed through `NSEvent.mouseLocation`. A short
    /// polling loop is enough: no event taps, no Accessibility permission.
    private func startPassThroughLoop() {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.updatePassThroughHole()
                try? await Task.sleep(nanoseconds: 33_000_000)  // ~30 Hz
            }
        }
    }

    /// Cut a soft-edged circular hole in the pill around the cursor so the
    /// window below shows through. The panel already ignores all clicks, so
    /// what is visible through the hole is clickable too.
    private func updatePassThroughHole() {
        guard let chrome else { return }
        guard state.appearance.clickThrough, isVisible else {
            clearPassThroughHole()
            return
        }

        let inWindow = convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = chrome.convert(inWindow, from: nil)
        let bounds = chrome.bounds
        // Leave room for the feathered rim to fade out past the pill edge
        // instead of popping in/out exactly at the boundary.
        guard bounds.insetBy(dx: -24, dy: -24).contains(local) else {
            clearPassThroughHole()
            return
        }

        let radius = min(34, max(14, bounds.height * 0.55))
        let feather = min(18, radius * 0.6)
        let corner = min(CGFloat(state.effectiveAppearance.cornerRadius),
                         min(bounds.width, bounds.height) / 2)

        let maskLayer: PassThroughMaskLayer
        if let existing = chrome.layer?.mask as? PassThroughMaskLayer {
            maskLayer = existing
        } else {
            maskLayer = PassThroughMaskLayer()
            maskLayer.contentsScale = chrome.layer?.contentsScale ?? 2
        }

        // Redraw only when something actually moved — a 30 Hz full repaint of
        // the mask while the cursor is parked is pure waste.
        let moved = maskLayer.frame != bounds
            || abs(maskLayer.holeCenter.x - local.x) > 0.5
            || abs(maskLayer.holeCenter.y - local.y) > 0.5
            || maskLayer.holeRadius != radius
            || maskLayer.feather != feather
            || maskLayer.pillCornerRadius != corner

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if moved {
            maskLayer.frame = bounds
            maskLayer.holeCenter = local
            maskLayer.holeRadius = radius
            maskLayer.feather = feather
            maskLayer.pillCornerRadius = corner
        }
        if chrome.layer?.mask !== maskLayer { chrome.layer?.mask = maskLayer }
        CATransaction.commit()
        if moved { maskLayer.setNeedsDisplay() }
    }

    private func clearPassThroughHole() {
        guard chrome?.layer?.mask != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chrome?.layer?.mask = nil
        CATransaction.commit()
    }

    /// Background, corners and shadow of the pill.
    ///
    /// These live on the window's own layer, not inside the SwiftUI content.
    /// That is the whole point: a rounded rect drawn *by* the content gets
    /// clipped square by the window the moment content and window disagree
    /// about size — which they do during every line hand-off. Drawn here, the
    /// rounded shape is the clip, so it holds no matter what the content does.
    private func applyChrome() {
        guard let pill, let pillLayer = pill.layer, let chromeLayer = chrome?.layer else { return }
        let ap = state.effectiveAppearance
        chromeLayer.cornerRadius = CGFloat(ap.cornerRadius)
        chromeLayer.backgroundColor = NSColor(ap.backgroundColor).cgColor
        chromeLayer.masksToBounds = true

        // The shadow used to be cast by a *rectangular* outer layer while the
        // rounded shape lived on the inner one. The two never agreed, so all
        // that showed was a hard, straight dark bar under the pill. Give the
        // outer layer an explicit rounded shadowPath and keep the offset tiny:
        // a soft halo on all four sides, only barely weighted downwards.
        let radius = CGFloat(ap.cornerRadius)
        (pill as? PillShadowView)?.cornerRadius = radius
        pillLayer.masksToBounds = false
        pillLayer.shadowColor = NSColor.black.cgColor
        pillLayer.shadowOpacity = ap.shadowEnabled ? Float(ap.shadowIntensity) : 0
        // Keep the blur comfortably inside `shadowRoom`; otherwise the
        // window's rectangular edge clips it into a square halo.
        pillLayer.shadowRadius = min(LyricAppearance.shadowBlurRadius,
                                     LyricAppearance.shadowRoom / 3)
        // AppKit measures the offset upwards; -1 is a barely-there downward
        // bias, so the shadow still reads as a halo rather than a bar.
        pillLayer.shadowOffset = CGSize(width: 0, height: -1)
        pill.needsLayout = true   // refresh shadowPath for the current bounds

        // Grow or shrink the ring of empty window around the pill to match.
        pillLeading?.constant = shadowRoom
        pillTop?.constant = shadowRoom
        pillTrailing?.constant = -shadowRoom
        pillBottom?.constant = -shadowRoom

        let msg = String(format: "外壳 圆角=%.0f 阴影=%@ 强度=%.2f 模糊=%.0f 不透明度=%.2f 留白=%.0f",
                         ap.cornerRadius, ap.shadowEnabled ? "开" : "关",
                         ap.shadowIntensity, pillLayer.shadowRadius,
                         pillLayer.shadowOpacity, shadowRoom)
        guard msg != lastChromeLog else { return }
        lastChromeLog = msg
        AppLog.info(msg)
    }

    private var lastChromeLog = ""

    private func observeAppearanceChanges() {
        cancellable = NotificationCenter.default
            .publisher(for: .appearanceDidChange)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.applyAppearance()
                    self?.refit()
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
            Task { @MainActor in self?.refit() }
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

        refit()
    }

    /// Rate-limited note of how the pill is resizing, for the log.
    private var lastFitLog = Date.distantPast
    private var lastResizeLog = Date.distantPast

    /// Kept in step with the line hand-off in `KaraokeView`, so the pill and
    /// its text settle at the same moment.
    private static let resizeDuration: TimeInterval = KaraokeView.handOffDuration
    /// Until when a resize we started is still running.
    private var animatingUntil = Date.distantPast

    /// Sizes the window to its content.
    ///
    /// Animated, and safe to be: the rounded corners are the window's own
    /// (see `applyChrome`), so a window that lags half a frame behind its
    /// content no longer produces a square edge — the content simply slides
    /// under the rounded mask.
    private func refit(animated: Bool = true) {
        guard !isDragging else { return }
        guard let hosting, state.panelContent != .hidden else { return }
        // Don't interrupt a resize in flight: restarting from a halfway frame
        // makes the pill stutter instead of glide.
        if animated, Date() < animatingUntil { return }

        let content = hosting.fittingSize
        guard content.width >= 24, content.height >= 16, content.width.isFinite else { return }
        // The window is the pill plus room for its shadow on every side.
        let room = 2 * shadowRoom
        let target = NSSize(width: content.width + room, height: content.height + room)

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

        lastRefitWidth = target.width
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

/// The window's content view, which is larger than the pill whenever a shadow
/// is on — the shadow has to fall somewhere.
///
/// That ring of transparent window is invisible but still hit-testable, so
/// without this it swallows clicks meant for whatever sits underneath. Clicks
/// are only accepted inside the pill; everything else falls through.
extension Notification.Name {
    /// The container owns hit-testing now, so SwiftUI's `.onHover` no longer
    /// receives mouseMoved. Hover is relayed through this notification.
    static let pearPanelHover = Notification.Name("pear.panelHover")
}

private final class PillContainerView: NSView {
    weak var pill: NSView?
    var canDrag = true
    var onDragStateChange: (@MainActor (Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let pill, pill.frame.contains(point) else { return nil }
        // `super.hitTest` returned the SwiftUI hosting view, which swallowed
        // mouseDown on the text. Only the thin padding ring around the lyrics
        // could then start a drag — users had to aim for a few pixels. The
        // entire pill is now one drag surface.
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard canDrag else { super.mouseDown(with: event); return }
        onDragStateChange?(true)
        window?.performDrag(with: event)
        onDragStateChange?(false)
    }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NotificationCenter.default.post(name: .pearPanelHover, object: nil,
                                        userInfo: ["over": true])
    }

    override func mouseExited(with event: NSEvent) {
        NotificationCenter.default.post(name: .pearPanelHover, object: nil,
                                        userInfo: ["over": false])
    }
}

/// Outer layer of the pill: it owns the shadow.
///
/// Without an explicit `shadowPath`, Core Animation derives the shadow from
/// the layer's own rectangular bounds — that was the "dark bar under the
/// pill" bug. Keeping the path in sync inside `layout()` makes the halo
/// follow both the corner radius and the animated width.
private final class PillShadowView: NSView {
    var cornerRadius: CGFloat = 14

    override func layout() {
        super.layout()
        guard let layer else { return }
        let r = min(cornerRadius, min(layer.bounds.width, layer.bounds.height) / 2)
        layer.shadowPath = CGPath(roundedRect: layer.bounds,
                                  cornerWidth: r,
                                  cornerHeight: r,
                                  transform: nil)
    }
}

/// Mask with a soft-edged circular hole for click-through.
///
/// A layer mask reads only the *alpha* channel, and a `CAShapeLayer` with an
/// even-odd path can only ever be binary — that produced the hard, cut-out
/// circle. Here the rounded pill is first filled opaque, then a radial
/// gradient is subtracted with `destinationOut` (`D * (1 - Sa)`): alpha 1 at
/// the centre removes the mask completely, alpha 0 at the rim leaves it
/// intact, and the stops in between give the feathered edge.
private final class PassThroughMaskLayer: CALayer {
    var holeCenter: CGPoint = .zero
    var holeRadius: CGFloat = 34
    var feather: CGFloat = 16
    /// Not `cornerRadius`: CALayer already owns that name.
    var pillCornerRadius: CGFloat = 14

    override func draw(in ctx: CGContext) {
        let b = bounds
        ctx.clear(b)

        // Everything inside the rounded pill starts out visible.
        let rounded = CGPath(roundedRect: b,
                             cornerWidth: pillCornerRadius,
                             cornerHeight: pillCornerRadius,
                             transform: nil)
        ctx.addPath(rounded)
        ctx.clip()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(b)

        let inner = max(1, holeRadius - feather * 0.35)
        let outer = holeRadius + feather
        guard outer > inner else { return }
        let colors = [
            CGColor(gray: 0, alpha: 1),
            CGColor(gray: 0, alpha: 1),
            CGColor(gray: 0, alpha: 0)
        ] as CFArray
        let locations: [CGFloat] = [0, inner / outer, 1]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                        colors: colors, locations: locations) else { return }

        ctx.setBlendMode(.destinationOut)
        ctx.drawRadialGradient(gradient,
                               startCenter: holeCenter,
                               startRadius: 0,
                               endCenter: holeCenter,
                               endRadius: outer,
                               options: [])
    }
}
