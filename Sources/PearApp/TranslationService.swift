import Foundation
import SwiftUI
import AppKit
// TranslationSession's batch API is `@concurrent` while SwiftUI's
// `.translationTask` closure inherits the main actor. Without the
// preconcurrency import Swift 6 rejects handing the session (and its
// requests) to the framework even though the session never leaves the
// closure. The values crossing the actor boundary here are plain strings.
@preconcurrency import Translation

extension Notification.Name {
    /// Translated text landed (or failed); the pill must re-measure its height.
    static let translationDidChange = Notification.Name("Pear.translationDidChange")
}

/// One song's translation work, handed to the SwiftUI bridge.
///
/// Only `Sendable` values cross the actor boundary: `TranslationSession`
/// itself stays inside the `.translationTask` closure, which keeps Swift 6's
/// strict concurrency checking happy and follows Apple's guidance not to
/// store sessions.
struct TranslationJob: Sendable, Equatable {
    let id: String
    let lines: [String]
    let indices: [Int]
    let target: String
}

/// Owns translation preferences, the on-disk cache and the current result.
///
/// Translation is **entirely on-device** via Apple's Translation framework
/// (macOS 15+): no API key, no network request, no third-party service. The
/// whole song is translated in one batch when it changes; until the result
/// lands the original lyrics keep working exactly as before.
@MainActor
final class TranslationService: ObservableObject {
    static let shared = TranslationService()

