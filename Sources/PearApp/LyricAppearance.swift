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
    var hideOnHover: Bool = false
    var lockPosition: Bool = false
    var clickThrough: Bool = false

    /// `manual` = 用上面的固定配色；`album` = 取 Apple 为专辑算好的配色；
    /// `artwork` = 下载封面图自行提取主色。
    var colorModeRaw: String = "album"
    /// Neutral fallback when neither artwork extraction, Apple's palette, nor
    /// the user's manual colour yields a usable hex.
    static let neutralBackgroundHex = "#3A3A3C"
    /// 封面原色太亮时自动压暗，保证白字可读。
    var autoDarkenLightBackgrounds: Bool = true

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, fontWeightRaw
        case textColorHex, highlightColorHex, backgroundColorHex
        case backgroundOpacity, cornerRadius, horizontalPadding, verticalPadding, maxWidth
        case textAlignmentRaw, dimOpacity
        case showNextLine, nextLineScale
        case sweepEnabled, shadowEnabled, hideOnHover, lockPosition, clickThrough
        case colorModeRaw, autoDarkenLightBackgrounds
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
        read(.hideOnHover, &a.hideOnHover)
        read(.lockPosition, &a.lockPosition)
        read(.clickThrough, &a.clickThrough)
        read(.colorModeRaw, &a.colorModeRaw)
        read(.autoDarkenLightBackgrounds, &a.autoDarkenLightBackgrounds)
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

    /// Produce the appearance actually used for rendering: when automatic
    /// colour is on, override background / text / highlight with the album's
    /// own palette, keeping a legibility floor.
    func effective(backgroundHex: String?, textHex: String?) -> LyricAppearance {
        guard colorModeRaw != "manual" else { return self }
        guard let bg = Color(hex: backgroundHex ?? "") else { return self }

        var copy = self
        var background = bg
        var foreground = Color(hex: textHex ?? "") ?? Self.legibleText(on: bg)

        if autoDarkenLightBackgrounds {
            let lum = Self.luminance(of: background)
            if lum > 0.72 {
                // Blend towards black so the text never washes out.
                background = background.blended(with: .black, fraction: min(0.45, (lum - 0.72) * 1.8))
                if Color(hex: textHex ?? "") == nil {
                    foreground = Self.legibleText(on: background)
                }
            } else if lum < 0.10 {
                background = background.blended(with: .white, fraction: 0.12)
                foreground = Self.legibleText(on: background)
            }
        }

        copy.backgroundColorHex = background.hexString
        copy.textColorHex = foreground.hexString
        copy.highlightColorHex = foreground.hexString
        return copy
    }

    private static func legibleText(on background: Color) -> Color {
        luminance(of: background) > 0.55 ? .black : .white
    }

    private static func luminance(of color: Color) -> Double {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor.black
        return 0.2126 * ns.redComponent + 0.7152 * ns.greenComponent + 0.0722 * ns.blueComponent
    }
}

extension Color {
    func blended(with other: Color, fraction: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor.black
        let b = NSColor(other).usingColorSpace(.deviceRGB) ?? NSColor.black
        let f = min(max(fraction, 0), 1)
        return Color(
            red: a.redComponent * (1 - f) + b.redComponent * f,
            green: a.greenComponent * (1 - f) + b.greenComponent * f,
            blue: a.blueComponent * (1 - f) + b.blueComponent * f
        )
    }
}

// MARK: - Presets

extension LyricAppearance {
    static let presets: [(name: String, appearance: LyricAppearance)] = {
        func make(_ name: String, bg: String, fg: String = "#FFFFFF", hi: String? = nil) -> (String, LyricAppearance) {
            var a = LyricAppearance()
            a.backgroundColorHex = bg
            a.textColorHex = fg
            a.highlightColorHex = hi ?? fg
            return (name, a)
        }
        return [
            make("霓虹紫", bg: "#6E44FF"),
            make("莓果粉", bg: "#E0407F"),
            make("深海蓝", bg: "#1E5AFF"),
            make("薄荷青", bg: "#12A594"),
            make("曜石黑", bg: "#101014"),
            make("云雾白", bg: "#FFFFFF", fg: "#1C1C1E"),
            make("落日橙", bg: "#F0642F"),
            make("森野绿", bg: "#2E9E5B")
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
