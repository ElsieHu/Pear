# LyricFeverDirect — 直接对接 Apple Music 的单行歌词浮窗

> 目标：像 Lyric Fever 那样提供常驻屏幕的紧凑歌词胶囊，但**歌词直接取自 Apple Music 当前播放曲目自己的歌词数据**，而不是像 Lyric Fever 那样通过外部歌词库匹配获取。

---

## 一、市场调研结论

| 软件 | 支持 Apple Music | 紧凑浮窗 | 歌词是否为 **Apple Music 自有歌词** |
|---|---|---|---|
| **Lyric Fever** | ✅ | ✅ | ❌ **否** — 歌词来自 Spotify / LRCLIB / NetEase；对 Apple Music 曲目是「取 iTunes ID → 映射 ISRC → 转成 Spotify 曲目 ID → 取 Spotify 歌词」 |
| **LyricsX** / **Lyrimuse** / **Dynamic Lyrics** / **LyricGlow** | ✅ | ✅ | ❌ 否 — 网易云 / QQ / 酷狗 / LRCLIB / Musixmatch 多源匹配 |
| **Takpap/apple-music-lyrics**（MIT） | ✅ | ⚠️ 浮窗偏大 | ✅ 是 — 读 Apple Music 本地缓存，但 UI 为 AppKit 自绘，样式定制成本高 |

**结论**：Lyric Fever 恰好不满足需求 #1（外部匹配），而唯一"直接读 Apple Music"的开源项目 UI 又偏大、不好定制。因此自建：**数据层直连 Apple Music，UI 层做成可完全自定义的单行胶囊**。

---

## 二、目标平台

- **macOS 13+**（Apple Silicon / Intel 通用）
- 依赖系统「音乐」App；需要 **Apple Music 订阅**（同步歌词仅对订阅者开放）
- **Swift 6 + SwiftUI + AppKit**，SwiftPM 组织，**零第三方依赖**
- **不需要 Xcode，不需要付费开发者账号**

---

## 三、核心功能

1. **歌词直连 Apple Music（核心差异点）**
   读取「音乐」App 自己下载好的歌词缓存
   `~/Library/Caches/com.apple.Music/fsCachedData/`，
   取出官方 TTML 同步歌词（逐行 / 逐字时间轴）。
   **完全不访问** Spotify / LRCLIB / 网易云 / QQ；Apple Music 没缓存就如实提示。

2. **单行紧凑胶囊浮窗**
   只显示当前这一行，窗口宽度**随文字自动伸缩**（短句就是小胶囊，不是固定大框）。
   常驻最上层、跨所有虚拟桌面、不抢焦点、可拖动、可选点击穿透。

3. **完整外观自定义**（偏好设置）
   字体（全系统字体）、字号 12–64pt、字重、对齐方式、
   文字色 / 高亮色 / 背景色、未唱部分不透明度、
   背景不透明度、圆角、左右/上下内边距、最大宽度、
   是否显示下一句、扫光开关、投影、悬停淡出、锁定位置、点击穿透。
   另附 8 组配色预设（霓虹紫 / 莓果粉 / 深海蓝 / 薄荷青 / 曜石黑 / 云雾白 / 落日橙 / 森野绿）。

4. **实时同步**：AppleScript 读 `player position` 作锚点（250ms），本地插值平滑推进；左→右扫光高亮。
   重绘频率自适应：播放中且开扫光 60fps、播放中不开扫光 20fps、暂停 10fps。
   换句时旧行上移淡出、新行从下淡入，胶囊宽度同步以 0.26s 缓动伸缩（不再瞬间跳变）。

5. **菜单栏「正在播放」面板** — 点菜单栏图标弹出：
   专辑封面 + 歌名 + 艺人·专辑 + 上一首/播放暂停/下一首 + 可拖动进度条(已播/-剩余)。
   下方是功能行：浮动歌词 / 锁定 / 鼠标穿透 / 刷新歌词 / 诊断日志 / 偏好设置 / 退出。
   全局快捷键 `⌃⌥L` 开关浮窗、`⌃⌥K` 锁定位置（不需要 App 处于前台）。
   菜单栏本身显示什么可在「偏好设置 ▸ 菜单栏」里自由组合：**图标 / 歌曲名 / 歌手名**
   任意单选或多选（默认只显示图标）；三项全关时会自动保留图标，避免入口消失。

