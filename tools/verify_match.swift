import Foundation

// 与 Sources/AppleMusicBridge/LyricMatch.swift 一起用 swiftc 编译（见 build.sh），
// 所以这里直接用 LyricMatch，无需 import。
//
// 为什么不用 XCTest / swift-testing：这台机器只装了 Command Line Tools，
// XCTest 不存在，swift-testing 的 lib_TestingInterop.dylib 也缺失，
// `swift test` 根本跑不起来。这个自检在每次构建时执行，是这些规则的真正守卫。

var failures = 0

func check(_ ok: Bool, _ label: String) {
    if ok {
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ \(label)")
    }
}

/// 模拟一次匹配：输入按真实调用路径一样先归一化。
func match(candidate: (title: String, artist: String, duration: Double),
           target: (title: String, artist: String, duration: Double))
    -> (score: Double, accepted: Bool) {
    LyricMatch.evaluate(candidateTitle: LyricMatch.normalize(candidate.title),
                        candidateArtist: LyricMatch.normalize(candidate.artist),
                        candidateDuration: candidate.duration,
                        targetTitle: LyricMatch.normalize(target.title),
                        targetArtist: LyricMatch.normalize(target.artist),
                        targetDuration: target.duration)
}

// 顶层不允许写执行语句（只有 main.swift 例外），所以用 @main 承载。
@main
struct VerifyMatch {
    static func main() {
        print("缓存歌词匹配规则自检")

        // 真实发生的 bug：同艺人、同专辑、不同歌，把上一首的 69 行当成《珠玉》显示。
        let crossSong = match(candidate: ("我管不住我自己", "单依纯", 261.6),
                              target: ("珠玉", "单依纯", 202.4))
        check(crossSong.accepted == false, "同艺人不同歌必须拒绝（串歌回归）")

        let exact = match(candidate: ("珠玉", "单依纯", 202.4),
                          target: ("珠玉", "单依纯", 202.4))
        check(exact.accepted, "完全一致应命中")
        check(abs(exact.score - 15.0) < 0.001, "完全一致得分应为 15（标题10+艺人3+时长2）")

        // 翻唱/不同艺人唱同一首，标题即身份，仍应命中。
        let cover = match(candidate: ("珠玉", "SomeoneElse", 199.0),
                          target: ("珠玉", "单依纯", 202.4))
        check(cover.accepted, "标题一致时艺人不同也应命中")

        // `"珠玉".contains("")` 恒为真 —— 空标题不能仅凭艺人相同就命中。
        let emptyTitle = match(candidate: ("", "单依纯", 261.6),
                               target: ("珠玉", "单依纯", 202.4))
        check(emptyTitle.accepted == false, "空标题且时长不符时必须拒绝")

        // 但空标题 + 艺人 + 时长三项都对得上，八成就是同一首歌（只是该条目
        // 缺元数据），此时拒绝反而会永远等不到歌词。
        let emptyTitleAgreed = match(candidate: ("", "单依纯", 202.4),
                                     target: ("珠玉", "单依纯", 202.4))
        check(emptyTitleAgreed.accepted, "空标题但艺人+时长一致时允许命中")

        // 万一 AppleScript 给不出标题：艺人 + 时长一致是可信的兜底。
        let unknownTitle = match(candidate: ("珠玉", "单依纯", 202.4),
                                 target: ("", "单依纯", 202.4))
        check(unknownTitle.accepted, "标题未知时艺人+时长一致应命中")

        // "鲜花 - Single" 这类版本后缀仍要能匹配上。
        let suffix = match(candidate: ("鲜花 - Single", "回春丹", 341.4),
                           target: ("鲜花", "回春丹", 341.4))
        check(suffix.accepted, "标题带版本后缀仍应命中")

        // 毫不相干的两首歌。
        let unrelated = match(candidate: ("Back To Bedlam", "James Blunt", 213.0),
                              target: ("珠玉", "单依纯", 202.4))
        check(unrelated.accepted == false, "艺人与标题都不同必须拒绝")

        // 归一化：标点与大小写不应影响相等判定。
        check(LyricMatch.normalize("Don't Stop") == LyricMatch.normalize("Dont Stop"),
              "归一化应消除标点差异")

        print(failures == 0 ? "全部通过" : "\(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
