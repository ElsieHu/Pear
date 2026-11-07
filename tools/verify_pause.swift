import Foundation

/// Standalone self-check for the pause-hiding rule. Compiled by build.sh on
/// every build (no XCTest on this machine), so a regression here aborts the
/// build instead of reaching the installed app.
@main
struct VerifyPause {
    static func main() {
        var passed = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else {
                print("  ✗ \(label)")
                exit(1)
            }
            passed += 1
            print("  ✓ \(label)")
        }

        print("暂停隐藏自检")

        // 1. Only an explicit pause counts. A streaming stall keeps "playing"
        //    even though the position is frozen — that is the whole reason we
        //    do not derive pause from playback progress.
        check(!PauseVisibility.isExplicitPause("playing"),
              "playing 不算暂停")
        check(!PauseVisibility.isExplicitPause(""),
              "启动前空状态不算暂停")
        check(!PauseVisibility.isExplicitPause("loading"),
              "网络加载/缓冲中的状态不算暂停")
        check(!PauseVisibility.isExplicitPause("fast forwarding"),
              "快进不算暂停")
        check(!PauseVisibility.isExplicitPause("rewinding"),
              "快退不算暂停")
        check(!PauseVisibility.isExplicitPause("unknown state"),
              "无法识别的状态一律不隐藏")

        // 2. Explicit pauses, including a localised term and stray whitespace.
        check(PauseVisibility.isExplicitPause("paused"),
              "paused 算暂停")
        check(PauseVisibility.isExplicitPause("stopped"),
              "stopped 算暂停")
        check(PauseVisibility.isExplicitPause("  Paused  "),
              "大小写与空白不影响判定")
        check(PauseVisibility.isExplicitPause("已暂停"),
              "中文本地化的暂停也算暂停")

        // 3. Grace window before hiding.
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        check(!PauseVisibility.hides(pausedSince: nil, now: start),
              "未进入暂停时不隐藏")
        check(!PauseVisibility.hides(pausedSince: start,
                                    now: start.addingTimeInterval(0.1)),
              "刚暂停 0.1 秒仍显示")
        check(!PauseVisibility.hides(pausedSince: start,
                                    now: start.addingTimeInterval(1.19)),
              "宽限期内仍显示")
        check(PauseVisibility.hides(pausedSince: start,
                                   now: start.addingTimeInterval(1.21)),
              "超过宽限时长即隐藏")
        check(PauseVisibility.hides(pausedSince: start,
                                   now: start.addingTimeInterval(60)),
              "长时间暂停持续隐藏")
        check(!PauseVisibility.hides(pausedSince: start,
                                    now: start.addingTimeInterval(-5)),
              "时钟回拨不会误判为已超时")

        // 4. Recovery is not delayed by the grace: the caller clears
        //    pausedSince, so hides(nil) is false again.
        check(!PauseVisibility.hides(pausedSince: nil,
                                    now: start.addingTimeInterval(60)),
              "恢复播放后立即重新显示")

        print("暂停隐藏自检全部通过 (\(passed) 项)")
    }
}