6. **自动捕捉专辑封面配色**
   - `专辑配色`（默认）：用 Apple 自己为封面算好的 `bgColor` + `textColor1` 配对，离线即时生效，对比度由 Apple 保证。
   - `封面取色`：下载封面图，缩到 48×48 后量化取主色（按频次 × 饱和度打分，跳过近黑/近白）。
   - `手动`：用预设或自定义颜色。
   过亮的封面会自动压暗，太暗会自动提亮，保证歌词始终可读。

7. **App 图标** — `tools/make_icon.swift` 用 Core Graphics 现画（紫色渐变圆角方块 + 三行歌词条，中间一条带扫光），`iconutil` 打成 `.icns`，无需 Xcode。

---

## 四、实现要点

### 4.1 模块划分

```
LyricEngine              纯逻辑，无 UI / 无网络
  ├ LyricModels          LyricSegment / LyricLine / TimedLyrics
  ├ TTMLParser           Apple Music TTML → 时间轴
  ├ LRCParser            LRC / 增强 LRC
  └ LyricHighlight       当前行索引、行进度、逐字进度

AppleMusicBridge         与「音乐」App 对接
  ├ AppleMusicMonitor              当前曲目 + 播放进度 + 状态
  ├ AppleMusicCacheLyricsSource    ★ 读本地缓存（默认，零 token）
  └ AppleMusicLyricsSource         公开 MusicKit Web API（可选，需开发者账号）

LyricFeverDirectApp      SwiftUI + AppKit 界面层
  ├ KaraokePanel         自适应尺寸浮窗
  ├ KaraokeView          单行胶囊 + 扫光
  ├ LyricAppearance      全部外观项 + 预设 + 持久化
  ├ AppState             状态编排
  └ StatusBarController / SettingsView
```

### 4.2 为什么读本地缓存就是「直连 Apple Music」

Apple **没有**通过任何公开 MusicKit API 提供歌词正文——这正是所有竞品不得不去匹配第三方歌词库的根因。

但「音乐」App 自己会把播放过的曲目歌词以官方 TTML 形式缓存到本机：

```
fsCachedData/<UUID>   （JSON，Apple Music API 原始响应）
└── data[0]
    ├── id / type:"songs"
    ├── attributes { name, artistName, albumName, durationInMillis, hasTimeSyncedLyrics }
    └── relationships
        └── syllable-lyrics
            └── data[0].attributes.ttmlLocalizations   ← 官方 TTML 歌词全文
```

本项目扫描该目录，按 **曲名 + 艺人 + 时长** 打分匹配当前曲目（阈值严格，绝不串歌），
再用自研 `TTMLParser` 解析成时间轴。**全程不联网、不用 token、不碰第三方歌词库**。

TTML 有两种形态，解析器都支持：
- `itunes:timing="Word"`：`<p>` 内含 `<span begin end>` 逐字；
- `itunes:timing="Line"`：`<p begin end>` 直接带文字（中文曲库大量是这种）。
时间格式同时兼容 `1.2s` 与 `00:01:05.855`。

### 4.3 浮窗自适应尺寸

`NSPanel` 内放 `NSHostingView`，每 250ms 读一次 `fittingSize`，
若与当前 frame 差异 >0.5pt 就重新 setFrame（保持水平中心不动，0.18s 动画）。
窗口位置写入 `UserDefaults`，可一键重置。

### 4.4 设置窗口滚动卡顿的排查与修复

原实现有三个叠加的成因，都已修掉：

| 成因 | 说明 | 修复 |
|---|---|---|
| **每 250ms 无条件发布** | `@Published` 在**每次赋值**都会触发 `objectWillChange`，即使值没变。`monitor` 的轮询把 `isPlaying` 每 250ms 重设一遍 → 整个设置窗口每秒重建 4 次 | 加 `setPlaying/setTrack`，只在值真的改变时才赋值 |
| **`ScrollView { Form { … } }` 嵌套** | `Form` 本身就会滚动，外面再套一层 `ScrollView` 会形成尺寸反馈循环 | 去掉外层 `ScrollView`，只留 `Form` |
| **body 里直接读 `smoothPosition`** | 该值每帧都在变，会让整个 Form 失效重算 | 放进 `TimelineView(.periodic(by: 0.5))`，只让那一行失效；`LazyVGrid` 也给了固定高度，避免反复测量 |

另外设置窗口的 `NSHostingView` 已开启 `wantsLayer`（非 layer-backed 窗口里的 vibrancy Form 滚动会明显掉帧）。

关键窗口配置：

