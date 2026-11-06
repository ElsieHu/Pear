import Foundation

/// Extracts **two** colours from an album cover.
///
/// Pure arithmetic over sRGB samples — no AppKit / SwiftUI — so
/// `tools/verify_palette.swift` can compile this alongside `ColorContrast.swift`
/// and assert the exact rules the floating window uses.
///
/// The old extractor returned a single "dominant" bucket, which forced the
/// lyric colour to be pure black or pure white. Here the cover is clustered,
/// the largest cluster is the visual main colour, and a second cluster is
/// chosen for being *both* different in hue and readable against it. The two
/// are then ordered by WCAG luminance; `AppState` decides which one is the
/// background (dark by default) and which one is the lyric colour.
enum ColorPalette {

    struct Swatch {
        var colour: ColorContrast.RGB
        var count: Int
    }

    struct Pair {
        /// Darker of the two colours (WCAG relative luminance).
        var dark: ColorContrast.RGB
        /// Lighter of the two colours.
        var light: ColorContrast.RGB
        /// Largest cluster — the colour the eye reads as "the cover".
        var primary: ColorContrast.RGB
        /// False when the cover was effectively single-colour and the second
        /// swatch had to be generated from black / white instead.
        var hasSecondColour: Bool

        var darkHex: String { dark.hexString }
        var lightHex: String { light.hexString }
        var primaryHex: String { primary.hexString }
    }

    // MARK: - Extraction

    /// `pixels` should already exclude transparent / near-transparent samples.
    static func extract(from pixels: [ColorContrast.RGB],
                        clusters: Int = 6, iterations: Int = 12) -> Pair? {
        guard !pixels.isEmpty else { return nil }
        let k = max(2, min(clusters, pixels.count))

        // Deterministic seeds: quantiles of the luminance-sorted pixels.
        // Random k-means seeds made the same cover resolve to slightly
        // different colours between runs, which looked like a flicker.
        let sorted = pixels.sorted {
            ColorContrast.luminance($0) < ColorContrast.luminance($1)
        }
        var centres: [ColorContrast.RGB] = (0..<k).map { i in
            sorted[(i * (sorted.count - 1)) / max(1, k - 1)]
        }

        var assignment = [Int](repeating: -1, count: pixels.count)
        for _ in 0..<iterations {
            var sums = [(r: Double, g: Double, b: Double, count: Int)](
                repeating: (0, 0, 0, 0), count: k)
            var changed = false
            for (i, p) in pixels.enumerated() {
                var best = 0
                var bestDistance = Double.infinity
                for (j, c) in centres.enumerated() {
                    let d = distanceSquared(p, c)
                    if d < bestDistance { bestDistance = d; best = j }
                }
                if assignment[i] != best { assignment[i] = best; changed = true }
                sums[best].r += p.r
                sums[best].g += p.g
                sums[best].b += p.b
                sums[best].count += 1
            }
            for j in 0..<k where sums[j].count > 0 {
                let n = Double(sums[j].count)
                centres[j] = ColorContrast.RGB(r: sums[j].r / n,
                                               g: sums[j].g / n,
                                               b: sums[j].b / n)
            }
            if !changed { break }
        }

        let swatches: [Swatch] = (0..<k).compactMap { j in
            var count = 0
            for a in assignment where a == j { count += 1 }
            guard count > 0 else { return nil }
            return Swatch(colour: centres[j], count: count)
        }.sorted { $0.count > $1.count }

        guard let primary = swatches.first?.colour else { return nil }
        let total = Double(pixels.count)
        let others = Array(swatches.dropFirst())

        let second: ColorContrast.RGB
        let hasSecond: Bool
        if others.isEmpty {
            // A genuinely single-colour cover has nothing to pair with.
            second = ColorContrast.bestText(on: primary)
            hasSecond = false
        } else {
            // Prefer a cluster that is already readable; among those, pick by
            // hue difference + area. If none clears the bar, take the highest
            // contrast available — the readable mode will nudge it later.
            let readable = others.filter {
                ColorContrast.contrast($0.colour, primary) >= ColorContrast.minimumTextContrast
            }
            if let best = readable.max(by: {
                score($0, total: total, against: primary) < score($1, total: total, against: primary)
            }) {
                second = best.colour
            } else if let best = others.max(by: {
                ColorContrast.contrast($0.colour, primary) < ColorContrast.contrast($1.colour, primary)
            }) {
                second = best.colour
            } else {
                second = ColorContrast.bestText(on: primary)
            }
            hasSecond = true
        }

        let darkFirst = ColorContrast.luminance(primary) <= ColorContrast.luminance(second)
        return Pair(dark: darkFirst ? primary : second,
                    light: darkFirst ? second : primary,
                    primary: primary,
                    hasSecondColour: hasSecond)
    }

    private static func score(_ s: Swatch, total: Double,
                              against primary: ColorContrast.RGB) -> Double {
        let contrast = min(ColorContrast.contrast(s.colour, primary), 12) / 12
        let area = Double(s.count) / total
        return contrast * 1.6 + hueDistance(s.colour, primary) * 1.2 + area * 1.4
    }

    /// Luminance-weighted sRGB distance. Grouping in gamma-encoded space is
    /// close enough for 48×48 artwork and keeps the whole module dependency-free.
    private static func distanceSquared(_ a: ColorContrast.RGB,
                                        _ b: ColorContrast.RGB) -> Double {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return 0.30 * dr * dr + 0.59 * dg * dg + 0.11 * db * db
    }

    /// Circular hue difference in 0…1; achromatic colours count as zero so a
    /// grey highlight does not win over a genuinely different colour.
    static func hueDistance(_ a: ColorContrast.RGB, _ b: ColorContrast.RGB) -> Double {
        let ha = hue(a), hb = hue(b)
        guard ha.saturation > 0.12, hb.saturation > 0.12 else { return 0 }
        let d = abs(ha.value - hb.value)
        return min(d, 1 - d) * 2
    }

    private static func hue(_ c: ColorContrast.RGB) -> (value: Double, saturation: Double) {
        let maximum = max(c.r, c.g, c.b)
        let minimum = min(c.r, c.g, c.b)
        let delta = maximum - minimum
        guard delta > 1e-6, maximum > 0 else { return (0, 0) }
        var h: Double
        if maximum == c.r {
            h = (c.g - c.b) / delta
        } else if maximum == c.g {
            h = (c.b - c.r) / delta + 2
        } else {
            h = (c.r - c.g) / delta + 4
        }
        h /= 6
        if h < 0 { h += 1 }
        return (h, delta / maximum)
    }
}

extension ColorContrast.RGB {
    var hexString: String {
        String(format: "#%02X%02X%02X",
               Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}
