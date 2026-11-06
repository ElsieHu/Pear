import Foundation
import Combine
import AppKit
import SwiftUI
import LyricEngine
import AppleMusicBridge

/// What the floating window should render right now.
///
/// The pill is *content*, not a status surface: when a song has no lyrics
/// (still loading, waiting for Apple Music to write its cache, or Apple has
/// no synced lyrics at all) it stays hidden. Those messages belong in the
/// menu-bar panel / 状态 page, where they do not cover the desktop.
enum PanelContent: Equatable {
    case hidden
    case lyrics
}

/// Shared application state: owns the Apple Music monitor, the lyrics
/// sources, and all persisted appearance settings.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let monitor = AppleMusicMonitor()
    private let musicKitSource = AppleMusicLyricsSource()

    @Published var lyrics: TimedLyrics?
    @Published var isFetching = false
    @Published var lastError: String?

    /// Persisted appearance of the floating window.
    @Published var appearance: LyricAppearance {
        didSet { persistAppearance(); applyAutoColors() }
    }

    /// Colours derived from the current album artwork (nil when unused).
    @Published var autoBackgroundHex: String?
    @Published var autoTextHex: String?

    /// The appearance actually rendered: manual colours, or the album's.
    var effectiveAppearance: LyricAppearance {
        appearance.effective(backgroundHex: autoBackgroundHex, textHex: autoTextHex)
    }

    private var currentArtwork: AppleMusicCacheLyricsSource.ArtworkInfo?
    private var artworkCancellable: AnyCancellable?
    private var monitorCancellable: AnyCancellable?

    /// User-controlled visibility (menu bar toggle).
    @Published var windowEnabled = true

    /// Opt-in: also try the official MusicKit web API (needs a Developer token).
    @Published var useMusicKitAPI = false {
        didSet { UserDefaults.standard.set(useMusicKitAPI, forKey: "useMusicKitAPI") }
    }

    /// Manual calibration for a constant lyric/audio offset, in seconds.
    /// Positive values make the lyrics run *earlier* (use when lyrics lag
    /// behind the music); negative values delay them.
    @Published var lyricTimeOffset: Double = 0 {
        didSet { UserDefaults.standard.set(lyricTimeOffset, forKey: "lyricTimeOffset") }
    }

    /// Whether Pear is registered as a login item. Read back from the actual
    /// LaunchAgent file so the switch can never lie about the real state.
    @Published var launchAtLogin: Bool = false

    func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAgentManager.setEnabled(enabled)
        launchAtLogin = LaunchAgentManager.isEnabled
    }

    /// What the menu-bar item shows (icon / title / artist, any combination).
    @Published var menuBarDisplay: MenuBarDisplay {
        didSet { persistMenuBarDisplay() }
    }

    private var lastTrackKey: String?

    // MARK: - Retry state

    /// Set when the last attempt failed with “not downloaded *yet*”, i.e. a
    /// retry is meaningful. A definitive “Apple has no lyrics for this” stops
    /// the loop so we don't burn CPU on a song that will never have any.
    private var retryEligible = false
    private var retryAttempt = 0
    private var cacheWatcher: CacheDirectoryWatcher?
    /// Incremented by the cache watcher; the loop wakes on it.
    private var cacheDirty = false
    /// Set only by a genuine directory write (not the 5 s safety timer).
    private var colourWritePending = false
    private var fetchGeneration = 0

    private init() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: "appearance"),
           let decoded = try? JSONDecoder().decode(LyricAppearance.self, from: data) {
            self.appearance = decoded
        } else {
            self.appearance = LyricAppearance()
        }
        self.useMusicKitAPI = ud.bool(forKey: "useMusicKitAPI")
        self.lyricTimeOffset = ud.double(forKey: "lyricTimeOffset")
        self.launchAtLogin = LaunchAgentManager.isEnabled
        if let data = ud.data(forKey: "menuBarDisplay"),
           let decoded = try? JSONDecoder().decode(MenuBarDisplay.self, from: data) {
            self.menuBarDisplay = decoded
        } else {
            self.menuBarDisplay = .default
        }
    }

    // MARK: - Lifecycle

    func start() {
        AppLog.info("=== Pear 启动 ===")

        // Surface script failures (bad syntax, -10004 permission denial, …)
        // in the log instead of silently reporting "no track".
        MusicScript.diagnosticHandler = { message in
            AppLog.warn("AppleScript: \(message)")
        }
        monitor.start()
        // `monitor` is its own ObservableObject; views observe *this* object,
        // so its @Published changes would not reach them on their own. Without
        // this relay the menu panel's play/pause icon and track title only
        // refreshed by accident (whenever some unrelated @Published changed).
        monitorCancellable = monitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }

        // Artwork arrives asynchronously; re-derive colours once it lands.
        artworkCancellable = ArtworkLoader.shared.$dominantHex
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyAutoColors() }
            }

        // Watch Apple Music's cache directory: the moment the Music app
        // writes a song's TTML we retry, instead of waiting for a poll.
        if let dir = AppleMusicCacheLyricsSource.cacheDirectory {
            let watcher = CacheDirectoryWatcher(path: dir.path) { [weak self] forced in
                Task { @MainActor in
                    guard let self else { return }
                    self.cacheDirty = true
                    // A real write may be the artwork metadata we were
                    // waiting for — retry the colour lookup right away. The
                    // periodic safety net stays on the backoff schedule, or
                    // it would re-scan the whole cache every five seconds.
                    if !forced { self.colourWritePending = true }
                }
            }
            watcher.start()
            cacheWatcher = watcher
        }

        AppLog.info("start(): 正在下发监听循环")
        Task {
            AppLog.info("监听循环已启动")
            await self.watchTrackChanges()
        }
    }

    // MARK: - Album artwork & colour

    /// Look up the current track's artwork and load it (for the menu panel).
    /// The polling loop calls this on every tick even when the song has not
    /// changed, so only log an actual state change — otherwise a track with
    /// no artwork floods the log with the same warning every five seconds.
    private var lastArtworkLog = ""

    private func resolveArtwork(force: Bool = false) {
        // A retry must not read the 2-second memoised scan: the whole point is
        // to notice a cache file that has just been written.
        if force { AppleMusicCacheLyricsSource.invalidateScanCache() }
        guard let track = monitor.track else {
            currentArtwork = nil
            lastArtworkLog = ""
            ArtworkLoader.shared.load(url: nil)
            applyAutoColors()
            return
        }
        let info = AppleMusicCacheLyricsSource.artworkInfo(for: track)
        currentArtwork = info
        ArtworkLoader.shared.load(url: info?.url(size: 300))
        let msg: String
        if let info {
            msg = "封面已解析: url=\(info.url(size: 300)?.absoluteString ?? "nil") bg=\(info.bgColorHex ?? "-") fg=\(info.textColorHex ?? "-")"
        } else {
            msg = "封面未找到: 《\(track.title)》- \(track.artist) [\(String(format: "%.1f", track.duration))s]"
        }
        if msg != lastArtworkLog {
            lastArtworkLog = msg
            // A miss on the very first lookup is normal: the Music app writes
            // artwork metadata asynchronously, usually 2–4 s later. Logging a
            // WARN there made every single track change look like a failure.
            // A genuinely missing cover is reported by the colour fallback
            // chain once the grace period expires.
            if info != nil { AppLog.info(msg) }
        }
        applyAutoColors()
    }

    /// Turn artwork colours into the pill's palette through an explicit,
    /// logged chain: extracted colour → Apple's palette → the user's own
    /// manual colours.
    ///
    /// A *missing* automatic colour is deliberately NOT resolved into a
    /// substitute here. The auto fields are cleared so
    /// `LyricAppearance.effective()` shows the user's manual palette verbatim,
    /// and `autoColourMissing` keeps a dedicated retry loop alive until the
    /// real colours land. Swapping in a neutral grey instead hid the failure
    /// without fixing it — the actual defect was that the lookup never
    /// retried, which is why hitting 刷新 always "fixed" it.
    private var lastColorLog = ""

    private func validHex(_ value: String?) -> String? {
        guard let value, Color(hex: value) != nil else { return nil }
        return value
    }

    private func clearAutoColours() {
        // Only publish on a real change: every assignment fires
        // objectWillChange and redraws the settings window.
        if autoBackgroundHex != nil { autoBackgroundHex = nil }
        if autoTextHex != nil { autoTextHex = nil }
    }

    private func applyAutoColors() {
        guard appearance.colorModeRaw != "manual" else {
            clearAutoColours()
            autoColourMissing = false
            colourRetryAttempt = 0
            nextColourRetryDate = .distantPast
            lastColorLog = ""
            return
        }

        // No track yet (launch, or Music has just been quit): no artwork to
        // derive colours from. Emitting "取色失败" here was a false alarm.
        guard monitor.track != nil else {
            clearAutoColours()
            autoColourMissing = false
            colourRetryAttempt = 0
            nextColourRetryDate = .distantPast
            lastColorLog = ""
            return
        }

        let mode = appearance.colorModeRaw
        let info = currentArtwork
        let dominant = validHex(ArtworkLoader.shared.dominantHex)
        let appleBG = validHex(info?.bgColorHex)
        let appleFG = validHex(info?.textColorHex)

        var bg: String?
        var fg: String?
        var source = ""
        /// A colour from the *other* source is better than nothing to look at,
        /// but it is not what the user asked for — keep retrying for the real
        /// one instead of declaring victory and stopping the loop.
        var exact = false

        if mode == "artwork" {
            if let d = dominant { bg = d; source = "封面取色"; exact = true }
            else if let a = appleBG { bg = a; fg = appleFG; source = "Apple 配色暂代" }
        } else { // "album" — Apple's own bgColor / textColor1 pairing
            if let a = appleBG { bg = a; fg = appleFG; source = "Apple 配色"; exact = true }
            else if let d = dominant { bg = d; source = "封面主色暂代" }
        }

        if bg == nil {
            // Show the user's own manual palette until the real one arrives,
            // and keep retrying. Holding the *previous song's* colour here
            // made the pill look wrong for as long as the cache was missing.
            autoColourMissing = true
            clearAutoColours()   // → effective() uses the manual palette
            scheduleColourRetry()

            let reason = "取色未成功: 暂用手动配色 mode=\(mode) 有封面=\(info != nil) 主色=\(dominant ?? "-") AppleBG=\(appleBG ?? "-") 最近失败=\(ArtworkLoader.shared.lastFailure ?? "-")"
            // Deduplicated: the retry loop may call this dozens of times, and
            // the reason usually does not change between attempts.
            if reason != lastColorLog {
                lastColorLog = reason
                AppLog.warn(reason)
            }
            return
        }

        if exact {
            autoColourMissing = false
            colourRetryAttempt = 0
            nextColourRetryDate = .distantPast
        } else {
            // Still waiting for the requested source: show what we have (or
            // the manual palette) but keep the retry loop alive.
            autoColourMissing = true
            scheduleColourRetry()
        }
        if autoBackgroundHex != bg || autoTextHex != fg {
            autoBackgroundHex = bg
            autoTextHex = fg
        }

        let msg = "配色[\(mode)] 来源=\(source) bg=\(bg ?? "-") fg=\(fg ?? "自动")\(exact ? "" : " (继续重试)")"
        guard msg != lastColorLog else { return }
        lastColorLog = msg
        AppLog.info(msg)
    }

    private func scheduleColourRetry() {
        if nextColourRetryDate == .distantPast { nextColourRetryDate = Date() }
    }

    /// Detect track changes and (re)fetch lyrics from Apple Music.
    ///
    /// The Music app writes a song's TTML to disk *asynchronously* — often a
    /// second or two after playback starts. So a single fetch at track-change
    /// time is not enough; we retry until it lands, but back off so a song
    /// that genuinely has no lyrics doesn't keep the CPU busy all day.
    private var nextRetryDate = Date.distantPast

    /// Fibonacci-ish backoff, capped. Plus the cache watcher short-circuits
    /// all of this the instant the file actually appears.
    private static let backoff: [TimeInterval] = [0.6, 1.2, 2, 3, 5, 8, 13, 20]

    private var didInitialFetch = false
    private var lastNoTrackLog = Date.distantPast
    private let startedAt = Date()

    // MARK: - Automatic colour retry
    //
    // The real bug behind "一刷新就成功": artwork metadata lives in Apple
    // Music's *lyrics* cache and is written seconds (sometimes minutes) after
    // a song starts. The old code looked once at track change, retried for at
    // most 18 s, and then stopped forever as soon as `currentArtwork` became
    // non-nil — even when that entry carried no colours. `retry()` (刷新)
    // restarted the whole track-change path, which is exactly why it always
    // worked. There is no time window on this loop any more.
    /// True while an automatic mode has no usable palette for this track.
    private var autoColourMissing = false
    private var colourRetryAttempt = 0
    private var nextColourRetryDate = Date.distantPast
    /// Backing off but never giving up: the cache can be written at any point
    /// during a song, and a 40 s tail keeps looking without burning CPU.
    private static let colourBackoff: [TimeInterval] =
        [0.4, 0.8, 1.5, 2.5, 4, 6, 10, 15, 25, 40]

    private func watchTrackChanges() async {
        while !Task.isCancelled {
            let key = monitor.trackIdentity

            // nil == nil on the very first pass, so without this the initial
            // fetch (and its log line) would be skipped entirely.
            let isChange = key != lastTrackKey || !didInitialFetch

            if isChange {
                didInitialFetch = true
                lastTrackKey = key
                retryAttempt = 0
                retryEligible = true
                cacheDirty = false
                nextRetryDate = .distantPast
                // Never carry the previous song's auto palette into a new
                // track: it is a wrong colour, not a graceful transition.
                clearAutoColours()
                colourRetryAttempt = 0
                nextColourRetryDate = .distantPast
                if let t = monitor.track {
                    AppLog.info("曲目切换 → 《\(t.title)》- \(t.artist) [\(String(format: "%.1f", t.duration))s] 来源=AppleScript")
                } else if !MusicScript.appIsRunning() {
                    AppLog.info("音乐未运行 → 浮窗隐藏, 不再发送 AppleScript (不会把音乐重新打开)")
                } else if Date().timeIntervalSince(startedAt) > 2 {
                    // On launch the first loop iteration always runs before
                    // the first AppleScript poll has returned. Complaining
                    // about "no permission" there was a false alarm.
                    AppLog.warn("拿不到当前曲目 → 见上一条 AppleScript 具体报错 (若为 -10004 则是自动化未授权, 请在本应用重新打开后到「系统设置 ▸ 隐私与安全性 ▸ 自动化」允许控制“音乐”)")
                }
                resolveArtwork(force: true)
                await fetchCurrent()
            } else if monitor.track == nil,
                      Date().timeIntervalSince(startedAt) > 5,
                      Date().timeIntervalSince(lastNoTrackLog) > 10 {
                lastNoTrackLog = Date()
                if MusicScript.appIsRunning() {
                    AppLog.warn("音乐在运行但读不到当前曲目 (具体原因见上面的 AppleScript 报错行)")
                }
            }

            // The cache watcher fires on real writes (and every 5 s as a
            // safety net). Lyrics *and* artwork metadata live in that same
            // directory, so a write has to re-run both lookups.
            if cacheDirty {
                cacheDirty = false
                let realWrite = colourWritePending
                colourWritePending = false
                AppleMusicCacheLyricsSource.invalidateScanCache()
                if lyrics == nil, monitor.track != nil, retryEligible {
                    retryAttempt += 1
                    await fetchCurrent()
                }
                if realWrite, autoColourMissing { nextColourRetryDate = .distantPast }
            }

            if lyrics == nil, monitor.track != nil, retryEligible,
               Date() >= nextRetryDate {
                retryAttempt += 1
                await fetchCurrent()
            }

            // Automatic colour has its own retry loop, independent of the
            // lyrics state and of any track-change window. It keeps going
            // until a real palette resolves — or the track changes.
            if autoColourMissing, monitor.track != nil,
               Date() >= nextColourRetryDate {
                colourRetryAttempt += 1
                let idx = min(colourRetryAttempt - 1, Self.colourBackoff.count - 1)
                nextColourRetryDate = Date().addingTimeInterval(Self.colourBackoff[idx])
                if colourRetryAttempt == 1 || colourRetryAttempt % 8 == 0 {
                    AppLog.info("配色重试 第 \(colourRetryAttempt) 次 有封面=\(currentArtwork != nil) 主色=\(ArtworkLoader.shared.dominantHex ?? "-") 最近失败=\(ArtworkLoader.shared.lastFailure ?? "-")")
                }
                // `resolveArtwork` calls `ArtworkLoader.load(url:)` again;
                // after a failed download it has cleared its "already
                // requested" marker, so this is also the cover re-download.
                resolveArtwork(force: true)
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func fetchCurrent() async {
        guard let track = monitor.track else {
            lyrics = nil
            lastError = nil
            return
        }
        isFetching = true
        defer { isFetching = false }

        // Primary source: Apple Music's own on-disk lyrics cache.
        do {
            let cached = try AppleMusicCacheLyricsSource.lyrics(for: track)
            lyrics = cached
            lastError = nil
            retryEligible = false
            retryAttempt = 0
            let m = AppleMusicCacheLyricsSource.bestMatch(for: track)
            AppLog.info("拿到歌词 《\(track.title)》 \(cached.lines.count) 行, 逐字=\(cached.hasWordTiming) 匹配到《\(m?.entry.title ?? "?")》分=\(m?.score ?? 0)")
            return
        } catch let error as AppleMusicCacheLyricsSource.CacheError {
            switch error {
            case .noTimeSyncedLyrics:
                // Definitive: Apple's catalogue has no synced lyrics for this
                // song. Stop retrying — it will never arrive.
                retryEligible = false
                lastError = error.errorDescription
                AppLog.info("《\(track.title)》Apple Music 目录内无同步歌词, 停止重试")
                return
            case .noLyrics, .cacheUnavailable:
                break
            }
        } catch {
            AppLog.warn("缓存解析失败: \(error.localizedDescription)")
        }

        // Optional secondary: the official MusicKit web API. Needs a paid
        // Developer Program token, so it is off by default.
        if useMusicKitAPI {
            do {
                lyrics = try await musicKitSource.fetchLyrics(for: track)
                lastError = nil
                retryEligible = false
                AppLog.info("MusicKit API 拿到歌词")
                return
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                AppLog.warn("MusicKit API 失败: \(lastError ?? "")")
                return
            }
        }

        // Requirement #1: never fall back to Spotify / LRCLIB / NetEase / QQ.
        lyrics = nil
        lastError = AppleMusicCacheLyricsSource.CacheError.noLyrics.errorDescription
        retryEligible = true
        let idx = min(retryAttempt, Self.backoff.count - 1)
        nextRetryDate = Date().addingTimeInterval(Self.backoff[idx])
        if retryAttempt <= 1 || retryAttempt % 4 == 0 {
            let d = AppleMusicCacheLyricsSource.diagnose(for: track)
            AppLog.info("未命中 (第 \(retryAttempt) 次) 缓存曲目数=\(d.cacheEntryCount) 最高分=\(d.bestScore) 候选=\(d.bestTitle ?? "无") 已拒绝=\(d.rejectedTitle ?? "无")(\(d.rejectedScore)) 找到歌曲记录=\(d.foundSongRecord) 目录标记有词=\(String(describing: d.catalogueHasSyncedLyrics))")
        }
    }

    /// Manual retry (e.g. after the user grants Automation access).
    func retry() {
        lastTrackKey = nil
        retryAttempt = 0
        retryEligible = true
        nextRetryDate = .distantPast
        colourRetryAttempt = 0
        nextColourRetryDate = .distantPast
        resolveArtwork(force: true)
        Task { await fetchCurrent() }
    }

    // MARK: - Panel content

    var panelContent: PanelContent {
        guard windowEnabled else { return .hidden }
        // No track → stay out of the way (Music isn't playing / no permission).
        guard monitor.track != nil else { return .hidden }
        // No lyrics → stay out of the way as well. This covers the brief
        // fetch, the "waiting for Apple Music to write its cache" retry loop
        // and songs with no synced lyrics at all. Showing an "正在等待…" pill
        // (or an error pill) for minutes was the reported annoyance; the
        // status is still available in the menu-bar panel and 状态 page.
        guard let lyrics, !lyrics.lines.isEmpty else { return .hidden }
        return .lyrics
    }

    // MARK: - Persistence

    private func persistMenuBarDisplay() {
        guard let data = try? JSONEncoder().encode(menuBarDisplay) else { return }
        UserDefaults.standard.set(data, forKey: "menuBarDisplay")
    }

    /// One pending debounced write. A slider drag fires `didSet` many times;
    /// without cancelling the previous task, an older snapshot could land
    /// *after* a newer one and silently revert a mode/colour choice.
    private var appearanceSaveTask: Task<Void, Never>?

    private func persistAppearance() {
        let snapshot = appearance
        appearanceSaveTask?.cancel()
        appearanceSaveTask = Task { @MainActor in
            // Coalesce rapid slider drags into a single write.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: "appearance")
            // Let the panel re-fit to the new text metrics.
            NotificationCenter.default.post(name: .appearanceDidChange, object: nil)
        }
    }

    func resetAppearance() {
        appearance = LyricAppearance()
    }

    /// Apply **only the palette** from a preset.
    ///
    /// Replacing the whole struct used to reset the font, size, radius and —
    /// worst of all — `colorModeRaw` (a preset is built from defaults, where
    /// the mode is `album`). That made choosing a manual colour silently jump
    /// back to album colours and throw away the user's font choice. Presets
    /// touch exactly three colour fields; everything else stays independent.
    func applyPreset(_ preset: LyricAppearance) {
        var updated = appearance
        updated.backgroundColorHex = preset.backgroundColorHex
        updated.textColorHex = preset.textColorHex
        updated.highlightColorHex = preset.highlightColorHex
        // Picking a preset is an explicit "use these manual colours".
        updated.colorModeRaw = "manual"
        appearance = updated
    }

    /// Flip the two halves of a manual colour pair: background becomes the
    /// lyric colour and vice versa. The highlight follows the lyric colour
    /// whenever it was tracking it, so a preset keeps its two-colour look;
    /// a separately customised highlight colour is left alone.
    func swapManualColors() {
        var updated = appearance
        let oldBackground = updated.backgroundColorHex
        let oldText = updated.textColorHex
        let oldHighlight = updated.highlightColorHex

        updated.backgroundColorHex = oldText
        updated.textColorHex = oldBackground
        if oldHighlight == oldText {
            updated.highlightColorHex = oldBackground
        } else if oldHighlight == oldBackground {
            updated.highlightColorHex = oldText
        }
        updated.colorModeRaw = "manual"
        appearance = updated
    }
}

