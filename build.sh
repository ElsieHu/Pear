#!/bin/bash
# 编译并把 Pear 打包成可直接双击运行的 .app
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$PROJECT_DIR/dist/Pear.app"
CONTENTS="$APP_DIR/Contents"

# Build intermediates live on the system volume by default: SwiftPM and
# iconutil create (and delete) temp directories next to their output, and on
# an external volume that cleanup can be blocked. Set TMPDIR too so nothing
# spills onto /Volumes.
BUILD_DIR="${PEAR_BUILD_DIR:-$HOME/.cache/Pear}"
mkdir -p "$BUILD_DIR"
export TMPDIR="${TMPDIR:-/var/folders/tmp-pear}"
mkdir -p "$TMPDIR" 2>/dev/null || TMPDIR=/tmp
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# ---- SDK compatibility ----
# Some Command Line Tools releases (SDK 27+) declare SwiftUI's @State as a
# macro, but ship no SwiftUIMacros plugin. Then *every* SwiftUI file fails to
# compile with "external macro implementation type ... not found" (and a
# cascade of misleading "self is immutable" errors). Prefer the last SDK where
# @State is still a property wrapper when one is installed.
# Override with PEAR_SDK=/path/to/SDK, or PEAR_SDK=default to
# force the system default (e.g. when using a full Xcode toolchain).
SDK_DIR="${PEAR_SDK:-}"
if [ -z "$SDK_DIR" ]; then
    CLT_SDKS="/Library/Developer/CommandLineTools/SDKs"
    for candidate in MacOSX26.5.sdk MacOSX26.sdk; do
        if [ -d "$CLT_SDKS/$candidate" ]; then
            SDK_DIR="$CLT_SDKS/$candidate"
            break
        fi
    done
fi
if [ -n "$SDK_DIR" ] && [ "$SDK_DIR" != "default" ] && [ -d "$SDK_DIR" ]; then
    export SDKROOT="$SDK_DIR"
    echo "==> 使用 SDK: $SDK_DIR (绕开 SwiftUIMacros 插件缺失)"
fi

echo "==> 编译 (release)"
cd "$PROJECT_DIR"
# Where SwiftPM keeps intermediates. Overridable because building on an
# external volume occasionally cannot clear SwiftPM's own temp directories
# under /Volumes — pointing the scratch path elsewhere works around it.
SCRATCH="${PEAR_SCRATCH:-$BUILD_DIR/swiftpm}"
BUILD_LOG="$BUILD_DIR/swift_build.log"
SANDBOX_FLAG=""
if ! swift build -c release --scratch-path "$SCRATCH" >"$BUILD_LOG" 2>&1; then
    # SwiftPM compiles Package.swift through sandbox-exec. Some restricted
    # shells forbid nested sandboxing ("sandbox_apply: Operation not
    # permitted"), which shows up as a bogus "Invalid manifest" error. Retry
    # with SwiftPM's own sandbox disabled — still a plain local build.
    # (BSD grep needs -E for alternation; plain `\|` silently never matches.)
    if grep -qE "sandbox_apply|sandbox-exec" "$BUILD_LOG"; then
        echo "    SwiftPM 清单沙箱不可用，改用 --disable-sandbox 重试"
        SANDBOX_FLAG="--disable-sandbox"
        if ! swift build -c release --scratch-path "$SCRATCH" $SANDBOX_FLAG \
                >"$BUILD_LOG" 2>&1; then
            tail -30 "$BUILD_LOG"
            exit 1
        fi
    else
        tail -30 "$BUILD_LOG"
        exit 1
    fi
fi
tail -20 "$BUILD_LOG"

BIN="$(swift build -c release --scratch-path "$SCRATCH" $SANDBOX_FLAG --show-bin-path)/PearApp"
if [ ! -f "$BIN" ]; then
    echo "!! 找不到可执行文件: $BIN"
    exit 1
fi

echo "==> 自检歌词匹配规则"
# Why not `swift test`: this machine has only the Command Line Tools — XCTest
# is absent and swift-testing's lib_TestingInterop.dylib is missing, so the
# test bundle cannot even be launched. This self-check compiles the matching
# rules standalone and runs on every build, which is what actually keeps the
# "wrong song's lyrics" bug from coming back.
VERIFY_BIN="$BUILD_DIR/verify_match"
VERIFY_LOG="$BUILD_DIR/verify_build.log"
if swiftc -O "$PROJECT_DIR/Sources/AppleMusicBridge/LyricMatch.swift" \
        "$PROJECT_DIR/tools/verify_match.swift" \
        -o "$VERIFY_BIN" >"$VERIFY_LOG" 2>&1; then
    # `set -e` + a failing check must abort the build, not print and continue.
    if ! "$VERIFY_BIN"; then
        echo "    ! 匹配规则自检未通过，已中止构建"
        exit 1
    fi
else
    echo "    ! 自检程序编译失败："
    tail -5 "$VERIFY_LOG"
    exit 1
fi