    @Published var settings: TranslationSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
            // Target language changes the cache key; the other knobs are
            // cheap no-ops because update() short-circuits on an unchanged key.
            update(lines: currentLines)
        }
    }

    /// Line-indexed translations; an empty string means "no translation for
    /// this line" (already in the target language, or still in flight).
    @Published private(set) var translations: [String] = []
    /// Human-readable current state, shown at body size in 设置 ▸ 翻译.
    @Published private(set) var status: String = "未开启"
    @Published private(set) var isWorking = false
    /// Bumped for every new batch. The host view uses it as its SwiftUI
    /// identity, so a fresh `.translationTask` (and therefore a fresh
    /// `TranslationSession`) is guaranteed for each song. Cancelling the old
    /// task is exactly what we want when the track changes mid-translation.
    @Published private(set) var jobVersion = 0
    /// Set when the system needs its translation models downloaded. The
    /// settings page offers a visible button that triggers Apple's own
    /// download UI — a hidden helper window would swallow that sheet.
    @Published private(set) var needsModelSetup = false
    /// Bytes currently occupied by on-disk translations (设置 ▸ 翻译 ▸ 缓存).
    @Published private(set) var cacheBytes: Int64 = 0

    var isAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private var currentLines: [String] = []
    private var currentKey: String?
    private var pendingJob: TranslationJob?
    private var jobTaken = false
    /// Guards against a slow model-status query for a song that has already
    /// been switched away from.
    private var modelGeneration = 0
    private var waitingForModel = false

    private init() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: TranslationSettings.storageKey),
           let decoded = try? JSONDecoder().decode(TranslationSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = TranslationSettings()
        }
        refreshCacheSize()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: TranslationSettings.storageKey)
    }

    // MARK: - Song lifecycle

    /// Call whenever the current song's lyrics change (including to `[]`).
    func update(lines: [String]) {
        currentLines = lines
        guard settings.enabled else {
            reset(message: "未开启")
            return
        }
        guard isAvailable else {
            reset(message: "需要 macOS 15 或更新")
            return
        }
        guard !lines.isEmpty else {
            reset(message: "等待歌词")
            return
        }

        let target = settings.targetLanguage
        let indices = TranslationRules.translatableIndices(lines: lines, target: target)
        guard !indices.isEmpty else {
            currentKey = TranslationRules.cacheKey(lines: lines, target: target)
            translations = Array(repeating: "", count: lines.count)
            pendingJob = nil
            jobTaken = false
            isWorking = false
            needsModelSetup = false
            status = "已是\(TranslationSettings.displayName(for: target))，无需翻译"
            notifyChange()
            return
        }

        let key = TranslationRules.cacheKey(lines: lines, target: target)
        if key == currentKey, !translations.isEmpty {
            return
        }
        currentKey = key

        if let cached = loadCached(key: key, lineCount: lines.count) {
            translations = cached
            pendingJob = nil
            jobTaken = false
            isWorking = false
            needsModelSetup = false
            status = "已缓存 · \(indices.count) 行"
            AppLog.info("翻译命中缓存 key=\(key.prefix(8)) 行数=\(indices.count)")
            notifyChange()
            return
        }

        translations = Array(repeating: "", count: lines.count)
        pendingJob = nil
        jobTaken = false
        isWorking = true
        needsModelSetup = false
        status = "检查语言模型…"
        notifyChange()

        // The translation session lives in a tiny helper window that the user
        // cannot see. Apple's model-download sheet would attach to *that*
        // window and hang there forever, so check availability first and let
        // the visible settings window own the download instead.
        modelGeneration += 1
        let generation = modelGeneration
        let sample = lines[indices[0]]
        Task { @MainActor [weak self] in
            guard let self else { return }
            let state = await Self.modelState(for: sample, target: target)
            guard self.modelGeneration == generation, self.currentKey == key else { return }
            switch state {
            case .installed:
                self.dispatch(job: TranslationJob(id: key, lines: lines,
                                                  indices: indices, target: target))
            case .needsDownload:
                self.isWorking = false
                self.needsModelSetup = true
                self.status = "需要下载语言模型"
                self.notifyChange()
                AppLog.info("翻译等待系统语言模型 目标=\(target)")
                self.waitForModel(sample: sample, target: target, key: key)
            case .unsupported:
                self.isWorking = false
                self.status = "系统不支持这组语言"
                self.notifyChange()
                AppLog.warn("系统不支持该语言组合 目标=\(target) 例句=\(sample.prefix(20))")
            }
        }
    }

    private func dispatch(job: TranslationJob) {
        pendingJob = job
        jobTaken = false
        isWorking = true
        needsModelSetup = false
        status = "翻译中 · \(job.indices.count) 行"
        AppLog.info("翻译开始 key=\(job.id.prefix(8)) 目标=\(job.target) 送翻=\(job.indices.count)/\(job.lines.count) 行")
        jobVersion += 1
        notifyChange()

        // A system call that never returns must not leave the settings page
        // reading "翻译中" forever.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.pendingJob?.id == job.id else { return }
            self.needsModelSetup = true
            self.status = "翻译耗时过长，请重试或下载语言模型"
            AppLog.warn("翻译超过 25 秒未返回 key=\(job.id.prefix(8))")
        }
    }

    private enum ModelState: Equatable { case installed, needsDownload, unsupported }

    private static func modelState(for sample: String, target: String) async -> ModelState {
        guard #available(macOS 15.0, *) else { return .unsupported }
        let availability = LanguageAvailability()
        let to = Locale.Language(identifier: target)
        guard let status = try? await availability.status(for: sample, to: to) else {
            return .installed   // let the real call decide if the query fails
        }
        switch status {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .installed
        }
    }

    /// After the user opens Apple's translation popover once, the model
    /// downloads in the background. Pick the translation up automatically
    /// instead of making them guess when to press 重新翻译.
    private func waitForModel(sample: String, target: String, key: String) {
        guard !waitingForModel else { return }
        waitingForModel = true
        Task { @MainActor [weak self] in
            defer { self?.waitingForModel = false }
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.currentKey == key, self.needsModelSetup else { return }
                let state = await Self.modelState(for: sample, target: target)
                if state == .installed {
                    AppLog.info("语言模型已就绪，自动继续翻译")
                    self.status = "语言模型就绪，开始翻译"
                    self.retry()
                    return
                }
            }
        }
    }

    /// Force the current song through the translator again (settings page).
    func retry() {
        currentKey = nil
        translations = []
        update(lines: currentLines)
    }

    func clearForSongChange() {
        currentKey = nil
        translations = []
    }

    private func reset(message: String) {
        currentKey = nil
        translations = []
        pendingJob = nil
        jobTaken = false
        isWorking = false
        needsModelSetup = false
        status = message
        notifyChange()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .translationDidChange, object: nil)
    }

    // MARK: - Bridge interface

    /// Consumed once per job: a second (e.g. redundant) `translationTask`
    /// run for the same song must not issue a duplicate batch.
    func takeJob() -> TranslationJob? {
        guard let job = pendingJob, !jobTaken else { return nil }
        jobTaken = true
        return job
    }

    func finish(jobID: String, texts: [String], error: String?) {
        guard let job = pendingJob, job.id == jobID else { return }
        pendingJob = nil
        jobTaken = false
        isWorking = false

        if let error {
            needsModelSetup = true
            status = "翻译失败 · \(error)"
            AppLog.warn("翻译失败: \(error)")
        } else {
            let merged = TranslationRules.merged(lineCount: job.lines.count,
                                                 indices: job.indices,
                                                 translated: texts)
            let count = merged.filter { !$0.isEmpty }.count
            translations = merged
            needsModelSetup = false
            status = count > 0 ? "已翻译 · \(count) 行" : "译文为空"
            saveCached(key: job.id, target: job.target, texts: merged)
            refreshCacheSize()
            AppLog.info("翻译完成 \(count)/\(job.indices.count) 行 目标=\(job.target)")
        }
        notifyChange()
    }

    // MARK: - Disk cache

    private struct Cached: Codable {
        let target: String
        let texts: [String]
    }

    private static var cacheDirectory: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory,
                                                  in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Pear/Translations", isDirectory: true)
    }

    private func cacheURL(key: String) -> URL? {
        Self.cacheDirectory?.appendingPathComponent("\(key).json")
    }

    private func loadCached(key: String, lineCount: Int) -> [String]? {
        guard let url = cacheURL(key: key),
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(Cached.self, from: data),
              cached.texts.count == lineCount else { return nil }
        return cached.texts
    }

    private func saveCached(key: String, target: String, texts: [String]) {
        guard let dir = Self.cacheDirectory, let url = cacheURL(key: key) else { return }
        do {
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Cached(target: target, texts: texts))
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.warn("翻译缓存写入失败: \(error.localizedDescription)")
        }
    }

    /// Recount the files Pear wrote. Called at launch, after each save, and
    /// whenever the settings page appears (the folder can change externally).
    func refreshCacheSize() {
        guard let dir = Self.cacheDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            cacheBytes = 0
            return
        }
        var total: Int64 = 0
        for name in names where TranslationRules.isCacheFile(name) {
            let url = dir.appendingPathComponent(name)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                continue
            }
            total += Int64(size)
        }
        cacheBytes = total
    }

    /// Delete only the `<hex>.json` files Pear itself wrote. The song that is
    /// playing keeps its on-screen translation; the next song translates
    /// again and repopulates the cache.
    func clearCache() {
        guard let dir = Self.cacheDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            refreshCacheSize()
            return
        }
        var removed = 0
        for name in names where TranslationRules.isCacheFile(name) {
            do {
                try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                removed += 1
            } catch {
                AppLog.warn("翻译缓存清理失败 \(name): \(error.localizedDescription)")
            }
        }
        let freed = cacheBytes
        refreshCacheSize()
        if !isWorking { status = "缓存已清理" }
        AppLog.info("翻译缓存已清理 文件=\(removed) 释放=\(TranslationRules.formattedCacheSize(freed))")
        notifyChange()
    }
}

