import SwiftUI
import AppKit
import LyricEngine
import AppleMusicBridge

/// Preferences window.
///
/// Layout rule from the user: the live pill preview stays **pinned at the top**
/// and never scrolls away, while the actual knobs are grouped into tabs below
/// it. That way every change is visible in the preview without scrolling.
///
/// Performance notes (scroll stutter was reported here):
/// - No `ScrollView` wrapper around `Form`: `Form` already scrolls.
/// - No direct reads of `monitor.smoothPosition` in the tab bodies; live
///   values live inside a `TimelineView` so only that row invalidates.
/// - `AppleMusicMonitor` publishes only on real changes, so we no longer
///   re-render 4×/sec for free.
struct SettingsView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        VStack(spacing: 0) {
            previewHeader
            Divider()
            TabView {
                colorTab
                    .tabItem { Label("配色", systemImage: "paintpalette") }
                textTab
                    .tabItem { Label("文字", systemImage: "textformat.size") }
                shapeTab
                    .tabItem { Label("外形", systemImage: "rectangle.roundedtop") }
                behaviourTab
                    .tabItem { Label("行为", systemImage: "slider.horizontal.3") }
                menuBarTab
                    .tabItem { Label("菜单栏", systemImage: "menubar.rectangle") }
                statusTab
                    .tabItem { Label("状态", systemImage: "info.circle") }
            }
        }
        // Keep this in sync with the manually-created NSWindow in
        // StatusBarController.openSettings(); a narrower window clips the
        // pinned preview horizontally.
        .frame(width: 500, height: 600)
    }

    // MARK: - Pinned preview

    private var previewHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Text("当前浮窗")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("改动即时生效")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            PreviewPill()
                .frame(maxWidth: .infinity, minHeight: 62)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Colour

    private var colorTab: some View {
        Form {
            Section("配色来源") {
                Picker("来源", selection: $state.appearance.colorModeRaw) {
                    Text("专辑配色").tag("album")
                    Text("封面取色").tag("artwork")
                    Text("手动").tag("manual")
                }
                .pickerStyle(.segmented)

                Text(modeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Only meaningful for the automatic modes: in manual mode
                // `effective()` returns the user's colours untouched.
                if state.appearance.colorModeRaw != "manual" {
                    Toggle("封面过亮时自动压暗(保证可读)",
                           isOn: $state.appearance.autoDarkenLightBackgrounds)
                }
            }

            // Nothing below applies unless the user explicitly chose 手动 —
            // showing manual swatches while album/artwork colours are active
            // was confusing (they had no effect).
            if state.appearance.colorModeRaw == "manual" {
                Section("手动配色预设") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                        ForEach(LyricAppearance.presets, id: \.name) { preset in
                            Button {
                                // applyPreset owns the mode switch, so a single
                                // assignment triggers one persist (no double didSet).
                                state.applyPreset(preset.appearance)
                            } label: {
                                VStack(spacing: 3) {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color(hex: preset.appearance.backgroundColorHex) ?? .purple)
                                        .frame(height: 26)
                                        .overlay(
                                            Text("词")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundColor(Color(hex: preset.appearance.textColorHex) ?? .white)
                                        )
                                    Text(preset.name)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // Fixed height: an unconstrained LazyVGrid inside a
                    // scrolling Form re-measures on every pass and stutters.
                    .frame(height: 82)
                }

                Section("手动颜色") {
                    ColorPicker("歌词底色(未唱到)", selection: colorBinding(\.textColorHex))
                    ColorPicker("高亮色(已唱到)", selection: colorBinding(\.highlightColorHex))
                    ColorPicker("浮窗背景", selection: colorBinding(\.backgroundColorHex))
                    Slider(value: $state.appearance.dimOpacity, in: 0.1...1.0, step: 0.05) {
                        Text("未唱部分不透明度")
                    }
                    Text("\(Int(state.appearance.dimOpacity * 100))%　(调低会让扫光对比更明显)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var modeHint: String {
        switch state.appearance.colorModeRaw {
        case "album":
            return "使用 Apple 为专辑封面计算的 bgColor / textColor1 配色，离线即时生效。"
        case "artwork":
            return "下载封面图并提取主色(需联网)，明暗对比由程序保证。"
        default:
            return "使用下方手动指定的颜色，可先挑一个预设再微调。"
        }
    }

    // MARK: - Text

    private var textTab: some View {
        Form {
            Section("文字") {
                Picker("字体", selection: $state.appearance.fontName) {
                    Text("系统字体").tag("")
                    Divider()
                    ForEach(Self.fontFamilies, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }

                Picker("字重", selection: $state.appearance.fontWeightRaw) {
                    Text("常规").tag("regular")
                    Text("中等").tag("medium")
                    Text("半粗").tag("semibold")
                    Text("粗体").tag("bold")
                    Text("特粗").tag("heavy")
                }

                Slider(value: $state.appearance.fontSize, in: 12...64, step: 1) {
                    Text("字号")
                } minimumValueLabel: {
                    Text("12")
                } maximumValueLabel: {
                    Text("64")
                }
                Text("当前: \(Int(state.appearance.fontSize)) pt")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("对齐", selection: $state.appearance.textAlignmentRaw) {
                    Text("左").tag("leading")
                    Text("中").tag("center")
                    Text("右").tag("trailing")
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shape & shadow

    private var shapeTab: some View {
        Form {
            Section("外形") {
                Slider(value: $state.appearance.backgroundOpacity, in: 0...1, step: 0.02) {
                    Text("背景不透明度")
                }
                Slider(value: $state.appearance.cornerRadius, in: 0...30, step: 1) {
                    Text("圆角")
                }
                Slider(value: $state.appearance.horizontalPadding, in: 4...60, step: 1) {
                    Text("左右内边距")
                }
                Slider(value: $state.appearance.verticalPadding, in: 2...40, step: 1) {
                    Text("上下内边距")
                }
                Slider(value: $state.appearance.maxWidth, in: 240...1400, step: 20) {
                    Text("最大宽度")
                }
            }

            Section("投影") {
                Toggle("投影", isOn: $state.appearance.shadowEnabled)
                if state.appearance.shadowEnabled {
                    Slider(value: $state.appearance.shadowIntensity, in: 0...0.8, step: 0.02) {
                        Text("阴影强度")
                    }
                    Text("\(Int(state.appearance.shadowIntensity * 100))%　(阴影始终跟随圆角，四周柔和环绕)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Behaviour

    private var behaviourTab: some View {
        Form {
            Section("显示") {
                Toggle("显示下一句(更小更暗)", isOn: $state.appearance.showNextLine)
                Toggle("逐字/逐行扫光高亮", isOn: $state.appearance.sweepEnabled)
                Toggle("鼠标悬停时淡出", isOn: $state.appearance.hideOnHover)
                Toggle("锁定位置(禁止拖动)", isOn: $state.appearance.lockPosition)
                Toggle("点击穿透(浮窗不接收鼠标)", isOn: $state.appearance.clickThrough)
            }

            Section("歌词时间校准") {
                Slider(value: $state.lyricTimeOffset, in: -5...5, step: 0.1) {
                    Text("偏移")
                }
                Text("当前：\(String(format: "%+.1f", state.lyricTimeOffset)) 秒　(+ 让歌词提前，- 让歌词延后)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("若歌词整体比音乐慢几秒，往 + 方向微调直到对齐。")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("归零") { state.lyricTimeOffset = 0 }
            }

            Section("启动") {
                Toggle("开机时自动启动 Pear", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                ))
                Text("开关状态取自实际的登录项配置；变更最迟在下次登录时生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("重置") {
                Button("恢复默认外观") { state.resetAppearance() }
                Button("重置浮窗位置") {
                    NotificationCenter.default.post(name: .resetPanelPosition, object: nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Menu bar

    private var menuBarTab: some View {
        Form {
            Section("菜单栏") {
                Toggle("显示图标", isOn: $state.menuBarDisplay.showsIcon)
                Toggle("显示歌曲名", isOn: $state.menuBarDisplay.showsTitle)
                Toggle("显示歌手名", isOn: $state.menuBarDisplay.showsArtist)

                Text(menuBarHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var menuBarHint: String {
        let d = state.menuBarDisplay
        if d.isEffectivelyEmpty {
            return "至少要留一项，否则菜单栏入口会消失 —— 已自动保留图标。"
        }
        let preview = d.label(title: state.monitor.track?.title ?? "歌曲名",
                              artist: state.monitor.track?.artist ?? "歌手名")
        let iconPart = d.showsIcon ? "♪ " : ""
        return "当前：\(iconPart)\(preview)　(过长会自动截断)"
    }

    // MARK: - Status

    private var statusTab: some View {
        Form {
            Section("状态") {
                if let t = state.monitor.track {
                    LabeledContent("曲目", value: t.title)
                    LabeledContent("艺人", value: t.artist)
                } else {
                    Text("未在“音乐”中播放").foregroundStyle(.secondary)
                }

                if state.isFetching {
                    LabeledContent("歌词", value: "读取中…")
                } else if let lyrics = state.lyrics {
                    LabeledContent("歌词来源", value: lyrics.source)
                    LabeledContent("行数", value: "\(lyrics.lines.count)")
                    LabeledContent("时间轴", value: lyrics.hasWordTiming ? "逐字" : "逐行")
                } else if let err = state.lastError {
                    Text(err).foregroundStyle(.orange).font(.caption)
                }

                // Live values isolated in a TimelineView so the rest of the
                // form is not invalidated on every playback tick.
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("播放进度 \(String(format: "%.1f", state.monitor.smoothPosition)) 秒")
                        Text("歌词时间 \(String(format: "%.1f", max(0, state.monitor.smoothPosition + state.lyricTimeOffset))) 秒 (含校准)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Button("重新获取歌词") { state.retry() }
                Button("打开「自动化」隐私设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Text("首次运行需在「自动化」里允许本应用控制“音乐”。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func colorBinding(_ keyPath: WritableKeyPath<LyricAppearance, String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: state.appearance[keyPath: keyPath]) ?? .white },
            set: { state.appearance[keyPath: keyPath] = $0.hexString }
        )
    }

    private static let fontFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies.sorted()
    }()
}

/// Miniature of the real pill, so settings changes are visible immediately.
/// It mirrors the window's soft, rounded shadow so the preview looks like the
/// real thing rather than a flat swatch.
private struct PreviewPill: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        let ap = state.effectiveAppearance
        Text("父亲写的散文诗")
            .font(ap.font(size: min(ap.fontSize, 20)))
            .lineLimit(1)
            .foregroundColor(ap.textColor)
            .padding(.horizontal, min(ap.horizontalPadding, 18))
            .padding(.vertical, min(ap.verticalPadding, 8))
            .background(ap.backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: min(ap.cornerRadius, 14), style: .continuous))
            .shadow(color: .black.opacity(ap.shadowEnabled ? ap.shadowIntensity : 0),
                    radius: 22, x: 0, y: 1)
    }
}
