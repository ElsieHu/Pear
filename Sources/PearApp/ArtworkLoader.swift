import AppKit
import SwiftUI
import ImageIO
import CoreGraphics

/// Downloads album artwork from Apple's CDN and extracts **two** colours.
///
/// The pair is the cover's colours **verbatim**: a largest-cluster main colour
/// plus a second cluster chosen for hue difference and contrast. Readability
/// is handled downstream by `LyricAppearance.effective()`, not by changing
/// the background here — an earlier version silently darkened light covers
/// and brightened dark ones, which made the pill look nothing like the art.
///
/// Failure is a first-class outcome: no URL, HTTP error or undecodable bytes
/// leave `palette` nil, log the reason, and clear the "already requested"
/// marker so the same track can be retried. A flat monochrome cover is *not*
/// a failure — it still yields a pair, with a black/white second colour.
@MainActor
final class ArtworkLoader: ObservableObject {
    static let shared = ArtworkLoader()

    @Published private(set) var image: NSImage?
    /// Main colour only, kept for diagnostics and the "waiting" log line.
    @Published private(set) var dominantHex: String?
    /// The two cover colours, already ordered dark → light.
    @Published private(set) var palette: ColorPalette.Pair?
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
            palette = nil
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
            let pair = Self.extractPalette(from: cached)
            palette = pair
            dominantHex = pair?.primaryHex
            lastFailure = pair == nil ? "缓存封面取色失败" : nil
            if pair == nil { AppLog.warn("封面取色失败(缓存图): \(url.lastPathComponent)") }
            return
        }

        image = nil
        dominantHex = nil
        palette = nil
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
                let pair = Self.extractPalette(from: img)
                guard let self, self.loadGeneration == generation else { return }
                self.downloadInFlight = false
                // The bytes are good whether or not a palette could be
                // extracted; pin the URL so the retry loop stops re-fetching
                // this cover and Apple's palette can take over instead.
                self.loadedURL = key
                self.memoryCache.setObject(img, forKey: key as NSString)
                self.image = img
                self.palette = pair
                self.dominantHex = pair?.primaryHex
                self.lastFailure = pair == nil ? "两色提取返回空" : nil
                AppLog.info("封面已加载 \(data.count) 字节 HTTP \(status) 主色=\(pair?.primaryHex ?? "-") 暗=\(pair?.darkHex ?? "-") 亮=\(pair?.lightHex ?? "-") 双色=\(pair?.hasSecondColour == true)")
                if pair == nil {
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

    // MARK: - Two-colour extraction

    /// Kept for diagnostics and the "waiting for cover" log line.
    static func dominantHex(from image: NSImage) -> String? {
        extractPalette(from: image)?.primaryHex
    }

    static func extractPalette(from image: NSImage) -> ColorPalette.Pair? {
        guard let cg = cgImage(from: image) else { return nil }
        let side = 64
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

        // Unlike the old fixed 16-level histogram, clustering keeps a smooth
        // gradient together instead of averaging it into a muddy grey-brown.
        var pixels: [ColorContrast.RGB] = []
        pixels.reserveCapacity(side * side)
        for i in 0..<(side * side) {
            let o = i * 4
            let alpha = Double(raw[o + 3]) / 255
            guard alpha > 0.78 else { continue }
            // CGContext is premultiplied-last; undo the premultiplication so
            // semi-transparent edges do not darken the extracted swatch.
            func channel(_ v: UInt8) -> Double {
                min(1, Double(v) / 255 / alpha)
            }
            pixels.append(ColorContrast.RGB(r: channel(raw[o]),
                                            g: channel(raw[o + 1]),
                                            b: channel(raw[o + 2])))
        }
        return ColorPalette.extract(from: pixels)
    }
}
