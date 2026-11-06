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
            let watcher = CacheDirectoryWatcher(path: dir.path) { [weak self] in
                Task { @MainActor in self?.cacheDirty = true }
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

    private func resolveArtwork() {
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
    /// logged fallback chain: extracted colour → Apple's palette → the
    /// user's own manual colour → a neutral grey. A usable background is
    /// guaranteed on every path, even when the artwork never loads.
    private var lastColorLog = ""

    private func validHex(_ value: String?) -> String? {
        guard let value, Color(hex: value) != nil else { return nil }
        return value
    }

    private func applyAutoColors() {
        guard appearance.colorModeRaw != "manual" else {
            // Only publish on a real change: every assignment fires
            // objectWillChange and redraws the settings window, which used to
            // make the colour-source picker jitter while being used.
            if autoBackgroundHex != nil || autoTextHex != nil {
                autoBackgroundHex = nil
                autoTextHex = nil
            }
            lastColorLog = ""
            return
        }

        // No track yet (launch, or Music has just been quit): there is no
        // artwork to derive colours from. Emitting "取色失败" here was a
        // false alarm on every single launch.
        guard monitor.track != nil else {
            if autoBackgroundHex != nil { autoBackgroundHex = nil }
            if autoTextHex != nil { autoTextHex = nil }
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

        if mode == "artwork" {
            if let d = dominant {
                bg = d; source = "封面取色"
            } else if let a = appleBG {
                bg = a; fg = appleFG; source = "封面取色失败→Apple 配色"
            }
        } else { // "album" — Apple's own bgColor / textColor1 pairing
            if let a = appleBG {
                bg = a; fg = appleFG; source = "Apple 配色"
            } else if let d = dominant {
                bg = d; source = "Apple 配色缺失→封面取色"
            }
        }

        var fallbackWarning: String?
        if bg == nil {
            // For the first few seconds of a new track the cache simply has
            // not written artwork / Apple's palette yet. Hold the previous
            // palette instead of flashing the manual colour and then jumping
            // back when the real one lands a couple of seconds later.
            if Date() < artworkGraceUntil, autoBackgroundHex != nil { return }

            // Automatic modes must never borrow the manual palette. The user
            // may have picked a loud two-colour preset and then switched back
            // to album/artwork mode; falling back to those colours made the
            // pill turn purple for a few seconds on every track change, which
            // looked exactly like "colour extraction failed".
            bg = LyricAppearance.neutralBackgroundHex
            source = (source.isEmpty ? "自动取色不可用" : source) + "→中性色"
            fallbackWarning = "取色失败: \(source) mode=\(mode) 有封面=\(info != nil) 主色=\(dominant ?? "-") AppleBG=\(appleBG ?? "-") 最近失败=\(ArtworkLoader.shared.lastFailure ?? "-")"
        }

        // nil → LyricAppearance.effective() computes a legible text colour.
        if autoBackgroundHex != bg || autoTextHex != fg {
            autoBackgroundHex = bg
            autoTextHex = fg
        }

        let msg = "配色[\(mode)] 来源=\(source) bg=\(bg ?? "-") fg=\(fg ?? "自动")"
        // Emit both the success INFO and the fallback WARN only when the
        // resolved palette actually changes, so a repeating poll stays quiet.
        guard msg != lastColorLog else { return }
        lastColorLog = msg
        if let fallbackWarning {
            AppLog.warn(fallbackWarning)
        } else {
            AppLog.info(msg)
        }
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

    /// The Music app writes artwork metadata and its TTML to the cache a few
    /// seconds *after* a track starts. During that window the previous song's
    /// palette is a better answer than a flash of the manual fallback colour.
    private var artworkGraceUntil: Date = .distantPast
    private var nextArtworkDate: Date = .distantPast

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
                artworkGraceUntil = Date().addingTimeInterval(6)
                nextArtworkDate = .distantPast
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
                resolveArtwork()
                await fetchCurrent()
                // The cache is written asynchronously, so the first lookup
                // can miss the artwork even though the song is known. The
                // lyrics path retries; the artwork path must too, or the
                // album colours silently stay at the default forever.
                if currentArtwork == nil { resolveArtwork() }
            } else if monitor.track == nil,
                      Date().timeIntervalSince(startedAt) > 5,
                      Date().timeIntervalSince(lastNoTrackLog) > 10 {
                lastNoTrackLog = Date()
                if MusicScript.appIsRunning() {
                    AppLog.warn("音乐在运行但读不到当前曲目 (具体原因见上面的 AppleScript 报错行)")
                }
            } else if lyrics == nil, monitor.track != nil, retryEligible {
                let due = cacheDirty || Date() >= nextRetryDate
                if due {
                    cacheDirty = false
                    retryAttempt += 1
                    await fetchCurrent()
                    if currentArtwork == nil { resolveArtwork() }
                }
            }

            // Artwork metadata can land *after* the lyrics. Keep looking for
            // a short while, otherwise the album palette stays on the
            // fallback colour for the whole song once the first lookup misses.
            if monitor.track != nil, currentArtwork == nil,
               Date() >= nextArtworkDate,
               Date() < artworkGraceUntil.addingTimeInterval(12) {
                nextArtworkDate = Date().addingTimeInterval(1.0)
                resolveArtwork()
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
        resolveArtwork()
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