echo "==> 自检歌词时间轴(尾奏裁剪)"
VERIFY_TIMELINE_BIN="$BUILD_DIR/verify_timeline"
VERIFY_TIMELINE_LOG="$BUILD_DIR/verify_timeline_build.log"
if swiftc -O "$PROJECT_DIR/Sources/LyricEngine/LyricModels.swift" \
        "$PROJECT_DIR/Sources/LyricEngine/LyricHighlight.swift" \
        "$PROJECT_DIR/tools/verify_timeline.swift" \
        -o "$VERIFY_TIMELINE_BIN" >"$VERIFY_TIMELINE_LOG" 2>&1; then
    if ! "$VERIFY_TIMELINE_BIN"; then
        echo "    ! 时间轴自检未通过，已中止构建"
        exit 1
    fi
else
    echo "    ! 时间轴自检程序编译失败："
    tail -5 "$VERIFY_TIMELINE_LOG"
    exit 1
fi

echo "==> 自检配色对比度规则"
VERIFY_CONTRAST_BIN="$BUILD_DIR/verify_contrast"
VERIFY_CONTRAST_LOG="$BUILD_DIR/verify_contrast_build.log"
if swiftc -O "$PROJECT_DIR/Sources/PearApp/ColorContrast.swift" \
        "$PROJECT_DIR/tools/verify_contrast.swift" \
        -o "$VERIFY_CONTRAST_BIN" >"$VERIFY_CONTRAST_LOG" 2>&1; then
    if ! "$VERIFY_CONTRAST_BIN"; then
        echo "    ! 配色对比度自检未通过，已中止构建"
        exit 1
    fi
else
    echo "    ! 配色对比度自检程序编译失败："
    tail -5 "$VERIFY_CONTRAST_LOG"
    exit 1
fi

echo "==> 自检封面两色提取"
VERIFY_PALETTE_BIN="$BUILD_DIR/verify_palette"
VERIFY_PALETTE_LOG="$BUILD_DIR/verify_palette_build.log"
if swiftc -O "$PROJECT_DIR/Sources/PearApp/ColorContrast.swift" \
        "$PROJECT_DIR/Sources/PearApp/ColorPalette.swift" \
        "$PROJECT_DIR/tools/verify_palette.swift" \
        -o "$VERIFY_PALETTE_BIN" >"$VERIFY_PALETTE_LOG" 2>&1; then
    if ! "$VERIFY_PALETTE_BIN"; then
        echo "    ! 两色提取自检未通过，已中止构建"
        exit 1
    fi
else
    echo "    ! 两色提取自检程序编译失败："
    tail -5 "$VERIFY_PALETTE_LOG"
    exit 1
fi

echo "==> 生成图标"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
if [ ! -f "$BUILD_DIR/make_icon" ] || [ "$PROJECT_DIR/tools/make_icon.swift" -nt "$BUILD_DIR/make_icon" ]; then
    swiftc -O "$PROJECT_DIR/tools/make_icon.swift" -o "$BUILD_DIR/make_icon"
fi
"$BUILD_DIR/make_icon" "$ICONSET"
rm -f "$APP_DIR/Contents/Resources/AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"

echo "==> 组装 .app"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN" "$MACOS/PearApp"
cp "$BUILD_DIR/AppIcon.icns" "$RESOURCES/AppIcon.icns"
chmod +x "$MACOS/PearApp"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Pear</string>
    <key>CFBundleDisplayName</key>
    <string>Pear</string>
    <key>CFBundleIdentifier</key>
    <string>local.pear</string>
    <key>CFBundleExecutable</key>
    <string>PearApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>需要读取“音乐”当前播放的曲目与播放进度，以便同步显示 Apple Music 歌词。</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> 签名"
# Why a fixed self-signed identity instead of ad-hoc
# ------------------------------------------------
# macOS keys TCC ("自动化") authorisation on the code signature. With an
# ad-hoc signature every rebuild produces a new cdhash, so macOS treats the
# app as brand new and you have to re-allow “控制‘音乐’” after *every* build.
# Signing with one stable identity means you grant it once, forever.
SIGN_KEYCHAIN="${PEAR_SIGN_KEYCHAIN:-}"
SIGN_IDENTITY="${PEAR_SIGN_IDENTITY:-Pear Dev}"
SIGN_PASSWORD="${PEAR_SIGN_PASSWORD:-pear}"