// MARK: - SwiftUI bridge
//
// `.translationTask` is the only macOS 15 API that hands out a
// `TranslationSession` usable outside Apple's own translation popover. It
// lives on a SwiftUI view, so a tiny always-present helper window hosts it.
// Session objects are never stored: jobs are queued as plain values, and the
// bridge view's identity changes per job so each song gets a fresh session.

@available(macOS 15.0, *)
struct TranslationBridge: View {
    @ObservedObject var service: TranslationService
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                AppLog.info("翻译会话就绪 目标=\(service.settings.targetLanguage) 系统=\(ProcessInfo.processInfo.operatingSystemVersionString)")
                guard let job = service.takeJob() else { return }
                let requests = job.indices.map { index in
                    TranslationSession.Request(sourceText: job.lines[index],
                                               clientIdentifier: String(index))
                }
                do {
                    let responses = try await Self.batchTranslate(session, requests)
                    var byIndex: [Int: String] = [:]
                    for response in responses {
                        if let raw = response.clientIdentifier,
                           let index = Int(raw) {
                            byIndex[index] = response.targetText
                        }
                    }
                    let texts = job.indices.map { byIndex[$0] ?? "" }
                    service.finish(jobID: job.id, texts: texts, error: nil)
                } catch {
                    service.finish(jobID: job.id, texts: [],
                                        error: error.localizedDescription)
                }
            }
            .onAppear { resetConfiguration() }
    }

    private func resetConfiguration() {
        configuration = TranslationSession.Configuration(
            source: nil,
            target: Locale.Language(identifier: service.settings.targetLanguage))
    }

    /// `requests` is built inside the main-actor-inherited SwiftUI closure but
    /// is never used again after the framework call; `sending` transfers that
    /// ownership explicitly instead of sharing it with the concurrent API.
    private static func batchTranslate(
        _ session: TranslationSession,
        _ requests: sending [TranslationSession.Request]
    ) async throws -> [TranslationSession.Response] {
        try await session.translations(from: requests)
    }
}

/// Rebuilding the bridge on `jobVersion` is what starts each new batch.
/// It is more dependable than invalidating a session in place: SwiftUI tears
/// down the old `.translationTask` (cancelling a translation for a song the
/// user already skipped) and the fresh view picks up the queued job.
@available(macOS 15.0, *)
private struct TranslationHostRoot: View {
    @ObservedObject private var service = TranslationService.shared

    var body: some View {
        TranslationBridge(service: service)
            .id(service.jobVersion)
    }
}

/// A 2×2, fully transparent, click-through window that stays alive for the
/// whole session. It is visible to AppKit (so SwiftUI keeps its
/// `.translationTask` alive) but cannot be seen, focused or cycled to.
@available(macOS 15.0, *)
@MainActor
final class TranslationHostWindow {
    private let window: NSWindow

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
                         styleMask: [.borderless],
                         backing: .buffered,
                         defer: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isExcludedFromWindowsMenu = true
        w.collectionBehavior = [.ignoresCycle, .transient, .stationary, .canJoinAllSpaces]
        w.contentView = NSHostingView(rootView: TranslationHostRoot())
        w.orderFrontRegardless()
        window = w
    }
}
