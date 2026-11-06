import SwiftUI
import AppKit

/// Every visual knob of the floating lyrics window, persisted as JSON.
struct LyricAppearance: Codable, Equatable {

    /// Empty string means "system font".
    var fontName: String = ""
    var fontSize: Double = 22
    var fontWeightRaw: String = "bold"

    var textColorHex: String = "#FFFFFF"
    var highlightColorHex: String = "#FFFFFF"
    var backgroundColorHex: String = "#6E44FF"

    var backgroundOpacity: Double = 0.92
    var cornerRadius: Double = 14
    var horizontalPadding: Double = 22
    var verticalPadding: Double = 12
    var maxWidth: Double = 760

    var textAlignmentRaw: String = "center"
    var dimOpacity: Double = 0.45

    /// Show the upcoming line underneath, smaller and dimmed.
    var showNextLine: Bool = false
    var nextLineScale: Double = 0.7

    var sweepEnabled: Bool = true
    var shadowEnabled: Bool = true
    /// Opacity of the soft, rounded drop shadow (0 = invisible). The shadow
    /// itself always follows the pill's corner radius on all four sides; this
    /// knob only controls how strong it is.
    var shadowIntensity: Double = 0.30

    /// Blur radius of the pill's soft shadow, shared by the real window and
    /// the settings preview so the two always match. Kept small deliberately:
    /// Core Animation's blur reaches roughly 3× this radius, and a halo wider
    /// than the transparent window margin gets clipped by the window's
    /// *rectangular* edge — that clip is what made the shadow turn square.
    static let shadowBlurRadius: CGFloat = 9
    /// Transparent margin reserved around the pill for that shadow. Must stay
    /// larger than ~3 × `shadowBlurRadius` plus the 1pt offset.
    static let shadowRoom: CGFloat = 30
    var hideOnHover: Bool = false
    var lockPosition: Bool = false
    var clickThrough: Bool = false

    /// `manual` = 用上面的固定配色；`album` = 取 Apple 为专辑算好的配色；
    /// `artwork` = 下载封面图自行提取主色。
    var colorModeRaw: String = "album"
    /// Neutral fallback when neither artwork extraction, Apple's palette, nor
    /// the user's manual colour yields a usable hex.
    static let neutralBackgroundHex = "#3A3A3C"

