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
            .background(ap.backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: ap.cornerRadius, style: .continuous))
            .shadow(color: ap.shadowEnabled ? Color.black.opacity(0.28) : .clear,
                    radius: 18, x: 0, y: 8)
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
        case let .idle(message):
            Text(message)
                .font(ap.font(size: max(13, ap.fontSize * 0.6)))
                .foregroundColor(ap.textColor.opacity(0.85))
                .lineLimit(1)
                .frame(maxWidth: ap.maxWidth)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text("正在读取 Apple Music 歌词…")
                    .font(ap.font(size: max(13, ap.fontSize * 0.6)))
            }
            .foregroundColor(ap.textColor.opacity(0.85))
            .frame(maxWidth: ap.maxWidth)
        case .lyrics:
            lyricsBody
        }
    }

    @ViewBuilder
    private var lyricsBody: some View {
        if let lyrics = state.lyrics, !lyrics.lines.isEmpty {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                let pos = state.monitor.smoothPosition
                let idx = lyrics.activeLineIndex(at: pos) ?? 0
                let line = lyrics.lines[idx]
                let progress = ap.sweepEnabled ? lyrics.lineProgress(line, at: pos) : 1

                VStack(alignment: ap.horizontalAlignment, spacing: 6) {
                    KaraokeLine(
                        text: line.text.isEmpty ? "♪" : line.text,
                        progress: progress,
                        appearance: ap
                    )
                    if ap.showNextLine, idx + 1 < lyrics.lines.count {
                        KaraokeLine(
                            text: lyrics.lines[idx + 1].text,
                            progress: 0,
                            appearance: ap,
                            scale: ap.nextLineScale,
                            opacity: ap.dimOpacity
                        )
                    }
                }
                .frame(maxWidth: ap.maxWidth, alignment: ap.frameAlignment)
                .animation(.easeOut(duration: 0.18), value: idx)
            }
        }
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
