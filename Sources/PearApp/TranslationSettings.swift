import Foundation

/// Persisted translation preferences.
///
/// Kept free of SwiftUI / Translation imports so the pure decision rules
/// below can be compiled by `tools/verify_translation.swift` on every build.
struct TranslationSettings: Codable, Equatable {
    /// Master switch. Off by default: translation is opt-in.
    var enabled: Bool = false
    /// BCP-47 tag of the language shown underneath the original line.
    var targetLanguage: String = "zh-Hans"
    /// Translation font size relative to the main lyric line.
    var relativeSize: Double = 0.62
    /// Keep showing the upcoming line when a translation is on screen.
    /// Off by default so the pill stays two lines: original + translation.
    var keepNextLine: Bool = false

    static let storageKey = "translationSettings"

    private enum CodingKeys: String, CodingKey {
        case enabled, targetLanguage, relativeSize, keepNextLine
    }

    init() {}

    /// Per-key decode, for the same reason as `LyricAppearance`: a new knob
    /// must not wipe the user's existing preferences.
    init(from decoder: Decoder) throws {
        var s = TranslationSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ into: inout T) {
            if let v = try? c.decode(T.self, forKey: key) { into = v }
        }
        read(.enabled, &s.enabled)
        read(.targetLanguage, &s.targetLanguage)
        read(.relativeSize, &s.relativeSize)
        read(.keepNextLine, &s.keepNextLine)
        self = s
    }

    /// Languages Apple's on-device Translation framework actually supports
    /// (checked against `LanguageAvailability.supportedLanguages` on macOS 27).
    static let targets: [(id: String, name: String)] = [
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁体中文"),
        ("en-US", "English"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
        ("fr-FR", "Français"),
        ("de-DE", "Deutsch"),
        ("es-ES", "Español"),
        ("it-IT", "Italiano"),
        ("pt-BR", "Português"),
        ("ru-RU", "Русский"),
        ("th-TH", "ไทย"),
        ("vi-VN", "Tiếng Việt"),
        ("id-ID", "Bahasa Indonesia"),
        ("tr-TR", "Türkçe"),
        ("nl-NL", "Nederlands"),
        ("pl-PL", "Polski"),
        ("uk-UA", "Українська"),
        ("ar-AE", "العربية"),
        ("hi-IN", "हिन्दी")
    ]

    static func displayName(for id: String) -> String {
        targets.first { $0.id == id }?.name ?? id
    }
}

/// Pure, UI-free decisions about *what* to translate.
///
/// The system translator is on-device and free, but it cannot translate
/// Chinese lyrics into Chinese, and feeding it instrumental markers (`♪`,
/// `(…)`) produces noise. Short lyric lines also defeat
/// `NLLanguageRecognizer`, so script counting (Unicode ranges) is both more
/// predictable here and straightforward to unit-test.
enum TranslationRules {

    enum Script: String, Equatable {
        case han, kana, hangul, latin, cyrillic, thai, arabic, devanagari, other
    }

    /// A stable, framework-free 64-bit FNV-1a hash used for the cache key.
    static func cacheKey(lines: [String], target: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (lines.joined(separator: "\n") + "\u{1}" + target).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// Two-letter language code, so `zh-Hans` and `zh-Hant` both read as `zh`.
    static func languageCode(_ tag: String) -> String {
        String(tag.split(separator: "-").first ?? "")
            .lowercased()
    }

    /// Character counts per script. Deliberately ignores punctuation,
    /// digits and whitespace — they carry no language signal.
    static func scriptCounts(_ text: String) -> [Script: Int] {
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let s: Script?
            switch v {
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF: s = .kana
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: s = .hangul
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: s = .han
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F,
                 0x1E00...0x1EFF, 0x0100...0x017F: s = .latin
            case 0x0400...0x04FF: s = .cyrillic
            case 0x0E00...0x0E7F: s = .thai
            case 0x0600...0x06FF: s = .arabic
            case 0x0900...0x097F: s = .devanagari
            default: s = nil
            }
            if let s { counts[s, default: 0] += 1 }
        }
        return counts
    }

    /// Dominant script, or nil when a line has no language-bearing character.
    static func dominantScript(_ text: String) -> Script? {
        let counts = scriptCounts(text)
        // Kana / Hangul beat Han: Japanese and Korean lyrics are full of Han
        // characters, but a single kana or hangul syllable identifies them.
        if (counts[.kana] ?? 0) > 0 { return .kana }
        if (counts[.hangul] ?? 0) > 0 { return .hangul }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func code(for script: Script) -> String {
        switch script {
        case .han: return "zh"
        case .kana: return "ja"
        case .hangul: return "ko"
        case .latin: return "en"
        case .cyrillic: return "ru"
        case .thai: return "th"
        case .arabic: return "ar"
        case .devanagari: return "hi"
        case .other: return ""
        }
    }

    /// Whether one lyric line needs translating into `target`.
    ///
    /// Returns false for lines already in the target language, for pure
    /// punctuation / instrumental markers, and for text whose script cannot
    /// be identified. Singing an English hook inside a Chinese song is *not*
    /// skipped — those lines genuinely benefit from a translation.
    static func needsTranslation(_ line: String, target: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let script = dominantScript(trimmed), script != .other else { return false }
        let source = code(for: script)
        guard !source.isEmpty else { return false }
        let wanted = languageCode(target)
        // Chinese → Chinese (including 简体/繁体) is a no-op for the system
        // translator; Latin-script European languages are treated as one
        // group, so an English line is only skipped when English is the goal.
        return source != wanted
    }

    /// Indices of the lines that actually go to the translator.
    static func translatableIndices(lines: [String], target: String) -> [Int] {
        lines.indices.filter { needsTranslation(lines[$0], target: target) }
    }

    /// Merge sparse responses back into a full, line-indexed array.
    static func merged(lineCount: Int, indices: [Int], translated: [String]) -> [String] {
        var result = Array(repeating: "", count: max(0, lineCount))
        for (offset, index) in indices.enumerated() {
            guard index >= 0, index < result.count, offset < translated.count else { continue }
            result[index] = translated[offset]
        }
        return result
    }

    // MARK: - Disk cache

    /// A cache file is named `<16 lowercase hex digits>.json` — the FNV-1a
    /// key from `cacheKey`. Anything else in that folder is left untouched
    /// when the user clears the cache.
    static func isCacheFile(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(5)
        guard stem.count == 16 else { return false }
        return stem.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    /// Compact size label for 设置 ▸ 翻译 ▸ 缓存.
    static func formattedCacheSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}
