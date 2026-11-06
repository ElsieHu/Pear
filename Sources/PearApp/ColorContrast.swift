import Foundation

/// WCAG 2.1 contrast arithmetic on sRGB components.
///
/// Deliberately free of SwiftUI / AppKit so `tools/verify_contrast.swift` can
/// compile and assert the exact rules the floating window uses — no UI
/// framework, and no SwiftUIMacros plugin, in the loop.
///
/// The rules themselves (see also `LyricAppearance.effective`):
/// 1. The cover / Apple background colour is used verbatim.
/// 2. In 易读 mode the cover's own second colour is nudged toward the
///    readable extreme *just enough* to clear 4.5:1, keeping its hue. Pure
///    black / white is only the last resort when a cover has no second colour.
/// 3. The not-yet-sung half may be dimmed, but never below the WCAG AA
///    large-text floor. Lyrics render at 22pt bold, well above the 14pt bold
///    large-text threshold. Holding the *body* 4.5:1 floor here would force
///    85–95% opacity on mid-tone covers and erase the karaoke sweep.
/// 4. 保真 mode skips steps 2–3 entirely: both extracted colours are shown
///    exactly as they appear on the cover.
enum ColorContrast {
    struct RGB: Equatable {
        let r, g, b: Double
        static let white = RGB(r: 1, g: 1, b: 1)
        static let black = RGB(r: 0, g: 0, b: 0)
    }

    /// WCAG 2.1 AA for body text — required for the sung (highlight) half.
    static let minimumTextContrast = 4.5
    /// WCAG 2.1 AA for large text — the floor for the dimmed, unsung half.
    static let minimumDimContrast = 3.0

    /// Relative luminance with the sRGB transfer function removed. Using raw
    /// sRGB channels (the old 0.55 brightness cutoff) badly overestimates
    /// mid-tones and picks the wrong lyric colour.
    static func luminance(_ c: RGB) -> Double {
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Black and white are complementary on the luminance curve: the winner
    /// always clears `minimumTextContrast` on any opaque sRGB background.
    static func bestText(on background: RGB) -> RGB {
        contrast(.white, background) >= contrast(.black, background) ? .white : .black
    }

    /// Keep a cover colour's character while making it readable.
    ///
    /// Replacing an unreadable swatch with pure black / white is what made
    /// every automatic palette look monochrome. Instead, move it toward the
    /// extremity that improves contrast on this background (black on a light
    /// cover, white on a dark one) and stop at the *smallest* amount that
    /// reaches `minimumContrast`. Hue and relative saturation survive.
    static func adjustedForContrast(_ fg: RGB, on background: RGB,
                                    minimumContrast: Double = minimumTextContrast) -> RGB {
        guard contrast(fg, background) < minimumContrast else { return fg }
        let toward = bestText(on: background)
        func mixed(_ t: Double) -> RGB {
            RGB(r: fg.r * (1 - t) + toward.r * t,
                g: fg.g * (1 - t) + toward.g * t,
                b: fg.b * (1 - t) + toward.b * t)
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if contrast(mixed(mid), background) >= minimumContrast {
                hi = mid
            } else {
                lo = mid
            }
        }
        return mixed(hi)
    }

    /// Smallest alpha at which `fg` composited over `background` still clears
    /// `minimumContrast`. Opacity blends in component space, so interpolate
    /// the sRGB channels before measuring. Returns 1 when even the
    /// full-opacity foreground cannot reach the target: in that case the
    /// caller keeps the supplied colour instead of dimming it further.
    static func readableDim(fg: RGB, on background: RGB,
                            minimumContrast: Double = minimumDimContrast) -> Double {
        func blended(_ a: Double) -> RGB {
            RGB(r: background.r * (1 - a) + fg.r * a,
                g: background.g * (1 - a) + fg.g * a,
                b: background.b * (1 - a) + fg.b * a)
        }
        guard contrast(blended(1), background) >= minimumContrast else { return 1 }
        var lo = 0.0, hi = 1.0
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if contrast(blended(mid), background) >= minimumContrast {
                hi = mid
            } else {
                lo = mid
            }
        }
        return hi
    }
}
