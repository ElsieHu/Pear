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

        check(target == 3.0,
              "已唱底线是 22pt 粗体大字的 3:1，不是正文小字的 4.5:1")
        check(dimTarget < target,
              "未唱下限略低，刚达标的字色仍能保留扫光层次")

        check(abs(ColorContrast.contrast(.white, .black) - 21) < 0.01,
              "黑白对比度 = 21:1")
        check(abs(ColorContrast.luminance(rgb("#808080")) - 0.216) < 0.01,
              "中灰按 sRGB gamma 线性化 ≈ 0.216，不是裸通道的 0.5")

        let mid = rgb("#808080")
        check(ColorContrast.bestText(on: mid) == .black,
              "中灰底色选对比更高的黑字")
        check(ColorContrast.contrast(.white, mid) >= target,
              "3:1 下中灰上的白字也已达标，不再被强行换掉")
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

        // 易读模式：保留封面的第二个颜色，只把它往可读方向微调。
        let readable = rgb("#141B25")
        check(ColorContrast.adjustedForContrast(readable, on: pale) == readable,
              "两色本来就达标时原样保留，不改动封面色")
        let nudged = ColorContrast.adjustedForContrast(tooClose, on: pale)
        check(ColorContrast.contrast(nudged, pale) >= target - 0.005,
              "过近的封面字色被微调到达标")
        check(nudged != .black && nudged != .white,
              "微调保留封面自身颜色，不直接跳到纯黑/纯白")
        check(ColorContrast.contrast(blend(nudged, tooClose, 0.97), pale) < target,
              "调整量恰好是达标所需的最小值")
        let darkBg = rgb("#141B25")
        let darkText = rgb("#2A3038")
        check(ColorContrast.adjustedForContrast(darkText, on: darkBg).r > darkText.r,
              "深底上的暗字往白调，浅底上的亮字往黑调")

        // 《珠玉》：旧规则在红底上连纯白都过不了 4.5:1，于是把米白一路
        // 压成近黑 #1C1B1A。3:1 下米白原样保留。
        let red = rgb("#F03E47")
        let cream = rgb("#E9E4D9")
        check(ColorContrast.contrast(.white, red) < 4.5,
              "红底上纯白只有 3.83:1，4.5:1 小字标准正是旧规则压黑的根源")
        check(ColorContrast.contrast(cream, red) >= target,
              "封面的米白在红底上达到大字 3:1")
        check(ColorContrast.adjustedForContrast(cream, on: red) == cream,
              "已达标的封面字色原样保留，黑字问题消失")
        check(ColorContrast.readableDim(fg: cream, on: red) < 1,
              "刚达标的字色仍保留未唱层次，不把不透明度顶到 100%")

        // 双向微调：蓝/青在红底上只有 1.9:1，朝白比朝黑改动更小。
        let cyan = rgb("#45C9CA")
        check(ColorContrast.contrast(cyan, red) < target,
              "封面蓝/青原本确实读不清")
        let adjustedCyan = ColorContrast.adjustedForContrast(cyan, on: red)
        check(ColorContrast.contrast(adjustedCyan, red) >= target - 0.005,
              "低对比的封面蓝被微调到达标")
        check(adjustedCyan.r > cyan.r && adjustedCyan.g > cyan.g,
              "两个方向都试，取改动更小的白色方向，不再一律压黑")

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
