import Foundation
import AppKit

/// Event-driven replacement for the old once-a-second poller.
///
/// A full read (state + position + metadata) happens only when something
/// actually changed:
///   - `com.apple.Music.playerInfo` / `com.apple.iTunes.playerInfo`
///     distributed notifications: song change, play, pause, seek
///   - Music launching, quitting or becoming the active app
///   - an explicit user action in Pear (play/pause/next/previous/seek,
///     manual refresh, Pear becoming active)
///   - the initial read at launch
///   - a calibration noticing that the track identity changed
///
/// While playing, a 10 s calibration re-reads state, position and track ID
/// only. The calibration timer is cancelled outright when Music is paused,
/// stopped or closed, so no query of any kind happens in those states.
/// Between samples the position is interpolated in memory by
/// `PlaybackClock`.
final class MusicEventSource: @unchecked Sendable {

    private let queue = DispatchQueue(label: "Pear.MusicEvents", qos: .utility)
    private let onSnapshot: @Sendable (MusicSnapshot) -> Void
    private let onCalibration: @Sendable (MusicPlaybackSample) -> Void
    private let calibrationInterval = PlaybackClock.calibrationInterval

    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var pendingWork: DispatchWorkItem?

    private var state = ""
    private var appRunning = false
    private var lastPersistentID = ""
    private var lastCalibrationAt = Date()
    private var stopped = false

    init(onSnapshot: @escaping @Sendable (MusicSnapshot) -> Void,
         onCalibration: @escaping @Sendable (MusicPlaybackSample) -> Void) {
        self.onSnapshot = onSnapshot
        self.onCalibration = onCalibration
    }

    func start() { queue.async { [weak self] in self?.startOnQueue() } }

    func stop() { queue.async { [weak self] in self?.stopOnQueue() } }

    /// Any event asks for one full read. Bursts are debounced so a track
    /// change that fires several notifications still costs a single sample.
    func refresh() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.pendingWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.pendingWork = nil
                self?.readFullSnapshot(reason: "事件")
            }
            self.pendingWork = work
            self.queue.asyncAfter(deadline: .now() + PlaybackClock.eventDebounce,
                                  execute: work)
        }
    }

    /// Playback-control commands are explicit user actions. Re-read once
    /// shortly afterwards; the distributed notification is a second path in
    /// case Music takes a moment to report the new state.
    func run(_ source: String) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            MusicScript.run(source)
            self.queue.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                self?.readFullSnapshot(reason: "控制")
            }
        }
    }

    func seek(to seconds: TimeInterval) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            MusicScript.seek(to: seconds)
            self.queue.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                self?.readFullSnapshot(reason: "拖动")
            }
        }
    }

    // MARK: - Setup / teardown (all on `queue`)

    private func startOnQueue() {
        stopped = false
        guard distributedObservers.isEmpty else { return }

        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"] {
            let token = distributed.addObserver(
                forName: Notification.Name(name), object: nil, queue: nil) { [weak self] _ in
                    self?.refresh()
                }
            distributedObservers.append(token)
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            let token = workspace.addObserver(
                forName: name, object: nil, queue: nil) { [weak self] note in
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication,
                          app.bundleIdentifier == "com.apple.Music" else { return }
                    self?.refresh()
                }
            workspaceObservers.append(token)
        }

        // Clicking Pear's own menu bar is a good moment to catch up without
        // ever starting a polling loop.
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: nil) { [weak self] _ in
                self?.refresh()
            }
        appObservers.append(token)

        readFullSnapshot(reason: "启动")
    }

    private func stopOnQueue() {
        stopped = true
        pendingWork?.cancel()
        pendingWork = nil
        timer?.cancel()
        timer = nil
        for token in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(token)
        }
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        for token in appObservers {
            NotificationCenter.default.removeObserver(token)
        }
        distributedObservers.removeAll()
        workspaceObservers.removeAll()
        appObservers.removeAll()
    }

    // MARK: - Sampling

    private func readFullSnapshot(reason: String) {
        guard !stopped else { return }
        guard let snapshot = MusicScript.mergedSnapshot() else {
            MusicScript.info("读取失败 · 触发=\(reason)")
            return
        }
        state = snapshot.state
        appRunning = MusicScript.appIsRunning()
        lastPersistentID = snapshot.persistentID
        lastCalibrationAt = Date()
        updateCalibrationTimer()
        MusicScript.info(String(format: "完整读取 · 触发=%@ state=%@ pos=%.2f 校准=%@",
                                reason, snapshot.state, snapshot.position,
                                timer == nil ? "停" : "开"))
        onSnapshot(snapshot)
    }

    private func calibrate() {
        guard !stopped else { return }
        guard PlaybackClock.calibrationDue(state: state,
                                          appRunning: appRunning,
                                          now: Date(),
                                          lastCalibration: lastCalibrationAt,
                                          interval: calibrationInterval) else {
            updateCalibrationTimer()
            return
        }
        guard let sample = MusicScript.readPlayback() else {
            MusicScript.info("进度校准失败")
            return
        }
        lastCalibrationAt = Date()
        state = sample.state
        appRunning = MusicScript.appIsRunning()

        // A missed song-change notification would otherwise leave the old
        // lyrics on screen. Escalate to one full read, and only then.
        if PlaybackClock.trackChanged(lastID: lastPersistentID,
                                      currentID: sample.persistentID) {
            MusicScript.info("校准发现曲目变化 → 完整读取")
            readFullSnapshot(reason: "校准发现切歌")
            return
        }

        updateCalibrationTimer()
        MusicScript.info(String(format: "进度校准 · pos=%.2f state=%@ 后续=%@",
                                sample.position, sample.state,
                                timer == nil ? "停" : "开"))
        onCalibration(sample)
    }

    /// The timer exists only while Music is actively playing. Pausing or
    /// quitting cancels it; a later notification re-arms it.
    private func updateCalibrationTimer() {
        if PlaybackClock.keepsCalibrating(state: state, appRunning: appRunning) {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + calibrationInterval,
                       repeating: calibrationInterval,
                       leeway: .seconds(1))
            t.setEventHandler { [weak self] in self?.calibrate() }
            t.resume()
            timer = t
        } else {
            timer?.cancel()
            timer = nil
        }
    }
}
