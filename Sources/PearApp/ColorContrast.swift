import Foundation

/// WCAG 2.1 contrast arithmetic on sRGB components.
///
/// Deliberately free of SwiftUI / AppKit so `tools/verify_contrast.swift` can
/// compile and assert the exact rules the floating window uses — no UI
/// framework, and no SwiftUIMacros plugin, in the loop.
///
/// The rules themselves (see also `LyricAppearance.effective`):
/// 1. The cover / Apple background colour is used verbatim.
/// 2. In 易读 mode the cover's own second colour is nudged *just enough* to
///    clear 3:1 (WCAG AA large text — lyrics are 22pt bold), toward whichever
///    of black / white needs the smaller change. Holding the 4.5:1 body-text
///    floor here made pure white fail on mid-tone covers and forced every
///    lyric colour to near-black, erasing the second cover colour.
/// 3. The not-yet-sung half may be dimmed, but not below a readable floor.
///    It sits slightly under 3:1 so a sung colour that *just* clears 3:1
///    still leaves room for the karaoke sweep instead of pinning opacity to
///    100%.
/// 4. 保真 mode skips steps 2–3 entirely: both extracted colours are shown
///    exactly as they appear on the cover.
enum ColorContrast {
    struct RGB: Equatable {
        let r, g, b: Double
        static let white = RGB(r: 1, g: 1, b: 1)
        static let black = RGB(r: 0, g: 0, b: 0)
    }

    /// WCAG 2.1 AA for **large** text — the sung (highlight) half. Lyrics
    /// render at 22pt bold, above the 14pt-bold / 18pt threshold. The old
    /// 4.5:1 body-text floor was wrong here and turned cover colours black.
    static let minimumTextContrast = 3.0
    /// Floor for the dimmed, unsung half. Slightly below the sung floor on
    /// purpose: when the sung colour only just clears 3:1, demanding 3:1 for
    /// the dimmed half too would force `dimOpacity` to 1 and remove the sweep.
    static let minimumDimContrast = 2.5

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
    /// Both extremes are solved and the **smaller colour change** wins. Only
    /// following `bestText` used to drag every unreadable swatch toward the
    /// single highest-contrast extreme: on a mid-tone red cover that made all
    /// lyric colours near-black, even though a touch of white was closer.
    static func adjustedForContrast(_ fg: RGB, on background: RGB,
                                    minimumContrast: Double = minimumTextContrast) -> RGB {
        guard contrast(fg, background) < minimumContrast else { return fg }
        let preferred = bestText(on: background)
        let alternate: RGB = preferred == .black ? .white : .black

        func solve(toward: RGB) -> (colour: RGB, distance: Double)? {
            func mixed(_ t: Double) -> RGB {
                RGB(r: fg.r * (1 - t) + toward.r * t,
                    g: fg.g * (1 - t) + toward.g * t,
                    b: fg.b * (1 - t) + toward.b * t)
            }
            guard contrast(toward, background) >= minimumContrast else { return nil }
            var lo = 0.0, hi = 1.0
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if contrast(mixed(mid), background) >= minimumContrast {
                    hi = mid
                } else {
                    lo = mid
                }
            }
            let result = mixed(hi)
            let dr = result.r - fg.r, dg = result.g - fg.g, db = result.b - fg.b
            return (result, 0.30 * dr * dr + 0.59 * dg * dg + 0.11 * db * db)
        }

        let a = solve(toward: preferred)
        let b = solve(toward: alternate)
        if let a, let b { return a.distance <= b.distance ? a.colour : b.colour }
        return a?.colour ?? b?.colour ?? preferred
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
