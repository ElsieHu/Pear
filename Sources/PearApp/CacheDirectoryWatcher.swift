import Foundation

/// Watches Apple Music's lyrics cache directory and fires the moment the
/// Music app writes a new entry.
///
/// Polling was the original approach, but it either missed the write or
/// wasted work between writes. A vnode watcher on the directory reacts
/// immediately, so a new song's lyrics appear as soon as Music has them.
/// A slow timer is kept purely as a safety net (vnode events can be missed
/// when the volume holding the cache is unmounted, etc.).
final class CacheDirectoryWatcher {
    private let path: String
    private let onChange: () -> Void

    private let queue = DispatchQueue(label: "Pear.cacheWatch")
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var safetyTimer: DispatchSourceTimer?
    private var lastFire = Date.distantPast
    private let throttle: TimeInterval = 0.35

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard source == nil else { return }
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            AppLog.warn("无法监听缓存目录: \(path)")
            startSafetyTimer()
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                            eventMask: [.write, .extend, .rename, .delete],
                                                            queue: queue)
        src.setEventHandler { [weak self] in
            self?.fire()
        }
        src.setCancelHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            close(self.fd)
            self.fd = -1
        }
        src.resume()
        source = src
        startSafetyTimer()
        AppLog.info("已监听歌词缓存目录")
    }

    func stop() {
        safetyTimer?.cancel()
        safetyTimer = nil
        source?.cancel()
        source = nil
    }

    private func startSafetyTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.fire(force: true)
        }
        timer.resume()
        safetyTimer = timer
    }

    private func fire(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastFire) >= throttle else { return }
        lastFire = now
        onChange()
    }
}
