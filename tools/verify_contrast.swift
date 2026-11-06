import Foundation

// 与 Sources/PearApp/ColorContrast.swift 一起用 swiftc 编译（见 build.sh），
// 所以这里直接用 ColorContrast，无需 import。
// 断言覆盖的是浮窗真正使用的那套数学，不是一份复制品。

var failures = 0
var checks = 0

func check(_ ok: Bool, _ label: String) {
    checks += 1
    if ok {
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ \(label)")
    }
}

func rgb(_ hex: String) -> ColorContrast.RGB {
    let s = hex.replacingOccurrences(of: "#", with: "")
    var v: UInt64 = 0
    Scanner(string: s).scanHexInt64(&v)
    return ColorContrast.RGB(r: Double((v >> 16) & 0xFF) / 255,
                             g: Double((v >> 8) & 0xFF) / 255,
                             b: Double(v & 0xFF) / 255)
}

/// SwiftUI 的 opacity 在分量空间合成。
func blend(_ fg: ColorContrast.RGB, _ bg: ColorContrast.RGB,
           _ a: Double) -> ColorContrast.RGB {
    ColorContrast.RGB(r: bg.r * (1 - a) + fg.r * a,
                      g: bg.g * (1 - a) + fg.g * a,
                      b: bg.b * (1 - a) + fg.b * a)
}

@main
struct VerifyContrast {
    static func main() {
        let target = ColorContrast.minimumTextContrast
        let dimTarget = ColorContrast.minimumDimContrast
        print("对比度规则自检 (已唱 \(target):1 / 未唱 \(dimTarget):1)")

        check(abs(ColorContrast.contrast(.white, .black) - 21) < 0.01,
              "黑白对比度 = 21:1")
        check(abs(ColorContrast.luminance(rgb("#808080")) - 0.216) < 0.01,
              "中灰按 sRGB gamma 线性化 ≈ 0.216，不是裸通道的 0.5")

        // 旧规则按裸亮度 0.55 一刀切：中灰 0.502 < 0.55 会选白字，只有
        // 3.95:1。按 WCAG 应选黑字 5.32:1。
        let mid = rgb("#808080")
        check(ColorContrast.bestText(on: mid) == .black,
              "中灰底色选黑字而不是白字")
        check(ColorContrast.contrast(.white, mid) < target,
              "旧规则选的白字确实不达标")
        check(ColorContrast.contrast(ColorContrast.bestText(on: mid), mid) >= target,
              "新规则选出的歌词色达标")

        // 全部来自实际运行日志：封面主色 + Apple 配色，覆盖浅、中、深、
        // 高饱和与近灰。
        let samples = [
            "#FBB7D8", "#141B25", "#D25626", "#82817F", "#D98468",
            "#FE4823", "#380903", "#574529", "#382A25", "#FD3858",
            "#E80603", "#03A9EB", "#FBCEDD",
            "#FCFCFC", "#0E0C0A", "#955041", "#EDECE8", "#AE9377",
            "#625D57", "#63492D", "#DE3D0D", "#FA4775", "#1FB0E8",
            "#AA3C10", "#C2C2C2", "#7B8AD7", "#3A3A3C"
        ]

        var badPalette = 0
        var notMinimal = 0
        var fixed45Failures = 0
        for hex in samples {
            let bg = rgb(hex)
            let fg = ColorContrast.bestText(on: bg)
            let full = ColorContrast.contrast(fg, bg)
            let a = ColorContrast.readableDim(fg: fg, on: bg)
            let dimmed = ColorContrast.contrast(blend(fg, bg, a), bg)
            let fixed = ColorContrast.contrast(blend(fg, bg, 0.45), bg)

            if full < target || dimmed < dimTarget - 0.02 { badPalette += 1 }
            if fixed < dimTarget { fixed45Failures += 1 }
            if a > 0.03 {
                let slightlyLess = max(0, a - 0.03)
                if ColorContrast.contrast(blend(fg, bg, slightlyLess), bg) >= dimTarget - 0.005 {
                    notMinimal += 1
                }
            }
        }
        check(badPalette == 0,
              "\(samples.count) 个真实底色的已唱 ≥ \(target):1、未唱 ≥ \(dimTarget):1")
        check(notMinimal == 0, "求出的未唱不透明度是最小下限，没有过度提亮")
        check(fixed45Failures > 0,
              "固定 45% 会在 \(fixed45Failures) 个底色上不达标，动态下限确有必要")

        let pale = rgb("#FBB7D8")
        let tooClose = rgb("#E89FB8")
        check(ColorContrast.contrast(tooClose, pale) < target,
              "来源给的、与底色太接近的字色会被判为不达标并替换")

        check(ColorContrast.readableDim(fg: .white, on: .white) == 1,
              "字色与底色相同时返回 1，不再继续压暗")
        check(ColorContrast.readableDim(fg: .white, on: .black) <= 0.75,
              "黑底白字仍保留明显的已唱/未唱层次")

        if failures == 0 {
            print("对比度自检全部通过 (\(checks) 项)")
        } else {
            print("对比度自检失败 \(failures) 项")
            exit(1)
        }
    }
}