# Unlock a keychain and print its first codesigning identity, if there is one.
# Unlocking *before* querying matters: a locked keychain reports no identity,
# which silently degrades the build to ad-hoc.
unlock_and_find() {
    [ -f "$1" ] || return 1
    security unlock-keychain -p "$SIGN_PASSWORD" "$1" >/dev/null 2>&1 || true
    local found
    found=$(security find-identity -p codesigning "$1" 2>/dev/null \
            | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$found" ] || return 1
    printf '%s' "$found"
}

# Rather than hard-coding one keychain filename and certificate name, discover
# whichever keychain actually holds a usable identity. Two details bite here:
# `security create-keychain` writes `*.keychain-db` on modern macOS (so a
# `*.keychain` glob matches nothing), and a machine upgraded from an earlier
# build still has its previous dedicated keychain + certificate — reusing it
# keeps the same cdhash, so the 「自动化」 authorisation survives the rename.
if [ -n "$SIGN_KEYCHAIN" ]; then
    if FOUND=$(unlock_and_find "$SIGN_KEYCHAIN"); then
        SIGN_IDENTITY="$FOUND"
    fi
else
    for kc in "$HOME"/Library/Keychains/Pear.keychain-db \
              "$HOME"/Library/Keychains/Pear.keychain \
              "$HOME"/Library/Keychains/*.keychain-db \
              "$HOME"/Library/Keychains/*.keychain; do
        [ -f "$kc" ] || continue
        case "$kc" in *.sb-*) continue ;; esac   # sandbox shards, not keychains
        FOUND=$(unlock_and_find "$kc") || continue
        SIGN_KEYCHAIN="$kc"
        if [ "$FOUND" != "$SIGN_IDENTITY" ]; then
            echo "    沿用已有的开发签名身份: $FOUND  ($(basename "$kc"))"
        fi
        SIGN_IDENTITY="$FOUND"
        break
    done
fi

if security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    # Two things codesign needs that are easy to miss:
    # 1. It searches the keychain *search list*, not the --keychain path, so
    #    ours has to be in the list (keep login/system too — a list with only
    #    ours also fails with errSecInternalComponent).
    # 2. The key re-locks between sessions, and the partition list has to be
    #    re-applied or codesign fails with errSecInternalComponent despite the
    #    identity being visible to find-identity.
    security set-key-partition-list \
        -S apple-tool:,apple:,codesign: -s -k "$SIGN_PASSWORD" "$SIGN_KEYCHAIN" >/dev/null 2>&1
    security list-keychains -d user -s \
        "$SIGN_KEYCHAIN" \
        "$HOME/Library/Keychains/login.keychain-db" \
        /Library/Keychains/System.keychain >/dev/null 2>&1

    # `set -e` aborts on `VAR=$(failing command)`, so put codesign in the
    # condition instead of capturing `$?` — otherwise a failure silently
    # skips both the message and the ad-hoc fallback.
    if SIGN_OUT=$(codesign --force --deep --sign "$SIGN_IDENTITY" \
            --keychain "$SIGN_KEYCHAIN" --timestamp=none "$APP_DIR" 2>&1); then
        echo "    已用固定身份签名：$SIGN_IDENTITY  (授权只需给一次)"
    else
        echo "    ! 固定身份签名失败: $SIGN_OUT"
        echo "      回退 ad-hoc —— 下次重建后需重新允许“自动化”"
        codesign --force --deep --sign - "$APP_DIR" 2>&1 | tail -3
    fi
else
    echo "    未找到固定签名身份，回退 ad-hoc"
    echo "    跑一次 ./tools/setup_signing.sh 可让授权只需给一次"
    codesign --force --deep --sign - "$APP_DIR" 2>&1 | tail -3
fi

echo "==> 完成: $APP_DIR"

# ---- 安装到 Applications ----
# 默认装到标准应用目录 /Applications；可用 PEAR_INSTALL_DIR 覆盖到
# 任意位置（例如外置盘）。目标目录不存在时不要连构建一起失败，只是把产物
# 留在 dist/ 并提示。
INSTALL_DIR="${PEAR_INSTALL_DIR:-/Applications}"
if [ "$1" = "--no-install" ]; then
    echo "==> 跳过安装 (--no-install)"
elif [ ! -d "$INSTALL_DIR" ]; then
    echo "!! 安装目录不存在：$INSTALL_DIR"
    echo "   目标目录不存在（如外置盘未挂载），产物留在 $APP_DIR"
else
    echo "==> 安装到 $INSTALL_DIR"
    TARGET="$INSTALL_DIR/Pear.app"
    BIN_PATH="$TARGET/Contents/MacOS/PearApp"
    WAS_RUNNING=0
    # 旧版本正在跑的话必须先退出，否则会留下指向已删除文件的僵尸进程
    if pgrep -fx "$BIN_PATH" >/dev/null 2>&1; then
        WAS_RUNNING=1
        pkill -x -f "$BIN_PATH" >/dev/null 2>&1
        sleep 1
    fi
    rm -rf "$TARGET"
    # 同一块 APFS 卷上复制：只改目录项，签名与 TCC 授权都原样保留
    cp -R "$APP_DIR" "$TARGET"
    if codesign --verify --deep --strict "$TARGET" >/dev/null 2>&1; then
        echo "    已安装并校验签名：$TARGET"
    else
        echo "    ! 安装后签名校验失败，请检查：codesign -vv --deep $TARGET"
    fi
    if [ "$WAS_RUNNING" = "1" ]; then
        open "$TARGET"
        echo "    已重新启动"
    fi
fi

echo "    首次运行需要在「系统设置 ▸ 隐私与安全性 ▸ 自动化」允许控制“音乐”（只需一次）。"
