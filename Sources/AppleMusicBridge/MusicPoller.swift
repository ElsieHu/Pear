import Foundation

/// Owns the timer + queue that drive AppleScript polling.
///
/// Why this is a separate, **non-isolated** type
/// ---------------------------------------------
/// In Swift 6, a closure written inside a `@MainActor` method *inherits*
/// main-actor isolation when the API it is passed to does not require
/// `@Sendable` — which is the case for `DispatchSource.setEventHandler` and
/// `DispatchQueue.async`. Handed to a background queue, such a closure traps
/// with `EXC_BREAKPOINT` (`_swift_task_checkIsolatedSwift`) the moment it
/// runs. The app crashed on launch because of exactly that.
///
/// Keeping every closure inside a type with no actor isolation at all makes
/// the isolation explicit and the trap impossible.
final class MusicPoller {
    private let queue = DispatchQueue(label: "Pear.AppleScript", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 1.0
    private let onSnapshot: @Sendable (MusicSnapshot) -> Void

    init(onSnapshot: @escaping @Sendable (MusicSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
    }

    deinit { stop() }

    func start() {
        reschedule()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Change the poll rate (1 Hz while playing, 0.33 Hz when idle).
    func setInterval(_ newInterval: TimeInterval) {
        guard abs(newInterval - interval) > 0.01 else { return }
        interval = newInterval
        reschedule()
    }

    /// Consecutive failed polls. After a few, slow right down: while the
    /// Automation grant is missing every attempt fails the same way, and
    /// asking once a second achieves nothing but wasted processes.
    private var failures = 0

    func pollOnce() {
        queue.async { [onSnapshot] in
            guard let snapshot = MusicScript.mergedSnapshot() else { return }
            onSnapshot(snapshot)
        }
    }

    private func noteResult(_ snapshot: MusicSnapshot?) {
        if snapshot == nil {
            failures += 1
            if failures == 3 { setInterval(5.0) }
            else if failures == 6 { setInterval(15.0) }
        } else if failures > 0 {
            failures = 0
            setInterval(1.0)   // the monitor re-adjusts for playing/idle
        }
    }

    func run(_ source: String) {
        queue.async { MusicScript.run(source) }
    }

    private func reschedule() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let ms = max(200, Int(interval * 1000))
        timer.schedule(deadline: .now() + interval, repeating: .milliseconds(ms), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self, onSnapshot] in
            let snapshot = MusicScript.mergedSnapshot()
            self?.noteResult(snapshot)
            guard let snapshot else { return }
            onSnapshot(snapshot)
        }
        timer.resume()
        self.timer = timer
    }
}
