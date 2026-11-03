import SwiftUI
import AppKit
import LyricEngine

/// The floating karaoke lyrics view.
///
/// Design goal: a **single line**, sized to its own text — a compact pill
/// rather than a big panel. Every visual aspect (font, size, colours,
/// opacity, corner radius, padding, alignment) is driven by `LyricAppearance`.
struct KaraokeView: View {
    @EnvironmentObject private var state: AppState
    @State private var hovering = false

    private var ap: LyricAppearance { state.effectiveAppearance }

    var body: some View {
        content
            .padding(.horizontal, ap.horizontalPadding)
            .padding(.vertical, ap.verticalPadding)
            // No background, corner radius or shadow here — they belong to the
            // window itself now (see `KaraokePanel.applyChrome`). The pill's
            // shape must be the *window's* rounded rect, because whatever the
            // content does, it is the window edge that clips; a shape drawn
            // inside the content gets squared off the moment content and
            // window disagree about size.
            .fixedSize(horizontal: true, vertical: true)
            .onHover { over in
                withAnimation(.easeInOut(duration: 0.18)) { hovering = over }
            }
            .opacity(ap.hideOnHover && hovering ? 0.15 : 1)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state.panelContent {
        case .hidden:
            EmptyView()
        case .lyrics:
            lyricsBody
        }
    }

    @ViewBuilder
    private var lyricsBody: some View {
        if let lyrics = state.lyrics, !lyrics.lines.isEmpty {
            TimelineView(.periodic(from: .now, by: refreshInterval)) { _ in
                // User calibration for a constant lyric/audio offset.
                // Positive = lyrics run earlier (they were lagging behind).
                let pos = max(0, state.monitor.smoothPosition + state.lyricTimeOffset)
                let idx = lyrics.activeLineIndex(at: pos) ?? 0
                let line = lyrics.lines[idx]
                let progress = ap.sweepEnabled ? lyrics.lineProgress(line, at: pos) : 1

                VStack(alignment: ap.horizontalAlignment, spacing: 6) {
                    // A ZStack, not the VStack this used to be. During the
                    // hand-off the outgoing and incoming lines coexist, and in
                    // a VStack they *stack* — the content would briefly be
                    // twice as tall as the window that clips it. Overlapping
                    // them keeps the height at exactly one line.
                    ZStack(alignment: ap.frameAlignment) {
                        KaraokeLine(
                            text: line.text.isEmpty ? "♪" : line.text,
                            progress: progress,
                            appearance: ap
                        )
                        // `.id` ties identity to the line, so advancing swaps
                        // one view for another — which is what makes the
                        // transition below run. Without it the Text simply
                        // replaces its contents mid-frame: a hard cut.
                        .id(idx)
                        .transition(Self.handOffTransition)
                    }
                    if ap.showNextLine, idx + 1 < lyrics.lines.count {
                        KaraokeLine(
                            text: lyrics.lines[idx + 1].text,
                            progress: 0,
                            appearance: ap,
                            scale: ap.nextLineScale,
                            opacity: ap.dimOpacity
                        )
                        .id(idx + 1)
                        .transition(Self.handOffTransition)
                    }
                }
                .frame(maxWidth: ap.maxWidth, alignment: ap.frameAlignment)
                .animation(Self.handOffAnimation, value: idx)
            }
        }
    }

    /// How often the pill redraws, chosen for what is actually on screen.
    ///
    /// A blanket 60 Hz costs ~17% CPU for no visible gain when there is
    /// nothing moving: paused playback shows a static line, and with the
    /// sweep off only the line *index* matters. So spend the frames only when
    /// the highlight is genuinely sweeping.
    private var refreshInterval: TimeInterval {
        guard state.monitor.isPlaying else { return 1.0 / 10.0 }
        return ap.sweepEnabled ? 1.0 / 60.0 : 1.0 / 20.0
    }

    // MARK: - Hand-off

    /// Line-to-line hand-off. `easeInOut` rather than `easeOut` so the
    /// outgoing line leaves as gently as the new one arrives; `KaraokePanel`
    /// resizes the window over the same duration so the two settle together.
    /// Shared with `KaraokePanel.resizeDuration` so the window and the text
    /// settle at the same moment.
    static let handOffDuration: TimeInterval = 0.28

    static var handOffAnimation: Animation { .easeInOut(duration: handOffDuration) }

    /// A short drift, not a full line-height slide: the line fades as much as
    /// it moves, so a large offset would read as throwing the text away.
    private static let slideDistance: CGFloat = 10

    static var handOffTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: slideDistance)),
            removal: .opacity.combined(with: .offset(y: -slideDistance))
        )
    }
}

/// A single lyric line with an Apple-Music-style left-to-right highlight sweep.
struct KaraokeLine: View {
    let text: String
    let progress: Double
    let appearance: LyricAppearance
    var scale: Double = 1
    var opacity: Double = 1

    var body: some View {
        let p = min(max(progress, 0), 1)
        Text(text)
            .font(appearance.font(size: appearance.fontSize * scale))
            .lineLimit(1)
            .truncationMode(.tail)
            .multilineTextAlignment(appearance.swiftTextAlignment)
            .foregroundStyle(sweepGradient(progress: p))
            .opacity(opacity)
    }

    private func sweepGradient(progress p: Double) -> LinearGradient {
        let base = appearance.textColor.opacity(appearance.dimOpacity)
        let lit = appearance.highlightColor
        return LinearGradient(
            stops: [
                .init(color: lit, location: 0),
                .init(color: lit, location: p),
                .init(color: base, location: min(p + 0.0001, 1)),
                .init(color: base, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