    /// The two automatic colours are ordered by luminance. This decides which
    /// one becomes the pill and which becomes the lyrics: dark background +
    /// light text by default, flippable from settings.
    var preferDarkBackground: Bool = true
    /// 保真 = show both extracted colours exactly as they are. 易读 = nudge
    /// the lyric colour just enough to clear 3:1 (large text) and keep the
    /// unsung half above 2.5:1. Manual colours are never recoloured in either
    /// mode.
    var colourFidelityFirst: Bool = false
    /// Retired: the old "darken very light covers" switch altered the
    /// background itself and made the pill disagree with the artwork. Kept in
    /// the coding keys so older saved preferences still decode cleanly.
    var autoDarkenLightBackgrounds: Bool = true

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, fontWeightRaw
        case textColorHex, highlightColorHex, backgroundColorHex
        case backgroundOpacity, cornerRadius, horizontalPadding, verticalPadding, maxWidth
        case textAlignmentRaw, dimOpacity
        case showNextLine, nextLineScale
        case sweepEnabled, shadowEnabled, shadowIntensity, hideOnHover, lockPosition, clickThrough
        case colorModeRaw, autoDarkenLightBackgrounds
        case preferDarkBackground, colourFidelityFirst
    }

    /// Declaring `init(from:)` suppresses the synthesised memberwise
    /// initialiser, so keep an explicit zero-argument one for defaults/presets.
    init() {}

    /// Read settings key by key. The synthesised decoder throws if *any* key
    /// is missing — which means a build that adds one new option would make
    /// `AppState` fall back to **all** defaults, silently reverting the user's
    /// font, colours and colour mode on the next launch. Per-key decoding keeps
    /// older saved data readable and defaults only the genuinely new keys.
    init(from decoder: Decoder) throws {
        var a = LyricAppearance()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ into: inout T) {
            if let v = try? c.decode(T.self, forKey: key) { into = v }
        }
        read(.fontName, &a.fontName)
        read(.fontSize, &a.fontSize)
        read(.fontWeightRaw, &a.fontWeightRaw)
        read(.textColorHex, &a.textColorHex)
        read(.highlightColorHex, &a.highlightColorHex)
        read(.backgroundColorHex, &a.backgroundColorHex)
        read(.backgroundOpacity, &a.backgroundOpacity)
        read(.cornerRadius, &a.cornerRadius)
        read(.horizontalPadding, &a.horizontalPadding)
        read(.verticalPadding, &a.verticalPadding)
        read(.maxWidth, &a.maxWidth)
        read(.textAlignmentRaw, &a.textAlignmentRaw)
        read(.dimOpacity, &a.dimOpacity)
        read(.showNextLine, &a.showNextLine)
        read(.nextLineScale, &a.nextLineScale)
        read(.sweepEnabled, &a.sweepEnabled)
        read(.shadowEnabled, &a.shadowEnabled)
        read(.shadowIntensity, &a.shadowIntensity)
        read(.hideOnHover, &a.hideOnHover)
        read(.lockPosition, &a.lockPosition)
        read(.clickThrough, &a.clickThrough)
        read(.colorModeRaw, &a.colorModeRaw)
        read(.autoDarkenLightBackgrounds, &a.autoDarkenLightBackgrounds)
        read(.preferDarkBackground, &a.preferDarkBackground)
        read(.colourFidelityFirst, &a.colourFidelityFirst)
        self = a
    }

    // MARK: - Derived

    var textColor: Color { Color(hex: textColorHex) ?? .white }
    var highlightColor: Color { Color(hex: highlightColorHex) ?? .white }
    var backgroundColor: Color { (Color(hex: backgroundColorHex) ?? .purple).opacity(backgroundOpacity) }

    var fontWeight: Font.Weight {
        switch fontWeightRaw {
        case "ultraLight": return .ultraLight
        case "thin": return .thin
        case "light": return .light
        case "regular": return .regular
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        case "black": return .black
        default: return .bold
        }
    }

    var frameAlignment: Alignment {
        switch textAlignmentRaw {
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }

    var horizontalAlignment: HorizontalAlignment {
        switch textAlignmentRaw {
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }

    var swiftTextAlignment: SwiftUI.TextAlignment {
        switch textAlignmentRaw {
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }

    func font(size: Double = 0) -> Font {
        let s = size > 0 ? size : fontSize
        if fontName.isEmpty {
            return .system(size: s, weight: fontWeight, design: .rounded)
        }
        return .custom(fontName, size: s).weight(fontWeight)
    }

    // MARK: - Auto colour

    /// WCAG 2.1 AA large-text floor (3:1) for the sung half, with a slightly
    /// lower floor for the dimmed half so the sweep survives (22pt bold).
    static let minimumTextContrast = ColorContrast.minimumTextContrast
    static let minimumDimContrast = ColorContrast.minimumDimContrast

    /// The contract for automatic colouring (revised Nov 6):
    ///
    /// 1. **Both colours come from the chosen source** — two clusters from
    ///    the cover, or Apple's `bgColor` / `textColor1` pair. `AppState`
    ///    orders them dark → light and assigns background / lyrics.
    /// 2. **The background is verbatim.** It is never darkened or lightened:
    ///    that was why the pill looked nothing like the artwork. The old
    ///    `autoDarkenLightBackgrounds` switch is retired.
    /// 3. **易读** nudges only the lyric colour toward black or white —
    ///    whichever needs the smaller change to reach 3:1 — and keeps the
    ///    unsung half above 2.5:1. **保真** shows both colours untouched.
    /// 4. Manual mode — and the wait for a colour to arrive — keeps the
    ///    user's own pair exactly as chosen.
    func effective(backgroundHex: String?, textHex: String?) -> LyricAppearance {
        let autoBackground = colorModeRaw != "manual"
            ? Color(hex: backgroundHex ?? "") : nil
        var copy = self

        let background: Color
        let foreground: Color
        if let autoBackground {
            background = autoBackground
            copy.backgroundColorHex = background.hexString
            // A missing second colour only happens while a source is still
            // loading; black/white is the last resort, not the default.
            foreground = Color(hex: textHex ?? "")
                ?? Color.bestTextColor(on: background)
        } else {
            background = Color(hex: backgroundColorHex)
                ?? Color(red: 0.23, green: 0.23, blue: 0.24)
            foreground = Color(hex: textColorHex) ?? .white
        }

        if colourFidelityFirst {
            copy.textColorHex = foreground.hexString
            copy.highlightColorHex = foreground.hexString
            return copy
        }

        // Manual colours are the user's own decision: never recolour them.
        let readable = autoBackground != nil
            ? Color.readableTextColor(foreground, on: background)
            : foreground
        copy.textColorHex = readable.hexString
        copy.highlightColorHex = readable.hexString
        let floor = Color.readableDimOpacity(fg: readable, on: background,
                                             minimumContrast: Self.minimumDimContrast)
        copy.dimOpacity = min(1, max(dimOpacity, floor))
        return copy
    }
}

// MARK: - Contrast bridge
//
// The arithmetic lives in ColorContrast.swift (UI-free, unit-testable). These
// helpers only convert SwiftUI colours to/from its sRGB components.

extension Color {
    private var contrastRGB: ColorContrast.RGB {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor.gray
        return ColorContrast.RGB(r: ns.redComponent,
                                 g: ns.greenComponent,
                                 b: ns.blueComponent)
    }

    var wcagLuminance: Double { ColorContrast.luminance(contrastRGB) }

    static func contrast(_ a: Color, _ b: Color) -> Double {
        ColorContrast.contrast(a.contrastRGB, b.contrastRGB)
    }

    static func bestTextColor(on background: Color) -> Color {
        let c = ColorContrast.bestText(on: background.contrastRGB)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// 易读 mode: keep the cover's second colour, just make it legible.
    static func readableTextColor(_ candidate: Color, on background: Color) -> Color {
        let c = ColorContrast.adjustedForContrast(candidate.contrastRGB,
                                                  on: background.contrastRGB)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    static func readableDimOpacity(fg: Color, on background: Color,
                                   minimumContrast: Double) -> Double {
        ColorContrast.readableDim(fg: fg.contrastRGB,
                                  on: background.contrastRGB,
                                  minimumContrast: minimumContrast)
    }
}

// MARK: - Presets

extension LyricAppearance {
    /// Eight two-colour contrast pairs supplied by the user (Nov 3). Each
    /// entry is a background + lyric colour that can be flipped with the
    /// "交换背景色与歌词颜色" button — the pairing matters, not a fixed
    /// foreground/background assignment.
    static let presets: [(name: String, appearance: LyricAppearance)] = {
        func pair(_ name: String, _ bg: String, _ fg: String) -> (String, LyricAppearance) {
            var a = LyricAppearance()
            a.backgroundColorHex = bg
            a.textColorHex = fg
            a.highlightColorHex = fg
            return (name, a)
        }
        return [
            pair("浆果红 × 湖蓝色", "#65020A", "#18D5E7"),
            pair("胭脂粉 × 墨黑色", "#FF7CA2", "#000000"),
            pair("雾堇紫 × 樱粉色", "#615EDE", "#FF7EC1"),
            pair("长春花蓝 × 可可棕", "#7B8AD7", "#6D483B"),
            pair("裸桃粉 × 苔青色", "#FACBC6", "#465C47"),
            pair("桃绯粉 × 薄荷青", "#F35B83", "#8AEED1"),
            pair("浅松色 × 艾草青", "#FFC44F", "#5ECD8C"),
            pair("柿橙色 × 密金色", "#B85516", "#EAAE35")
        ]
    }()
}

// MARK: - Hex colour helpers

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "#", with: "")
        guard s.count == 6 || s.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }
        let r, g, b: Double
        if s.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        }
        self = Color(red: r, green: g, blue: b)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor.white
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
