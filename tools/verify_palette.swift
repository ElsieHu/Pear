import Foundation

// 与 Sources/PearApp/ColorContrast.swift、ColorPalette.swift 一起用 swiftc
// 编译（见 build.sh），断言的就是浮窗真正使用的两色提取规则。

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

func near(_ a: ColorContrast.RGB, _ b: ColorContrast.RGB, _ tolerance: Double) -> Bool {
    abs(a.r - b.r) < tolerance && abs(a.g - b.g) < tolerance && abs(a.b - b.b) < tolerance
}

func repeated(_ hex: String, _ count: Int) -> [ColorContrast.RGB] {
    Array(repeating: rgb(hex), count: count)
}

@main
struct VerifyPalette {
    static func main() {
        print("封面两色提取自检")

        check(ColorPalette.extract(from: []) == nil, "空像素返回 nil")

        // 1. 纯单色封面：确实没有第二色，兜底色仍需可读。
        let solid = ColorPalette.extract(from: repeated("#303030", 400))
        check(solid != nil, "单色封面也能给出一对颜色")
        if let solid {
            check(!solid.hasSecondColour, "单色封面标记为没有第二个封面色")
            check(ColorContrast.contrast(solid.dark, solid.light)
                  >= ColorContrast.minimumTextContrast,
                  "单色封面的兜底字色达到字色底线")
            check(near(solid.primary, rgb("#303030"), 0.01), "主色就是封面色")
        }

        // 2. 面积主导 + 暗亮排序：深蓝占 70%，亮黄占 30%。
        let two = repeated("#123456", 700) + repeated("#FFE066", 300)
        let pair = ColorPalette.extract(from: two)
        check(pair != nil, "双色封面提取成功")
        if let pair {
            check(pair.hasSecondColour, "双色封面标记为找到第二色")
            check(near(pair.primary, rgb("#123456"), 0.06),
                  "主色取面积最大的簇，不被亮色小块抢走")
            check(ColorContrast.luminance(pair.dark) <= ColorContrast.luminance(pair.light),
                  "两色按 WCAG 亮度排成暗 / 亮")
            check(near(pair.dark, rgb("#123456"), 0.08)
                  && near(pair.light, rgb("#FFE066"), 0.08),
                  "暗色=深蓝、亮色=亮黄，默认暗色打底时正好是深底亮字")
            check(ColorContrast.contrast(pair.dark, pair.light)
                  >= ColorContrast.minimumTextContrast,
                  "选出的两色本身达到大字对比度")
        }

        // 3. 渐变不再被固定色阶平均成一团灰棕，两端颜色都保留下来。
        var gradient: [ColorContrast.RGB] = []
        for i in 0..<120 {
            let t = Double(i) / 119
            gradient.append(ColorContrast.RGB(r: 1.0 - 0.875 * t,
                                              g: 0.88 - 0.755 * t,
                                              b: 0.69 - 0.44 * t))
        }
        let grad = ColorPalette.extract(from: gradient)
        check(grad != nil, "渐变封面提取成功")
        if let grad {
            check(grad.light.r > 0.6, "亮端仍是浅暖色，没有被平均成灰棕")
            check(grad.dark.b > grad.dark.r, "暗端仍是深蓝，没有被平均成灰棕")
            check(ColorContrast.contrast(grad.dark, grad.light) >= 3.0,
                  "渐变两端仍可作为一对可读配色")
        }

        // 4. 相同亮度的两种色相也要能配对，而不是退化成黑白。
        let sameLightness = repeated("#C04040", 500) + repeated("#40C0C0", 500)
        let sl = ColorPalette.extract(from: sameLightness)
        check(sl != nil && sl?.hasSecondColour == true,
              "亮度接近、色相不同的封面仍给出两种封面色")
        if let sl {
            check(ColorPalette.hueDistance(sl.dark, sl.light) > 0.3,
                  "两色确实有可辨的色相差")
        }

        // 5. 确定性：同一封面每次结果完全一致，切歌回来不会变色。
        let again = ColorPalette.extract(from: two)
        check(again?.darkHex == pair?.darkHex && again?.lightHex == pair?.lightHex,
              "同一封面重复提取结果一致（无随机种子抖动）")

        // 6. 《珠玉》那类封面：红是主色，青/蓝面积不小、色相差异最大，
        // 但对比只有约 1.9:1。旧规则用 4.5:1 硬过滤把它淘汰，退而选了
        // 对比最高的中性色；现在应优先取封面里确实存在的蓝色，可读性
        // 交给易读模式微调。
        let redCover = repeated("#F03E47", 600)
            + repeated("#45C9CA", 200)
            + repeated("#E9E4D9", 150)
            + repeated("#44423C", 50)
        let redPair = ColorPalette.extract(from: redCover)
        check(redPair != nil, "红 + 蓝 + 浅色封面提取成功")
        if let redPair {
            check(near(redPair.primary, rgb("#F03E47"), 0.06),
                  "主色仍是面积最大的红色")
            check(near(redPair.light, rgb("#45C9CA"), 0.09)
                  || near(redPair.dark, rgb("#45C9CA"), 0.09),
                  "第二色选中封面里的蓝/青，而不是白色或黑色")
            check(ColorContrast.contrast(redPair.dark, redPair.light)
                  < ColorContrast.minimumTextContrast,
                  "允许选出尚未达标但色相不同的封面色，交由易读微调")
            check(redPair.hasSecondColour, "标记为找到了封面第二色")
        }

        // 7. 色相距离与 hex 序列化。
        check(ColorPalette.hueDistance(rgb("#FF0000"), rgb("#00FFFF")) > 0.4,
              "红 / 青色相距离大")
        check(ColorPalette.hueDistance(rgb("#FF0000"), rgb("#808080")) == 0,
              "灰色不参与色相距离竞争")
        check(rgb("#1A2B3C").hexString == "#1A2B3C", "RGB → #RRGGBB 序列化正确")

        if failures == 0 {
            print("两色提取自检全部通过 (\(checks) 项)")
        } else {
            print("两色提取自检失败 \(failures) 项")
            exit(1)
        }
    }
}
