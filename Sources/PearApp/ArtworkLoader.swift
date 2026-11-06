import AppKit
import SwiftUI
import ImageIO
import CoreGraphics

/// Downloads album artwork from Apple's CDN and extracts a dominant colour.
///
/// The returned hex is the cover's colour **verbatim**. Readability is handled
/// downstream by `LyricAppearance.effective()` (text colour + a contrast-based
/// dim floor), not by changing the background here — an earlier version
/// silently darkened light covers and brightened dark ones, which made the
/// pill look nothing like the artwork and ignored the "auto darken" switch.
///
/// Failure is a first-class outcome: no URL, HTTP error, undecodable bytes,
/// and flat / monochrome covers leave `dominantHex` nil but log the reason and
/// clear the "already requested" marker so the same track can be retried.
@MainActor
final class ArtworkLoader: ObservableObject {
    static let shared = ArtworkLoader()

    @Published private(set) var image: NSImage?
    @Published private(set) var dominantHex: String?
    /// Last failure reason, surfaced in diagnostics.
    @Published private(set) var lastFailure: String?

    private let memoryCache = NSCache<NSString, NSImage>()
    private var loadedURL: String?
    private var lastURL: URL?
    /// True from the first attempt until success or the last retry gives up.
    /// The colour retry loop calls `load(url:)` repeatedly; without this flag
    /// each of those calls would cancel a retry already in flight.
    private var downloadInFlight = false
    /// A transient network error is worth retrying on its own schedule; a
    /// cover that decodes but yields no dominant colour is not (retrying the
    /// same bytes cannot produce a different answer).
    private static let maxAttempts = 4
    private static let retryDelays: [TimeInterval] = [1, 2, 4]
    /// Bumped on every new request. A download for the *previous* song can
    /// finish after the track has already changed; without this check it
    /// writes the old cover's colour over the new one.
    private var loadGeneration = 0

    private init() {
        memoryCache.countLimit = 40
    }

    func load(url: URL?) {
        guard let url else {
            // Invalidate anything still in flight for the previous track.
            loadGeneration += 1
            downloadInFlight = false
            image = nil
            dominantHex = nil
            loadedURL = nil
            lastURL = nil
            lastFailure = nil
            return
        }
        let key = url.absoluteString
        let previousURL = lastURL?.absoluteString
        lastURL = url
        guard loadedURL != key else { return }
        // A retry is already running for *this* cover — don't cancel it. But
        // a different URL means a new track: go ahead and invalidate the old
        // request, otherwise the previous cover's colour lands on this song.
        if downloadInFlight, previousURL == key { return }
        loadedURL = key
        // Only invalidate older requests when we actually start a new one —
        // a repeated load() for the same URL must not cancel its own download.
        loadGeneration += 1
        startDownload(url: url, generation: loadGeneration, attempt: 0)
    }

    private func startDownload(url: URL, generation: Int, attempt: Int) {
        let key = url.absoluteString
        if attempt == 0, let cached = memoryCache.object(forKey: key as NSString) {
            image = cached
            let hex = Self.dominantHex(from: cached)
            dominantHex = hex
            lastFailure = hex == nil ? "缓存封面取色失败" : nil
            if hex == nil { AppLog.warn("封面取色失败(缓存图): \(url.lastPathComponent)") }
            return
        }

        image = nil
        dominantHex = nil
        lastFailure = nil
        downloadInFlight = true
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad,
                                 timeoutInterval: 12)
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 0 || (200...299).contains(status) else {
                    throw NSError(domain: "Pear.Artwork", code: status,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
                }
                guard let img = Self.decodeImage(data) else {
                    throw NSError(domain: "Pear.Artwork", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "图片解码失败 (\(data.count) 字节, 可能是不支持的格式或非图片响应)"])
                }
                let hex = Self.dominantHex(from: img)
                guard let self, self.loadGeneration == generation else { return }
                self.downloadInFlight = false
                // The bytes are good whether or not a dominant colour could
                // be extracted; pin the URL so the retry loop stops re-fetching
                // this cover and Apple's palette can take over instead.
                self.loadedURL = key
                self.memoryCache.setObject(img, forKey: key as NSString)
                self.image = img
                self.dominantHex = hex
                self.lastFailure = hex == nil ? "主色提取返回空" : nil
                AppLog.info("封面已加载 \(data.count) 字节 HTTP \(status) 主色=\(hex ?? "-")")
                if hex == nil {
                    AppLog.warn("封面取色失败: \(url.lastPathComponent) → 交给配色兜底链")
                }
            } catch {
                guard let self, self.loadGeneration == generation else { return }
                // Clear the "already requested" marker so the colour retry
                // loop can start a fresh download for this same cover.
                self.loadedURL = nil
                self.lastFailure = error.localizedDescription
                AppLog.warn("封面失败(第 \(attempt + 1) 次): \(error.localizedDescription) url=\(url.lastPathComponent)")
                guard attempt + 1 < Self.maxAttempts else {
                    self.downloadInFlight = false
                    return
                }
                let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard self.loadGeneration == generation else { return }
                self.startDownload(url: url, generation: generation, attempt: attempt + 1)
            }
        }
    }

    // MARK: - Decoding

    private static func decodeImage(_ data: Data) -> NSImage? {
        if let img = NSImage(data: data) { return img }
        // HEIC / bytes with a prologue sometimes defeat NSImage but ImageIO
        // can still decode them.
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        // Vector / PDF-backed representations have no direct cgImage; rebuild
        // one from the TIFF representation.
        guard let tiff = image.tiffRepresentation,
              let src = CGImageSourceCreateWithData(tiff as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return cg
    }

    // MARK: - Dominant colour

    static func dominantHex(from image: NSImage) -> String? {
        guard let cg = cgImage(from: image) else { return nil }
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

        // Pass 1 ignores near-black / near-white pixels to find a
        // "characteristic" colour. Flat monochrome, pure black, pure white or
        // very dark / very bright covers can filter out *every* pixel though,
        // so pass 2 relaxes the luminance gate and only skips transparency.
        return pick(raw, side, strict: true) ?? pick(raw, side, strict: false)
    }

    private static func pick(_ raw: [UInt8], _ side: Int, strict: Bool) -> String? {
        var buckets: [Int: (count: Int, r: Int, g: Int, b: Int, sat: Double)] = [:]
        for i in 0..<(side * side) {
            let o = i * 4
            let r = Int(raw[o]), g = Int(raw[o + 1]), b = Int(raw[o + 2]), a = Int(raw[o + 3])
            guard a > 200 else { continue }
            let maxC = max(r, g, b), minC = min(r, g, b)
            let lum = (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255.0
            if strict, !(lum > 0.06 && lum < 0.93) { continue }
            let sat = maxC == 0 ? 0 : Double(maxC - minC) / Double(maxC)
            let key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
            var entry = buckets[key] ?? (0, 0, 0, 0, 0)
            entry.count += 1
            entry.r += r; entry.g += g; entry.b += b
            entry.sat = max(entry.sat, sat)
            buckets[key] = entry
        }
        // Area first, saturation second. The old (0.4 + sat) weight let a
        // small vivid patch beat the colour covering most of the cover, so
        // the pill could disagree with the artwork the eye actually sees.
        guard let best = buckets.values.max(by: { lhs, rhs in
            (Double(lhs.count) * (0.7 + 0.3 * lhs.sat)) < (Double(rhs.count) * (0.7 + 0.3 * rhs.sat))
        }), best.count > 0 else { return nil }
        let r = best.r / best.count, g = best.g / best.count, b = best.b / best.count
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
