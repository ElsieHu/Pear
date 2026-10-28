import AppKit
import SwiftUI

/// Downloads album artwork from Apple's CDN and extracts a dominant colour.
@MainActor
final class ArtworkLoader: ObservableObject {
    static let shared = ArtworkLoader()

    @Published private(set) var image: NSImage?
    @Published private(set) var dominantHex: String?

    private let memoryCache = NSCache<NSString, NSImage>()
    private var loadedURL: String?

    private init() {
        memoryCache.countLimit = 40
    }

    func load(url: URL?) {
        guard let url else {
            image = nil
            dominantHex = nil
            loadedURL = nil
            return
        }
        let key = url.absoluteString
        guard loadedURL != key else { return }
        loadedURL = key

        if let cached = memoryCache.object(forKey: key as NSString) {
            image = cached
            dominantHex = Self.dominantHex(from: cached)
            return
        }

        image = nil
        dominantHex = nil
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = NSImage(data: data) else { return }
            self?.memoryCache.setObject(img, forKey: key as NSString)
            self?.image = img
            self?.dominantHex = Self.dominantHex(from: img)
        }
    }

    // MARK: - Dominant colour

    /// Quantises a 48×48 thumbnail and picks the most "characteristic"
    /// bucket: frequent, saturated, and neither near-white nor near-black.
    static func dominantHex(from image: NSImage) -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 48
        var raw = [UInt8](repeating: 0, count: side * side * 4)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: &raw,
                                  width: side,
                                  height: side,
                                  bitsPerComponent: 8,
                                  bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        var buckets: [Int: (count: Int, r: Int, g: Int, b: Int, sat: Double)] = [:]
        for i in 0..<(side * side) {
            let o = i * 4
            let r = Int(raw[o]), g = Int(raw[o + 1]), b = Int(raw[o + 2]), a = Int(raw[o + 3])
            guard a > 200 else { continue }
            let maxC = max(r, g, b), minC = min(r, g, b)
            let lum = (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255.0
            guard lum > 0.06, lum < 0.93 else { continue }
            let sat = maxC == 0 ? 0 : Double(maxC - minC) / Double(maxC)
            let key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
            var entry = buckets[key] ?? (0, 0, 0, 0, 0)
            entry.count += 1
            entry.r += r; entry.g += g; entry.b += b
            entry.sat = max(entry.sat, sat)
            buckets[key] = entry
        }

        guard let best = buckets.values.max(by: { lhs, rhs in
            (Double(lhs.count) * (0.4 + lhs.sat)) < (Double(rhs.count) * (0.4 + rhs.sat))
        }), best.count > 0 else { return nil }

        let r = best.r / best.count, g = best.g / best.count, b = best.b / best.count
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