| 配置 | 作用 |
|---|---|
| `styleMask: .nonactivatingPanel` | 永不抢焦点 |
| `level = .mainMenu` | 浮于普通窗口之上 |
| `.canJoinAllSpaces / .fullScreenAuxiliary` | 所有桌面 / 全屏空间可见 |
| `isMovableByWindowBackground` | 可拖动（锁定时关闭） |
| `ignoresMouseEvents` | 可选点击穿透 |
| `hasShadow = false` | 由 SwiftUI 画胶囊投影（AppKit 阴影会跟矩形窗口走） |

---

## 五、构建与运行

```bash
cd LyricFeverDirect
./build.sh          # 编译 release + 打包 + 固定身份签名 + 安装到 Applications
./build.sh --no-install   # 只打包，产物留在 dist/
```

每次构建会先跑一遍歌词匹配规则自检（`tools/verify_match.swift`，
验证"同艺人的另一首歌不会被当成当前曲目"等 10 条规则），
任一条不通过即中止构建。

产物：`dist/LyricFeverDirect.app`；脚本默认会**自动安装**到
`/Volumes/三星2T/Applications/LyricFeverDirect.app`（换位置用
`LYRIC_FEVER_INSTALL_DIR=/Applications ./build.sh`）。同一块 APFS 卷上移动/复制
只改目录项，签名与「自动化」授权都原样保留，**不会重新弹权限窗**。

### 首次运行需做两件事

1. **「自动化」授权**：弹窗中选择"允许"本应用控制「音乐」。
   若误点拒绝：系统设置 ▸ 隐私与安全性 ▸ 自动化 ▸ 勾选本应用。
   （设置页里有直达按钮）
2. **播放一首 Apple Music 曲库里的歌**，并在「音乐」里打开一次歌词面板。
   歌词是 Music 首次展示时下载的，缓存出现后浮窗 2 秒内自动跟上（会持续重试，无需手动刷新）。

> 本地导入的音频文件没有 Apple Music 官方歌词，会如实提示——这是设计要求，不偷换外部源。

### 可选：启用 MusicKit Web API

设置里打开 `useMusicKitAPI` 会额外尝试公开 MusicKit 接口作为补充来源。
这需要 **Apple Developer Program 会员**（付费）并配置 MusicKit App Service，否则返回 401。
默认关闭，不影响主流程。

---

## 六、已验证内容

在目标机器上用**真实数据**完成端到端验证：

- ✅ `swift build` / `swift build -c release` 全部 target 编译通过
- ✅ `dist/LyricFeverDirect.app` 打包 + **固定身份签名**（`LyricFeverDirect Dev`），实机启动后进程存活、无崩溃
- ✅ 本地缓存扫描：识别出 5 首带歌词的曲目（彗星守望者 / 流浪的小行星圆舞曲 / 悟不空 / 父亲写的散文诗 / 不红）
- ✅ 曲目匹配：《父亲写的散文诗 — 许飞》正确命中 `id=6805417004`
- ✅ TTML 解析：26 行，时间轴正确（如 `15.09→20.80 一九八四年 庄稼还没 收割完`）
- ✅ 进度计算：行中点进度 = 0.50；`lines[3].start + 0.1` → 行索引 3
- ✅ 修复真实 bug：行级歌词（无 `<span>`）原先会丢掉整行文字，现已修好

---

## 六之二、故障排查（排障第一站：日志文件）

应用会在 `~/Library/Logs/LyricFeverDirect.log` 写运行日志；
菜单栏 ▸ 「诊断日志」里也会直接显示最后 12 行。

| 日志里看到 | 含义 | 怎么办 |
|---|---|---|
| `拿不到当前曲目 … 自动化未允许` | 未授权控制「音乐」 | 系统设置 ▸ 隐私与安全性 ▸ 自动化 ▸ 允许；或菜单栏 ▸ 「⚠︎ 允许控制"音乐"」 |
| `来源=MediaRemote(未获自动化授权)` | 没授权，但已通过 MediaRemote 读到曲目 | 可正常使用；只是播放控制（上一首/播放/下一首）不可用 |
| `未命中 (第 N 次) … 缓存曲目数=…` | 缓存里还没有这首歌 | 自动退避重试，Music 一写入就立刻跟上，无需手动刷新 |
| `Apple Music 目录内无同步歌词, 停止重试` | Apple 曲库本身就没有这首歌的同步歌词 | 换一首；本应用**不**回退外部歌词源 |
| 进程启动后立刻消失 | 大概率崩溃 | 看 `~/Library/Logs/DiagnosticReports/LyricFeverDirectApp-*.ips` |

