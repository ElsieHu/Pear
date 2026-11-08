import SwiftUI
import AppKit
import Translation
import LyricEngine
import AppleMusicBridge

/// Preferences window.
///
/// Layout rules (Nov 3 feedback):
/// - **One continuous background.** The tinted preview header, the system
///   `TabView` grey band and the inset `Form` cards used to stack three
///   different grey shades on top of each other — that was the "分层" look.
///   Everything now sits on the window's own background; the only separator
///   is a single hairline under a self-drawn, flat tab strip.
/// - **No small caption-style explanations.** Explanatory text was scattered
///   under every section at `.caption` / `.caption2` size. The current state
///   values that actually matter (font size, radius, offset, …) are kept, but
///   shown at body size on the same line as their label.
struct SettingsView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var translator = TranslationService.shared
    @State private var selectedTab: SettingsTab = .color
    @State private var showsTranslationSetup = false

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case color = "配色"
        case text = "文字"
        case shape = "外形"
        case behaviour = "行为"
        case translation = "翻译"
        case menuBar = "菜单栏"
        case status = "状态"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            previewHeader
            tabStrip
            Divider()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Match the NSWindow's own background so there is no second layer.
        .background(Color(NSColor.windowBackgroundColor))
        // Keep this in sync with the manually-created NSWindow in
        // StatusBarController.openSettings(); a narrower window clips the
        // pinned preview horizontally.
        .frame(width: 500, height: 600)
    }

    // MARK: - Pinned preview

    private var previewHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前浮窗")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            PreviewPill()
                .frame(maxWidth: .infinity, minHeight: 62, alignment: .center)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        // Room for the halo so it never touches the tab strip.
        .padding(.bottom, 20)
    }

    // MARK: - Flat tab strip
    //
    // A native TabView draws its own grey band across the window. That band
    // plus the form's lighter background read as two stacked slabs, so draw
    // the tabs as plain buttons on the shared background instead.

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.body)
                        .foregroundStyle(selectedTab == tab
                                         ? Color(NSColor.controlAccentColor)
                                         : Color(NSColor.secondaryLabelColor))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selectedTab == tab
                                      ? Color(NSColor.controlAccentColor).opacity(0.16)
                                      : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var page: some View {
        switch selectedTab {
        case .color: colorTab
        case .text: textTab
        case .shape: shapeTab
        case .behaviour: behaviourTab
        case .translation: translationTab
        case .menuBar: menuBarTab
        case .status: statusTab
        }
    }

    // MARK: - Colour

    /// Plain buttons, not a Picker: a Picker bound to a nested @Published
    /// field writes its selection back while the view is being redrawn.
    private func optionButton(_ title: String, selected: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 22)
                .padding(.horizontal, 4)
                .background(selected ? Color.accentColor.opacity(0.9) : Color.clear)
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func colourModeButton(_ title: String, mode: String) -> some View {
        let selected = state.appearance.colorModeRaw == mode
        return optionButton(title, selected: selected) {
            guard !selected else { return }
            var updated = state.appearance
            updated.colorModeRaw = mode
            state.appearance = updated
        }
    }

    /// The two automatic colours are ordered by luminance; this picks which
    /// one becomes the pill. Default: dark background, light lyrics.
    private func backgroundRoleButton(_ title: String, dark: Bool) -> some View {
        let selected = state.appearance.preferDarkBackground == dark
        return optionButton(title, selected: selected) {
            guard !selected else { return }
            var updated = state.appearance
            updated.preferDarkBackground = dark
            state.appearance = updated
        }
    }

    private func fidelityButton(_ title: String, fidelity: Bool) -> some View {
        let selected = state.appearance.colourFidelityFirst == fidelity
        return optionButton(title, selected: selected) {
            guard !selected else { return }
            var updated = state.appearance
            updated.colourFidelityFirst = fidelity
            state.appearance = updated
        }
    }

    private func segmented(_ content: some View) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            )
            .frame(maxWidth: 260)
    }

    private var colorTab: some View {
        SettingsPage {
            SettingsSection("配色来源") {
                SettingsRow("来源") {
                    segmented(HStack(spacing: 0) {
                        colourModeButton("Apple 配色", mode: "album")
                        colourModeButton("封面取色", mode: "artwork")
                        colourModeButton("手动", mode: "manual")
                    })
                }

                if state.appearance.colorModeRaw != "manual" {
                    SettingsRow("底色") {
                        segmented(HStack(spacing: 0) {
                            backgroundRoleButton("较暗打底", dark: true)
                            backgroundRoleButton("较亮打底", dark: false)
                        })
                    }
                    SettingsRow("颜色处理") {
                        segmented(HStack(spacing: 0) {
                            fidelityButton("保真", fidelity: true)
                            fidelityButton("易读", fidelity: false)
                        })
                    }
                }
            }

            currentColorSection

            // Nothing below applies unless the user explicitly chose 手动 —
            // showing manual swatches while album/artwork colours are active
            // was confusing (they had no effect).
            if state.appearance.colorModeRaw == "manual" {
                SettingsSection("手动配色预设") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              spacing: 10) {
                        ForEach(LyricAppearance.presets, id: \.name) { preset in
                            Button {
                                // applyPreset owns the mode switch, so a single
                                // assignment triggers one persist (no double didSet).
                                state.applyPreset(preset.appearance)
                            } label: {
                                VStack(spacing: 6) {
                                    // Both orientations of the pair at once —
                                    // the swap button flips the live colours.
                                    HStack(spacing: 0) {
                                        presetHalf(background: preset.appearance.backgroundColorHex,
                                                   foreground: preset.appearance.textColorHex)
                                        presetHalf(background: preset.appearance.textColorHex,
                                                   foreground: preset.appearance.backgroundColorHex)
                                    }
                                    .frame(height: 28)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    Text(preset.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // Fixed height: an unconstrained LazyVGrid inside a
                    // scrolling page re-measures on every pass and stutters.
                    .frame(height: 232)

                    HStack {
                        Spacer()
                        Button {
                            state.swapManualColors()
                        } label: {
                            Text("⇄ 交换背景色与歌词颜色").font(.body)
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                }

                SettingsSection("手动颜色") {
                    ColorPicker("歌词底色(未唱到)", selection: colorBinding(\.textColorHex))
                    ColorPicker("高亮色(已唱到)", selection: colorBinding(\.highlightColorHex))
                    ColorPicker("浮窗背景", selection: colorBinding(\.backgroundColorHex))
                    SettingsSlider(title: "未唱部分不透明度",
                                   value: "\(Int(state.appearance.dimOpacity * 100))%",
                                   binding: $state.appearance.dimOpacity,
                                   range: 0.1...1.0, step: 0.05)
                }
            }
        }
    }

    /// Live palette and contrast, at body size on the same line as each
    /// label. Showing the source's two colours separately from the assigned
    /// background / lyric roles makes the dark↔light swap visible.
    private var currentColorSection: some View {
        let ap = state.effectiveAppearance
        let bg = Color(hex: ap.backgroundColorHex) ?? .gray
        let fg = Color(hex: ap.textColorHex) ?? .white
        let ratio = Color.contrast(fg, bg)
        // The source colour and the colour actually on screen are different
        // things in 易读 mode. Showing both is what makes the adjustment
        // visible instead of looking like the extractor "picked black".
        let sourceTextHex = state.appearance.colorModeRaw != "manual"
            ? state.autoTextHex : nil
        let textAdjusted = sourceTextHex.map {
            $0.uppercased() != ap.textColorHex.uppercased()
        } ?? false

        let sourceDark: String?
        let sourceLight: String?
        if state.appearance.colorModeRaw != "manual",
           let a = state.autoBackgroundHex, let b = state.autoTextHex {
            let ca = Color(hex: a) ?? .gray
            let cb = Color(hex: b) ?? .white
            if ca.wcagLuminance <= cb.wcagLuminance {
                sourceDark = a
                sourceLight = b
            } else {
                sourceDark = b
                sourceLight = a
            }
        } else {
            sourceDark = nil
            sourceLight = nil
        }

        return SettingsSection("当前配色") {
            SettingsRow("来源") {
                Text(currentSourceLabel).font(.body)
            }
            if let sourceDark, let sourceLight {
                SettingsRow("来源两色") {
                    HStack(spacing: 6) {
                        colorSwatch(sourceDark)
                        Text(sourceDark).font(.body)
                        Text("·").foregroundStyle(.secondary)
                        colorSwatch(sourceLight)
                        Text(sourceLight).font(.body)
                    }
                }
            }
            SettingsRow("实际底色") {
                HStack(spacing: 8) {
                    colorSwatch(ap.backgroundColorHex)
                    Text(ap.backgroundColorHex).font(.body)
                }
            }
            SettingsRow("实际歌词色") {
                HStack(spacing: 8) {
                    colorSwatch(ap.textColorHex)
                    Text(ap.textColorHex).font(.body)
                }
            }
            if state.appearance.colorModeRaw != "manual" {
                SettingsRow("字色处理") {
                    HStack(spacing: 6) {
                        if textAdjusted, let sourceTextHex {
                            colorSwatch(sourceTextHex)
                            Text("→").foregroundStyle(.secondary)
                            colorSwatch(ap.textColorHex)
                            Text("易读已微调").font(.body)
                        } else {
                            Text("原样").font(.body)
                        }
                    }
                }
            }
            SettingsRow("对比度") {
                Text(String(format: "%.1f:1 · 未唱 %d%%", ratio,
                            Int((ap.dimOpacity * 100).rounded()))).font(.body)
            }
        }
    }

    private var currentSourceLabel: String {
        switch state.appearance.colorModeRaw {
        case "manual":
            return "手动配色"
        case "artwork":
            return state.autoBackgroundHex == nil
                ? "暂用手动配色(等待封面两色)" : "封面取色"
        default:
            return state.autoBackgroundHex == nil
                ? "暂用手动配色(等待 Apple 两色)" : "Apple 配色"
        }
    }

    private func colorSwatch(_ hex: String) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color(hex: hex) ?? .gray)
            .frame(width: 16, height: 16)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.secondary.opacity(0.45), lineWidth: 0.5)
            )
    }

    private func presetHalf(background: String, foreground: String) -> some View {
        ZStack {
            Rectangle().fill(Color(hex: background) ?? .gray)
            Text("词")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color(hex: foreground) ?? .white)
        }
    }

    // MARK: - Text

    private var textTab: some View {
        SettingsPage {
            SettingsSection("文字") {
                SettingsRow("字体") {
                    Picker("", selection: $state.appearance.fontName) {
                        Text("系统字体").tag("")
                        Divider()
                        ForEach(Self.fontFamilies, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }

                SettingsRow("字重") {
                    Picker("", selection: $state.appearance.fontWeightRaw) {
                        Text("常规").tag("regular")
                        Text("中等").tag("medium")
                        Text("半粗").tag("semibold")
                        Text("粗体").tag("bold")
                        Text("特粗").tag("heavy")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 140)
                }

                SettingsSlider(title: "字号",
                               value: "\(Int(state.appearance.fontSize)) pt",
                               binding: $state.appearance.fontSize,
                               range: 12...64, step: 1)

                SettingsRow("对齐") {
                    Picker("", selection: $state.appearance.textAlignmentRaw) {
                        Text("左").tag("leading")
                        Text("中").tag("center")
                        Text("右").tag("trailing")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                }
            }
        }
    }

    // MARK: - Shape & shadow

    private var shapeTab: some View {
        SettingsPage {
            SettingsSection("外形") {
                SettingsSlider(title: "背景不透明度",
                               value: "\(Int(state.appearance.backgroundOpacity * 100))%",
                               binding: $state.appearance.backgroundOpacity,
                               range: 0...1, step: 0.02)
                SettingsSlider(title: "圆角",
                               value: "\(Int(state.appearance.cornerRadius)) pt",
                               binding: $state.appearance.cornerRadius,
                               range: 0...30, step: 1)
                SettingsSlider(title: "左右内边距",
                               value: "\(Int(state.appearance.horizontalPadding)) pt",
                               binding: $state.appearance.horizontalPadding,
                               range: 4...60, step: 1)
                SettingsSlider(title: "上下内边距",
                               value: "\(Int(state.appearance.verticalPadding)) pt",
                               binding: $state.appearance.verticalPadding,
                               range: 2...40, step: 1)
                SettingsSlider(title: "最大宽度",
                               value: "\(Int(state.appearance.maxWidth)) pt",
                               binding: $state.appearance.maxWidth,
                               range: 240...1400, step: 20)
            }

            SettingsSection("投影") {
                SettingsRow("投影") {
                    Toggle("", isOn: $state.appearance.shadowEnabled)
                        .labelsHidden()
                }
                if state.appearance.shadowEnabled {
                    SettingsSlider(title: "阴影强度",
                                   value: "\(Int(state.appearance.shadowIntensity * 100))%",
                                   binding: $state.appearance.shadowIntensity,
                                   range: 0...0.8, step: 0.02)
                }
            }
        }
    }

    // MARK: - Behaviour

    private var behaviourTab: some View {
        SettingsPage {
            SettingsSection("显示") {
                SettingsRow("显示下一句(更小更暗)") {
                    Toggle("", isOn: $state.appearance.showNextLine)
                        .labelsHidden()
                }
                SettingsRow("逐字/逐行扫光高亮") {
                    Toggle("", isOn: $state.appearance.sweepEnabled)
                        .labelsHidden()
                }
                SettingsRow("鼠标悬停时淡出") {
                    Toggle("", isOn: $state.appearance.hideOnHover)
                        .labelsHidden()
                }
                SettingsRow("锁定位置(禁止拖动)") {
                    Toggle("", isOn: $state.appearance.lockPosition)
                        .labelsHidden()
                }
                SettingsRow("点击穿透(浮窗不接收鼠标)") {
                    Toggle("", isOn: $state.appearance.clickThrough)
                        .labelsHidden()
                }
            }

            SettingsSection("歌词时间校准") {
                SettingsSlider(title: "偏移（+ 提前 / − 延后）",
                               value: String(format: "%+.1f 秒", state.lyricTimeOffset),
                               binding: $state.lyricTimeOffset,
                               range: -5...5, step: 0.1)
                HStack {
                    Spacer()
                    Button("归零") { state.lyricTimeOffset = 0 }
                        .font(.body)
                }
            }

            SettingsSection("启动") {
                SettingsRow("开机时自动启动 Pear") {
                    Toggle("", isOn: Binding(
                        get: { state.launchAtLogin },
                        set: { state.setLaunchAtLogin($0) }
                    ))
                    .labelsHidden()
                }
            }

            SettingsSection("重置") {
                HStack(spacing: 12) {
                    Button("恢复默认外观") { state.resetAppearance() }
                        .font(.body)
                    Button("重置浮窗位置") {
                        NotificationCenter.default.post(name: .resetPanelPosition, object: nil)
                    }
                    .font(.body)
                }
            }
        }
    }

    // MARK: - Translation

    private var translationTab: some View {
        SettingsPage {
            SettingsSection("翻译") {
                SettingsRow("显示译文") {
                    Toggle("", isOn: $translator.settings.enabled)
                        .labelsHidden()
                        .disabled(!translator.isAvailable)
                }

                SettingsRow("目标语言") {
                    Picker("", selection: $translator.settings.targetLanguage) {
                        ForEach(TranslationSettings.targets, id: \.id) { target in
                            Text(target.name).tag(target.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }

                SettingsSlider(title: "译文字号",
                               value: "\(Int(translator.settings.relativeSize * 100))%",
                               binding: $translator.settings.relativeSize,
                               range: 0.4...0.9, step: 0.02)

                SettingsRow("同时显示下一句") {
                    Toggle("", isOn: $translator.settings.keepNextLine)
                        .labelsHidden()
                }
            }

            SettingsSection("状态") {
                SettingsRow("当前状态") {
                    Text(translator.status).font(.body).foregroundStyle(.secondary)
                }
                SettingsRow("系统要求") {
                    Text(translator.isAvailable ? "macOS 15 或更新" : "需要 macOS 15 或更新")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                SettingsRow("缓存") {
                    Text(TranslationRules.formattedCacheSize(translator.cacheBytes))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if #available(macOS 15.0, *) {
                        // Only offer the system download flow when the model
                        // really is missing; otherwise the popover would just
                        // show a sample translation with nothing to install.
                        if translator.needsModelSetup {
                            Button("下载语言模型") { showsTranslationSetup = true }
                                .font(.body)
                                .translationPresentation(
                                    isPresented: $showsTranslationSetup,
                                    text: "Hello, how are you? こんにちは 안녕하세요")
                                .onChange(of: showsTranslationSetup) { _, showing in
                                    if !showing { translator.retry() }
                                }
                        }
                        Button("重新翻译") { translator.retry() }
                            .font(.body)
                            .disabled(!translator.settings.enabled)
                    }
                    Button("清理缓存") { translator.clearCache() }
                        .font(.body)
                        .disabled(translator.cacheBytes == 0)
                }
            }
        }
        .onAppear { translator.refreshCacheSize() }
    }

    // MARK: - Menu bar

    private var menuBarTab: some View {
        SettingsPage {
            SettingsSection("菜单栏") {
                SettingsRow("显示图标") {
                    Toggle("", isOn: $state.menuBarDisplay.showsIcon).labelsHidden()
                }
                SettingsRow("显示歌曲名") {
                    Toggle("", isOn: $state.menuBarDisplay.showsTitle).labelsHidden()
                }
                SettingsRow("显示歌手名") {
                    Toggle("", isOn: $state.menuBarDisplay.showsArtist).labelsHidden()
                }
                SettingsRow("当前显示") {
                    Text(menuBarPreview)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var menuBarPreview: String {
        let d = state.menuBarDisplay
        if d.isEffectivelyEmpty { return "♪" }
        let preview = d.label(title: state.monitor.track?.title ?? "歌曲名",
                              artist: state.monitor.track?.artist ?? "歌手名")
        let iconPart = d.showsIcon ? "♪ " : ""
        return iconPart + (preview.isEmpty ? "♪" : preview)
    }

    // MARK: - Status

    private var statusTab: some View {
        SettingsPage {
            SettingsSection("状态") {
                if let t = state.monitor.track {
                    SettingsRow("曲目") {
                        Text(t.title).font(.body).lineLimit(1)
                    }
                    SettingsRow("艺人") {
                        Text(t.artist).font(.body).lineLimit(1)
                    }
                } else {
                    Text("未在「音乐」中播放")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                if state.isFetching {
                    SettingsRow("歌词") { Text("读取中…").font(.body) }
                } else if let lyrics = state.lyrics {
                    SettingsRow("歌词来源") { Text(lyrics.source).font(.body) }
                    SettingsRow("行数") { Text("\(lyrics.lines.count)").font(.body) }
                    SettingsRow("时间轴") {
                        Text(lyrics.hasWordTiming ? "逐字" : "逐行").font(.body)
                    }
                } else if let err = state.lastError {
                    Text(err).font(.body).foregroundStyle(.orange)
                }

                // Live values isolated in a TimelineView so the rest of the
                // page is not invalidated on every playback tick.
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsRow("播放进度") {
                            Text(String(format: "%.1f 秒", state.monitor.smoothPosition))
                                .monospacedDigit().font(.body)
                        }
                        SettingsRow("歌词时间(含校准)") {
                            Text(String(format: "%.1f 秒",
                                        max(0, state.monitor.smoothPosition + state.lyricTimeOffset)))
                                .monospacedDigit().font(.body)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button("重新获取歌词") { state.retry() }
                        .font(.body)
                    Button("打开「自动化」隐私设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.body)
                }
            }
        }
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

// MARK: - Flat, reusable building blocks
//
// Replacing `Form` + `.formStyle(.grouped)` removes the inset cards entirely:
// there is only one background surface from the title bar down to the last row.

private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(.body)
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 24)
    }
}

/// A slider whose current value sits on the label line at **body** size —
/// no `.caption` footnote underneath, but the number is still visible.
private struct SettingsSlider: View {
    let title: String
    let value: String
    @Binding var binding: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.body)
                Spacer()
                Text(value)
                    .monospacedDigit()
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Slider(value: $binding, in: range, step: step) {
                Text("")
            }
            .labelsHidden()
        }
    }
}

/// Miniature of the real pill, so settings changes are visible immediately.
/// It mirrors the window's soft, rounded shadow — including "显示下一句",
/// which previously had no visible effect in the preview at all.
private struct PreviewPill: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var translator = TranslationService.shared

    var body: some View {
        let ap = state.effectiveAppearance
        let showNext = ap.showNextLine
            && (!translator.settings.enabled || translator.settings.keepNextLine)
        VStack(spacing: 4) {
            // One line covers 中文 / English / 日本語 / 한국어, so the sample
            // still exercises every script when "显示下一句" is off.
            Text("散文诗 Hello こんにちは 안녕하세요")
                .font(ap.font(size: min(ap.fontSize, 20)))
                .lineLimit(1)
                // Both halves exactly as the real pill draws them, so the
                // preview exposes an unreadable dim colour instead of hiding
                // it behind a fully opaque sample line.
                .foregroundStyle(
                    LinearGradient(stops: [
                        .init(color: ap.highlightColor, location: 0),
                        .init(color: ap.highlightColor, location: 0.45),
                        .init(color: ap.textColor.opacity(ap.dimOpacity), location: 0.46),
                        .init(color: ap.textColor.opacity(ap.dimOpacity), location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                )
            if translator.settings.enabled {
                Text("译文示例 Translation 訳文 번역문")
                    .font(ap.font(size: min(ap.fontSize, 20) * translator.settings.relativeSize))
                    .lineLimit(1)
                    .foregroundColor(ap.textColor.opacity(max(ap.dimOpacity, 0.82)))
            }
            if showNext {
                Text("再见 Bye さよなら 안녕")
                    .font(ap.font(size: min(ap.fontSize, 20) * ap.nextLineScale))
                    .lineLimit(1)
                    .foregroundColor(ap.textColor.opacity(ap.dimOpacity))
            }
        }
        .padding(.horizontal, min(ap.horizontalPadding, 18))
        .padding(.vertical, min(ap.verticalPadding, 8))
        .background(ap.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: min(ap.cornerRadius, 14), style: .continuous))
        .shadow(color: .black.opacity(ap.shadowEnabled ? ap.shadowIntensity : 0),
                radius: LyricAppearance.shadowBlurRadius, x: 0, y: 1)
    }
}
