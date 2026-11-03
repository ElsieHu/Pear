import Foundation

// 与 Sources/LyricEngine/LyricModels.swift、LyricHighlight.swift 一起用 swiftc
// 编译（见 build.sh），所以这里直接用 TimedLyrics / LyricLine，无需 import。
//
// 守卫「尾奏把最后一句的结束时间拉长」这个 bug：最后一句的 end 常被 Apple
// 写成整曲时长（含纯音乐尾奏），lineProgress 的分母因此被拉长，唱完了扫光
// 还在慢慢爬。trimmingOutro 应把它裁回真实演唱窗口，且不动其他行。
//
// 顶层不允许写执行语句（只有 main.swift 例外），所以用 @main 承载。

var failures = 0

func check(_ ok: Bool, _ label: String) {
    if ok {
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ \(label)")
    }
}

func makeLine(_ text: String, _ start: Double, _ end: Double,
              segments: [(String, Double, Double)] = []) -> LyricLine {
    LyricLine(text: text,
              segments: segments.map {
                  LyricSegment(text: $0.0, startTime: $0.1, endTime: $0.2)
              },
              startTime: start, endTime: end)
}

func near(_ a: Double, _ b: Double, _ eps: Double = 0.001) -> Bool {
    abs(a - b) < eps
}

@main
struct VerifyTimeline {
    static func main() {
        print("歌词时间轴自检")

        // ---- 1. 逐字时间轴 + 尾奏：应裁到最后一个字的结束 ----
        do {
            let normal = [
                makeLine("第一句", 0, 4),
                makeLine("第二句", 5, 9),
                makeLine("第三句", 10, 14),
            ]
            let last = makeLine("最后一句", 20, 240,
                                segments: [("最后", 20, 22.5), ("一句", 22.5, 25)])
            let fixed = TimedLyrics(lines: normal + [last], source: "test")
                .trimmingOutro(songDuration: 240)
            check(near(fixed.lines.last!.endTime, 25),
                  "尾奏(逐字): 最后一句 end 240 → 25（最后一个字结束）")
            check(near(fixed.lines[0].endTime, 4) && near(fixed.lines[1].endTime, 9),
                  "尾奏(逐字): 前面的行时间轴不受影响")
            check(near(fixed.lineProgress(fixed.lines.last!, at: 25), 1),
                  "尾奏(逐字): 唱完时进度=1 而不是 25/220")
            check(near(fixed.lineProgress(fixed.lines.last!, at: 22.5), 0.5),
                  "尾奏(逐字): 唱到一半进度=0.5")
            check(fixed.activeLineIndex(at: 120) == 3,
                  "尾奏(逐字): 尾奏期间最后一句仍保持显示（不空白）")
            check(near(fixed.lineProgress(fixed.lines.last!, at: 120), 1),
                  "尾奏(逐字): 尾奏期间进度保持 1，不再爬升")
        }

        // ---- 2. 仅逐行时间轴 + 尾奏：用正常句长估计演唱窗口 ----
        do {
            let normal = [
                makeLine("第一句", 0, 4),
                makeLine("第二句", 5, 9),
                makeLine("第三句", 10, 14),
            ]
            let last = makeLine("最后一句", 190, 240) // end == 整曲时长，无 span
            let fixed = TimedLyrics(lines: normal + [last], source: "test")
                .trimmingOutro(songDuration: 240)
            check(near(fixed.lines.last!.endTime, 194),
                  "尾奏(逐行): end 240 → 194（start + 典型句长 4s）")
            check(near(fixed.lineProgress(fixed.lines.last!, at: 194), 1),
                  "尾奏(逐行): 估计的演唱结束时进度=1")
            check(near(fixed.lineProgress(fixed.lines.last!, at: 240), 1),
                  "尾奏(逐行): 播放到曲末进度仍=1（钳制，不越界）")
        }

        // ---- 3. 没有尾奏时绝不误裁 ----
        do {
            let normal = [makeLine("第一句", 0, 4), makeLine("第二句", 5, 9)]
            let last = makeLine("最后一句", 10, 14,
                                segments: [("最后", 10, 12), ("一句", 12, 14)])
            let fixed = TimedLyrics(lines: normal + [last], source: "test")
                .trimmingOutro(songDuration: 14.2)
            check(near(fixed.lines.last!.endTime, 14),
                  "无尾奏: 最后一句 end 保持 14 不变")
            check(near(fixed.lineProgress(fixed.lines.last!, at: 12), 0.5),
                  "无尾奏: 半程进度仍为 0.5")
        }

        // ---- 4. 短尾奏（0.5s 内）不触发裁剪 ----
        do {
            let normal = [makeLine("第一句", 0, 4)]
            let last = makeLine("最后一句", 10, 14.3,
                                segments: [("最后", 10, 12), ("一句", 12, 14)])
            let fixed = TimedLyrics(lines: normal + [last], source: "test")
                .trimmingOutro(songDuration: 14.3)
            check(near(fixed.lines.last!.endTime, 14.3),
                  "短尾奏(<0.5s): 不裁剪，避免抖动")
        }

        // ---- 5. 证据不足（单行、无曲长、无逐字）时绝不猜测 ----
        do {
            let only = makeLine("唯一一句", 0, 240)
            let fixed = TimedLyrics(lines: [only], source: "test").trimmingOutro()
            check(near(fixed.lines.last!.endTime, 240),
                  "无证据: 单行且不知曲长时保持原样（不误裁长音）")
        }

        // ---- 5b. 已知曲长但 end 不贴曲末 → 不裁 ----
        do {
            let normal = [makeLine("第一句", 0, 4), makeLine("第二句", 5, 9)]
            let last = makeLine("最后一句", 10, 60)
            let fixed = TimedLyrics(lines: normal + [last], source: "test")
                .trimmingOutro(songDuration: 240)
            check(near(fixed.lines.last!.endTime, 60),
                  "end 不贴曲末: 即使窗口偏长也不裁")
        }

        // ---- 6. 基础进度计算 ----
        do {
            let l = makeLine("一句", 10, 14)
            let lyrics = TimedLyrics(lines: [l], source: "test")
            check(near(lyrics.lineProgress(l, at: 10), 0)
                  && near(lyrics.lineProgress(l, at: 12), 0.5)
                  && near(lyrics.lineProgress(l, at: 14), 1)
                  && near(lyrics.lineProgress(l, at: 20), 1),
                  "lineProgress 基础边界正确")
        }

        print(failures == 0 ? "  时间轴自检全部通过 (6 组)" : "  时间轴自检失败: \(failures) 项")
        exit(failures == 0 ? 0 : 1)
    }
}