### 为什么每换一首歌都要手动刷新（已修复）

三个原因叠加，前两个是真 bug：

1. **主线程被 AppleScript 吃满**：旧实现每 0.25s 同步 spawn 两次 `osascript`
   （`player state` + `player position`），即每秒 8 个进程，全部在主线程
   `waitUntilExit()` 阻塞。主线程饱和后取词循环根本排不上队。
   → 改为「合并成 1 次调用 + 1Hz + 专用后台串行队列」。
2. **只在切歌瞬间取一次**：而 Music 是**异步**写入歌词缓存的，切歌那一刻
   往往还没有。→ 改为「监听缓存目录（vnode，写入即触发）+ 斐波那契退避重试」，
   并区分「还没写到」和「Apple 曲库根本没有」——后者停止重试，不空转。
3. **每次重新打包 = 新的 ad-hoc 签名 = TCC 当新 App**，于是每次都要重新授权
   「自动化」。→ `tools/setup_signing.sh` 建一个固定自签名身份，`build.sh`
   用它签名，授权只需一次。

### 已授权却仍提示「没授权」（已修复）—— AppleScript 变量名撞车

最隐蔽的一个：日志一直刷「仍无曲目 (自动化授权可能未授予)」，但系统设置里
「音乐」开关明明是**开**的。真凶是脚本里的变量名 **`st`**：

```applescript
set st to (player state as text)   -- ❌ 编译不过
```

`st` 与「音乐」的 AppleScript 字典里的词冲突，`osascript` 直接以
`script error 预期是表达式，却找到"st" (-2741)` 退出。**整段脚本编译失败 →
`read()` 返回 nil → 表现和「没授权」一模一样**。已逐个验证过：`pp / nm / ar /
al / du / pid / t` 都安全，只有 `st` 会撞（现改名 `pstate`）。

顺带修的两处：

* `MusicScript.run` 以前**丢弃 stderr**，脚本报错完全静默。现在捕获 stderr
  并交给 `diagnosticHandler`（相同消息去重，避免 1Hz 轮询刷屏），日志里直接
  看到 `-10004 权限违例` / `-2741 语法错误`，不用再猜。
* `build.sh` 里 `codesign … | tail -3` 判断的是 `tail` 的退出码，**永远为 0**，
  签名失败也被报成成功（实际静默回退 ad-hoc，等于每次重建都要重新授权）。
  改为先取 `$?` 再判断。

### 「居中」无效、每行歌词都从左边缘长出（已修复）

现象：设置里选了「居中」，但新歌词出现时胶囊总是以**左边缘**为基准伸缩。

根因不在对齐代码，而在**窗口尺寸是谁改的**。实测日志：

```
refit进入: frameW=107 fittingW=107      ← 每个 tick 都完全相等
refit进入: frameW=185 fittingW=185
refit进入: frameW=195 fittingW=195
```

`KaraokePanel.refit()` 每次都发现 `frame.size == hosting.fittingSize`，于是
**调整分支一次都没执行过**。窗口其实一直由 AppKit 自己按 `NSHostingView`
的理想尺寸自适应，而这个自适应**保持 frame origin 不变** —— 也就是左边缘钉死。
所以 `refit()` 里那套"保持中心"的逻辑是**死代码**。

修法：不与机制对抗，改为监听 `NSWindow.didResizeNotification`，在宽度变化后
把原点补回来（居中补 Δw/2，右对齐补 Δw，左对齐不补）：

```
修正前 midX: 1040 → 1134 → 1080 → 1100 → 1194   （乱跳）
修正后 midX: 1097 → 1096 → 1096 → 1095 → 1095   （钉住）
```

拖动窗口不改变尺寸，所以用户拖出来的中心会被完整保留；之后每行歌词都以
该点为中心对称伸缩。

### 封面与专辑取色不生效（已修复）

`resolveArtwork()` 只在**切歌那一瞬**取一次，而歌词缓存是 Music **异步**
写入的 —— 第一次往往扑空。歌词路径有退避重试所以最终能出现，**封面/配色
路径没有重试**，于是永久停在默认值（`#6E44FF`）。

→ 在 `watchTrackChanges` 的两条分支里都补上：`if currentArtwork == nil { resolveArtwork() }`。
顺带把 `AppleMusicCacheLyricsSource.scan()` 加了 2 秒记忆化 —— 原来一次切歌
会全量重扫缓存目录 3～4 遍。

