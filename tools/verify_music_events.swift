import Foundation

/// Standalone self-check for the in-memory playback clock and the rule that
/// governs when Pear is allowed to sample Music at all.
@main
struct VerifyMusicEvents {
    static func main() {
        var passed = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else {
                print("  ✗ \(label)")
                exit(1)
            }
            passed += 1
        }

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // Local interpolation: no Music query on the UI redraw path.
        check(PlaybackClock.position(anchor: 10, anchorDate: t0,
                                     now: t0.addingTimeInterval(2.5),
                                     playing: true) == 12.5,
              "播放中按本地时间推进")
        check(PlaybackClock.position(anchor: 10, anchorDate: t0,
                                     now: t0.addingTimeInterval(2.5),
                                     playing: false) == 10,
              "暂停时锚点冻结")
        check(PlaybackClock.position(anchor: 10, anchorDate: t0,
                                     now: t0.addingTimeInterval(-5),
                                     playing: true) == 10,
              "时钟回拨不倒退")
        check(PlaybackClock.position(anchor: 0, anchorDate: .distantPast,
                                     now: t0, playing: true) > 0,
              "无锚点时仍可推进")

        // Calibration is allowed only while Music is actually playing.
        check(PlaybackClock.keepsCalibrating(state: "playing", appRunning: true),
              "播放中保留校准")
        check(!PlaybackClock.keepsCalibrating(state: "paused", appRunning: true),
              "暂停时停止校准")
        check(!PlaybackClock.keepsCalibrating(state: "stopped", appRunning: true),
              "停止时停止校准")
        check(!PlaybackClock.keepsCalibrating(state: "fast forwarding", appRunning: true),
              "快进时停止校准")
        check(!PlaybackClock.keepsCalibrating(state: "rewinding", appRunning: true),
              "快退时停止校准")
        check(!PlaybackClock.keepsCalibrating(state: "playing", appRunning: false),
              "Music 未运行时停止校准")

        check(PlaybackClock.calibrationDue(state: "playing", appRunning: true,
                                          now: t0.addingTimeInterval(10),
                                          lastCalibration: t0),
              "到 10 秒允许校准")
        check(!PlaybackClock.calibrationDue(state: "playing", appRunning: true,
                                           now: t0.addingTimeInterval(9.9),
                                           lastCalibration: t0),
              "未满 10 秒不校准")
        check(!PlaybackClock.calibrationDue(state: "paused", appRunning: true,
                                           now: t0.addingTimeInterval(60),
                                           lastCalibration: t0),
              "暂停多久都不校准")
        check(!PlaybackClock.calibrationDue(state: "playing", appRunning: false,
                                           now: t0.addingTimeInterval(60),
                                           lastCalibration: t0),
              "Music 退出后不校准")

        check(PlaybackClock.calibrationInterval >= 10 &&
              PlaybackClock.calibrationInterval <= 30,
              "校准间隔落在 10~30 秒")
        check(PlaybackClock.eventDebounce > 0 && PlaybackClock.eventDebounce < 0.5,
              "事件合并窗口合理")

        check(PlaybackClock.trackChanged(lastID: "", currentID: "ABC"),
              "首次拿到曲目身份视为切歌")
        check(PlaybackClock.trackChanged(lastID: "ABC", currentID: "DEF"),
              "校准发现切歌")
        check(!PlaybackClock.trackChanged(lastID: "ABC", currentID: "ABC"),
              "同一首歌不重复读元数据")
        check(!PlaybackClock.trackChanged(lastID: "ABC", currentID: ""),
              "空身份不触发读取")

        // One hour of continuous playback. The old 1 Hz poller sampled 3600
        // times; event-driven + calibration must stay at 360 or fewer.
        var samples = 0
        var last = t0
        for second in 1...3600 {
            let now = t0.addingTimeInterval(Double(second))
            if PlaybackClock.calibrationDue(state: "playing", appRunning: true,
                                           now: now, lastCalibration: last) {
                samples += 1
                last = now
            }
        }
        check(samples == 360, "一小时播放采样 360 次（原为 3600 次）")

        // After a pause, no amount of elapsed time may produce a sample.
        var pausedSamples = 0
        for second in 1...600 {
            let now = t0.addingTimeInterval(Double(second) * 10)
            if PlaybackClock.calibrationDue(state: "paused", appRunning: true,
                                           now: now, lastCalibration: t0) {
                pausedSamples += 1
            }
        }
        check(pausedSamples == 0, "暂停期间零采样")

        print("播放状态自检通过：\(passed) 项")
    }
}
