import Foundation
import CoreGraphics
import AppKit

// 生成 Pear 的 App 图标：
// 圆角渐变方块 + 三行"歌词条"，中间一条带左→右点亮效果。
// 用法: swiftc make_icon.swift -o make_icon && ./make_icon <输出 .iconset 目录>

let sizes: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2)
]

func drawIcon(pixelSize: Int) -> CGImage? {
    let w = pixelSize, h = pixelSize
    guard let ctx = CGContext(data: nil,
                              width: w,
                              height: h,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    let rect = CGRect(x: 0, y: 0, width: w, height: h)

    // --- 渐变背景 ---
    let top = CGColor(red: 0.63, green: 0.42, blue: 1.0, alpha: 1)      // #A06BFF
    let bottom = CGColor(red: 0.36, green: 0.17, blue: 0.88, alpha: 1)  // #5B2BE0
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [top, bottom] as CFArray,
                              locations: [0, 1])!

    let radius = CGFloat(w) * 0.2237   // macOS Big Sur 圆角比例
    let path = CGPath(roundedRect: rect.insetBy(dx: 0, dy: 0),
                      cornerWidth: radius,
                      cornerHeight: radius,
                      transform: nil)
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: CGFloat(h)),
                           end: CGPoint(x: 0, y: 0),
                           options: [])

    // --- 歌词条 ---
    let innerW = CGFloat(w) * 0.62
    let barH = max(CGFloat(w) * 0.075, 1)
    let gap = barH * 1.55
    let totalH = barH * 3 + gap * 2
    var y = (CGFloat(h) - totalH) / 2
    let cx = CGFloat(w) / 2

    let widths: [CGFloat] = [0.62, 0.86, 0.48]
    for (i, ratio) in widths.enumerated() {
        let bw = innerW * ratio
        let bar = CGRect(x: cx - bw / 2, y: y, width: bw, height: barH)
        let barPath = CGPath(roundedRect: bar,
                             cornerWidth: barH / 2,
                             cornerHeight: barH / 2,
                             transform: nil)

        if i == 1 {
            // 中间一行：左侧已"唱到"(不透明)，右侧未唱(半透明)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.38))
            ctx.addPath(barPath)
            ctx.fillPath()

            ctx.saveGState()
            let lit = CGRect(x: bar.minX, y: bar.minY, width: bar.width * 0.52, height: barH)
            let litPath = CGPath(roundedRect: lit, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil)
            ctx.addPath(litPath)
            ctx.clip()
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(lit)
            ctx.restoreGState()
        } else {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: i == 0 ? 0.55 : 0.38))
            ctx.addPath(barPath)
            ctx.fillPath()
        }
        y += barH + gap
    }

    return ctx.makeImage()
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法: make_icon <iconset 目录>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for (points, scale) in sizes {
    let pixels = points * scale
    guard let cg = drawIcon(pixelSize: pixels) else { continue }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    let name = scale == 1 ? "icon_\(points)x\(points).png"
                          : "icon_\(points)x\(points)@2x.png"
    try? data.write(to: outDir.appendingPathComponent(name))
}
print("iconset 已生成: \(outDir.path)")