### 菜单栏面板的播放/暂停图标不刷新（已修复）

`NowPlayingView` 观察的是 `AppState`，却读 `state.monitor.isPlaying`。
而 `monitor` 是**另一个** `ObservableObject` —— 它的 `@Published` 变化不会
通知到观察 `AppState` 的视图。图标只在别的 `@Published`（比如 `lyrics`）
恰好变化时"顺带"刷新。

→ 在 `AppState.start()` 里把 `monitor.objectWillChange` 中继成
`self.objectWillChange.send()`，所有读 `state.monitor.*` 的视图都能正确刷新。

### 反复弹出的权限窗口（已修复）—— 两个弹窗，两个根因

用户报告两个弹窗反复出现，它们**都不是**「自动化」授权：

| 弹窗 | 真凶 |
|---|---|
| “**codesign** 想使用 **LyricFeverDirect** 钥匙串” | `build.sh` 签名时钥匙串 ACL 没生效 |
| “**LyricFeverDirect.app** 想访问 **Apple Music**、你的音乐与视频活动以及你的媒体资料库” | **MediaRemote** 私有框架，不是 Apple Events |

**① Apple Music 媒体资料库弹窗 —— 删掉 MediaRemote**

当初加 `MediaRemoteBridge` 是想让它做免授权备份通道。但两个实测否掉了它：

* 在当前的 macOS 上 `MRMediaRemoteGetNowPlayingInfo` **即使正在播放也返回 nil**，
  从来没贡献过任何数据；
* 每秒调一次 → 系统反复弹「想访问 Apple Music…媒体资料库」的授权框。

`MediaRemoteBridge.swift` 已删除，`mergedSnapshot()` 改为只走 AppleScript。
顺带给 `MusicPoller` 加了失败退避（连续失败 3 次降到 5s、6 次降到 15s），
避免授权缺失时空转。

**② codesign 钥匙串弹窗**

即使 `find-identity` 看得到身份，`codesign` 仍会要求钥匙串密码，除非
**每次签名前重跑 `security set-key-partition-list`**（会话之间钥匙串会重新上锁）。
`build.sh` 现在每次都会做这件事，并把 `login.keychain-db` 与 `System.keychain`
一起保留在搜索列表里（只放自己的钥匙串同样会失败）。

### Swift 6 并发踩坑（记在这里，别再踩）

* 在 `@MainActor` 方法里写给 `DispatchSource.setEventHandler` /
  `DispatchQueue.async` 的闭包，会**继承 main-actor 隔离**（这些 API 的参数
  并非 `@Sendable`）。把它交给后台队列执行 → `EXC_BREAKPOINT`
  (`_swift_task_checkIsolatedSwift`)。解法：这类 GCD 代码放进**不带任何
  actor 隔离**的类型（本项目是 `MusicPoller`），回调参数显式标注
  `@Sendable`，回主 actor 一律 `Task { @MainActor in … }`。
* `FileHandle(forWritingAtPath:)` 会 **截断** 文件，日志会只剩最后一行；
  追加要用 `FileHandle(forUpdatingAtPath:)`。
* `security` 对**含中文的路径**找不到钥匙串 → 钥匙串放在
  `~/Library/Keychains/` 下。另外钥匙串会话结束会锁定，`find-identity`
  前必须先 `unlock-keychain`；`codesign` 还要求钥匙串在搜索列表里，
  且**每次都要重跑 `set-key-partition-list`**，否则即使 `find-identity`
  看得到身份，`codesign` 仍报 `errSecInternalComponent`。
* `set -e` 下 `VAR=$(可能失败的命令)` 会**直接退出脚本**，后面的错误提示和
  ad-hoc 回退都不会执行。要把命令放进 `if VAR=$(...); then` 的条件里。

---

## 七、已知限制

- 依赖「音乐」App 的私有缓存格式，macOS 大版本更新后可能需要适配。
- 歌曲必须先被 Music 缓存过歌词（打开过歌词面板）才会显示。
- 使用私有缓存路径，**不能上架 Mac App Store**（个人使用无碍）。
- AppleScript 读取播放位置存在约 0.1–0.3s 固定延迟，若觉得扫光偏早/偏晚，可后续加 offset 微调。

## 八、后续可扩展

- 歌词偏移微调（全局 / 单曲）
- 按曲目持久化缓存，历史歌曲秒开
- 端侧翻译 → 双语字幕
- 封面取色自动配色
- 全屏歌词视图
