import Foundation

/// Standalone self-check for the translation decision rules. Compiled by
/// build.sh on every build (no XCTest on this machine), so a regression that
/// would send Chinese lyrics to the translator — or skip Japanese lyrics
/// because they contain Han characters — aborts the build.
@main
struct VerifyTranslation {
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

        print("翻译规则自检")

        // 1. Language tags collapse to a two-letter code.
        check(TranslationRules.languageCode("zh-Hans") == "zh", "简中归一为 zh")
        check(TranslationRules.languageCode("zh-Hant") == "zh", "繁中归一为 zh")
        check(TranslationRules.languageCode("en-US") == "en", "英语归一为 en")
        check(TranslationRules.languageCode("ja-JP") == "ja", "日语归一为 ja")

        // 2. Lines already in the target language are skipped.
        check(!TranslationRules.needsTranslation("我爱故我在", target: "zh-Hans"),
              "中文歌词不翻成简体中文")
        check(!TranslationRules.needsTranslation("紅塵有你", target: "zh-Hant"),
              "繁体歌词不翻成繁体中文")
        check(!TranslationRules.needsTranslation("Hello, how are you", target: "en-US"),
              "英文歌词不翻成英文")
        check(!TranslationRules.needsTranslation("こんにちは 世界", target: "ja-JP"),
              "日文歌词不翻成日文")
        check(!TranslationRules.needsTranslation("안녕하세요", target: "ko-KR"),
              "韩文歌词不翻成韩文")

        // 3. Kana / Hangul must win over Han: Japanese and Korean lines are
        //    full of Chinese characters but still need a Chinese translation.
        check(TranslationRules.needsTranslation("地球儀 回る 世界", target: "zh-Hans"),
              "含汉字的日文歌词仍要翻译")
        check(TranslationRules.needsTranslation("사랑해요 世界", target: "zh-Hans"),
              "含汉字的韩文歌词仍要翻译")
        check(TranslationRules.needsTranslation("Hello, how are you", target: "zh-Hans"),
              "英文歌词翻成中文")
        check(TranslationRules.needsTranslation("Bonjour tout le monde", target: "zh-Hans"),
              "拉丁字母歌词翻成中文")
        check(TranslationRules.needsTranslation("Привет мир", target: "zh-Hans"),
              "西里尔字母歌词翻成中文")
        check(TranslationRules.needsTranslation("Hello 世界", target: "zh-Hans"),
              "中英混合歌词也翻译")

        // 4. Instrumental markers and punctuation carry no language.
        check(!TranslationRules.needsTranslation("♪", target: "zh-Hans"), "音符不翻译")
        check(!TranslationRules.needsTranslation("…", target: "zh-Hans"), "省略号不翻译")
        check(!TranslationRules.needsTranslation("   ", target: "zh-Hans"), "空行不翻译")
        check(!TranslationRules.needsTranslation("12345", target: "zh-Hans"), "纯数字不翻译")
        check(!TranslationRules.needsTranslation("( )", target: "zh-Hans"), "纯符号不翻译")

        // 5. Only the necessary lines go into the batch.
        let lines = ["Hello", "你好", "♪", "こんにちは", "안녕"]
        let indices = TranslationRules.translatableIndices(lines: lines, target: "zh-Hans")
        check(indices == [0, 3, 4], "只送翻非中文且含语言信息的行")

        // 6. Sparse responses are merged back onto their original line index.
        let merged = TranslationRules.merged(lineCount: 5, indices: [0, 3, 4],
                                             translated: ["你好", "你好", "你好"])
        check(merged == ["你好", "", "", "你好", "你好"], "译文按原行号回填")
        let safe = TranslationRules.merged(lineCount: 2, indices: [0, 9],
                                           translated: ["A", "B"])
        check(safe == ["A", ""], "越界行号被忽略")

        // 7. Cache keys are stable, and change with both content and target.
        let a = TranslationRules.cacheKey(lines: lines, target: "zh-Hans")
        let b = TranslationRules.cacheKey(lines: lines, target: "zh-Hans")
        let c = TranslationRules.cacheKey(lines: lines, target: "en-US")
        let d = TranslationRules.cacheKey(lines: lines + ["Bye"], target: "zh-Hans")
        check(a == b, "同样的歌词与目标得到同一个缓存键")
        check(a != c, "目标语言改变会换缓存键")
        check(a != d, "歌词改变会换缓存键")
        check(a.count == 16, "缓存键是定长十六进制")

        // 8. Missing keys in an older saved settings blob keep the rest.
        let partial = "{\"enabled\":true,\"targetLanguage\":\"ja-JP\"}"
        if let data = partial.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(TranslationSettings.self, from: data) {
            check(decoded.enabled, "旧设置里的开关被保留")
            check(decoded.targetLanguage == "ja-JP", "旧设置里的目标语言被保留")
            check(decoded.relativeSize == 0.62, "新增字号项取默认值")
            check(!decoded.keepNextLine, "新增下一句项取默认值")
        } else {
            check(false, "旧设置可解码")
        }
        check(TranslationSettings.targets.contains { $0.id == "zh-Hans" }, "目标语言含简体中文")

        // 9. Cache size label and the strict whitelist used when clearing.
        check(TranslationRules.formattedCacheSize(0) == "0 B", "空缓存显示 0 B")
        check(TranslationRules.formattedCacheSize(512) == "512 B", "不足 1 KB 用 B")
        check(TranslationRules.formattedCacheSize(2048) == "2 KB", "KB 取整")
        check(TranslationRules.formattedCacheSize(1_572_864) == "1.5 MB", "MB 保留一位小数")
        check(TranslationRules.isCacheFile("0123456789abcdef.json"), "合法缓存文件名")
        check(TranslationRules.isCacheFile(
            TranslationRules.cacheKey(lines: ["Hello"], target: "zh-Hans") + ".json"),
              "缓存键生成的文件名可被识别")
        check(!TranslationRules.isCacheFile("notes.json"), "同名目录里的其它 json 不清理")
        check(!TranslationRules.isCacheFile("0123456789abcdef.txt"), "非 json 不清理")
        check(!TranslationRules.isCacheFile("0123456789abcde.json"), "键长度不对不清理")
        check(!TranslationRules.isCacheFile("../secret.json"), "路径穿越不清理")

        print("翻译规则自检通过：\(passed) 项")
    }
}
