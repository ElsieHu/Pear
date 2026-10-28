import SwiftUI
import AppKit
import AppleMusicBridge

/// The panel shown when the menu-bar icon is clicked: now-playing header
/// (artwork, title, artist · album, transport, progress) plus the action rows.
struct NowPlayingView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var artwork = ArtworkLoader.shared
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showDiagnostics = false

    private let artworkSize: CGFloat = 72

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            actionRows
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
        }
        .frame(width: 320)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                artworkView

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.monitor.track?.title ?? "未在播放")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            progressRow

            HStack(spacing: 22) {
                controlButton("backward.fill") { state.monitor.previousTrack() }
                controlButton(state.monitor.isPlaying ? "pause.fill" : "play.fill") {
                    state.monitor.togglePlayPause()
                }
                controlButton("forward.fill") { state.monitor.nextTrack() }
            }
            .font(.system(size: 16))
        }
    }

    private var artworkView: some View {
        Group {
            if let img = artwork.image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.18))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(radius: 3, y: 1)
    }

    private var subtitle: String {
        guard let t = state.monitor.track else { return "在“音乐”中播放一首歌" }
        return [t.artist, t.album].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - Progress

    private var progressRow: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = max(state.monitor.track?.duration ?? 0, 1)
            let position = min(max(state.monitor.smoothPosition, 0), duration)
            let shown = scrubbing ? scrubValue : position

            VStack(spacing: 4) {
                Slider(value: Binding(
                    get: { shown },
                    set: { scrubValue = $0 }
                ), in: 0...duration) { editing in
                    scrubbing = editing
                    if !editing { state.monitor.seek(to: scrubValue) }
                }
                .controlSize(.small)

                HStack {
                    Text(Self.time(shown))
                    Spacer()
                    Text("-\(Self.time(max(duration - shown, 0)))")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Controls

    private func controlButton(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rows

    private var actionRows: some View {
        VStack(spacing: 1) {
            MenuRow(title: "浮动歌词", shortcut: "⌃⌥L", checked: state.windowEnabled) {
                state.windowEnabled.toggle()
            }
            .keyboardShortcut("l", modifiers: [.control, .option])

            MenuRow(title: "锁定浮动歌词", shortcut: "⌃⌥K", checked: state.appearance.lockPosition) {
                state.appearance.lockPosition.toggle()
            }
            .keyboardShortcut("k", modifiers: [.control, .option])

            MenuRow(title: "鼠标穿透浮动歌词", checked: state.appearance.clickThrough) {
                state.appearance.clickThrough.toggle()
            }

            MenuRow(title: "刷新歌词", shortcut: "⌘R") { state.retry() }
                .keyboardShortcut("r", modifiers: .command)

            if state.monitor.track == nil {
                MenuRow(title: "⚠︎ 允许控制“音乐”(自动化)") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            MenuRow(title: "诊断日志", disclosure: true) {
                withAnimation { showDiagnostics.toggle() }
            }

            if showDiagnostics {
                diagnostics
                MenuRow(title: "在访达中显示日志文件") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
                }
            }

            MenuRow(title: "偏好设置…", shortcut: "⌘,") {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider().padding(.vertical, 4)

            MenuRow(title: "退出歌词浮窗", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var diagnostics: some View {
        let ap = state.effectiveAppearance
        return VStack(alignment: .leading, spacing: 3) {
            diagLine("曲目", state.monitor.track?.title ?? "—")
            diagLine("歌词来源", state.lyrics?.source ?? "—")
            diagLine("行数", state.lyrics.map { "\($0.lines.count)" } ?? "—")
            diagLine("时间轴", (state.lyrics?.hasWordTiming ?? false) ? "逐字" : "逐行")
            diagLine("配色模式", ap.colorModeRaw == "manual" ? "手动" : (ap.colorModeRaw == "album" ? "专辑配色" : "封面取色"))
            diagLine("浮窗底色", ap.backgroundColorHex)
            if let err = state.lastError {
                diagLine("最近错误", err)
            }
            Divider().padding(.vertical, 2)
            Text(AppLog.tail(12))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private func diagLine(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.tertiary)
            Spacer()
            Text(v).lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: - Helpers

    private static func time(_ seconds: Double) -> String {
        let s = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A menu-like row with hover highlight, optional check mark and shortcut.
struct MenuRow: View {
    let title: String
    var shortcut: String?
    var checked: Bool = false
    var disclosure: Bool = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(checked ? "✓" : "")
                    .frame(width: 12, alignment: .leading)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 4)
                if disclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                } else if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hovered ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovered ? .white : .primary)
        .onHover { hovered = $0 }
    }
}

