#!/bin/bash
# 编译并把 LyricFeverDirect 打包成可直接双击运行的 .app
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$PROJECT_DIR/dist/LyricFeverDirect.app"
CONTENTS="$APP_DIR/Contents"

# Build intermediates live on the system volume by default: SwiftPM and
# iconutil create (and delete) temp directories next to their output, and on
# an external volume that cleanup can be blocked. Set TMPDIR too so nothing
# spills onto /Volumes.
BUILD_DIR="${LYRIC_FEVER_BUILD_DIR:-$HOME/.cache/LyricFeverDirect}"
mkdir -p "$BUILD_DIR"
export TMPDIR="${TMPDIR:-/var/folders/tmp-lfd}"
mkdir -p "$TMPDIR" 2>/dev/null || TMPDIR=/tmp
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> 编译 (release)"
cd "$PROJECT_DIR"
# Where SwiftPM keeps intermediates. Overridable because building on an
# external volume occasionally cannot clear SwiftPM's own temp directories
# under /Volumes — pointing the scratch path elsewhere works around it.
SCRATCH="${LYRIC_FEVER_SCRATCH:-$BUILD_DIR/swiftpm}"
swift build -c release --scratch-path "$SCRATCH" 2>&1 | tail -20

BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/LyricFeverDirectApp"
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
cp "$BIN" "$MACOS/LyricFeverDirectApp"
cp "$BUILD_DIR/AppIcon.icns" "$RESOURCES/AppIcon.icns"
chmod +x "$MACOS/LyricFeverDirectApp"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>LyricFeverDirect</string>
    <key>CFBundleDisplayName</key>
    <string>歌词浮窗</string>
    <key>CFBundleIdentifier</key>
    <string>local.lyricfeverdirect</string>
    <key>CFBundleExecutable</key>
    <string>LyricFeverDirectApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
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
KEYCHAIN="$HOME/Library/Keychains/LyricFeverDirect.keychain"
IDENTITY="LyricFeverDirect Dev"
# 钥匙串在会话结束后会自动锁定，必须先解锁才能看到身份。
if [ -f "$KEYCHAIN" ]; then
    security unlock-keychain -p lyricfever "$KEYCHAIN" >/dev/null 2>&1
fi

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    # Two things codesign needs that are easy to miss:
    # 1. It searches the keychain *search list*, not the --keychain path, so
    #    ours has to be in the list (keep login/system too — a list with only
    #    ours also fails with errSecInternalComponent).
    # 2. The key re-locks between sessions, and the partition list has to be
    #    re-applied or codesign fails with errSecInternalComponent despite the
    #    identity being visible to find-identity.
    security set-key-partition-list \
        -S apple-tool:,apple:,codesign: -s -k lyricfever "$KEYCHAIN" >/dev/null 2>&1
    security list-keychains -d user -s \
        "$KEYCHAIN" \
        "$HOME/Library/Keychains/login.keychain-db" \
        /Library/Keychains/System.keychain >/dev/null 2>&1

    # `set -e` aborts on `VAR=$(failing command)`, so put codesign in the
    # condition instead of capturing `$?` — otherwise a failure silently
    # skips both the message and the ad-hoc fallback.
    if SIGN_OUT=$(codesign --force --deep --sign "$IDENTITY" \
            --keychain "$KEYCHAIN" --timestamp=none "$APP_DIR" 2>&1); then
        echo "    已用固定身份签名：$IDENTITY  (授权只需给一次)"
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
# 默认装到标准应用目录 /Applications；可用 LYRIC_FEVER_INSTALL_DIR 覆盖到
# 任意位置（例如外置盘）。目标目录不存在时不要连构建一起失败，只是把产物
# 留在 dist/ 并提示。
INSTALL_DIR="${LYRIC_FEVER_INSTALL_DIR:-/Applications}"
if [ "$1" = "--no-install" ]; then
    echo "==> 跳过安装 (--no-install)"
elif [ ! -d "$INSTALL_DIR" ]; then
    echo "!! 安装目录不存在：$INSTALL_DIR"
    echo "   目标目录不存在（如外置盘未挂载），产物留在 $APP_DIR"
else
    echo "==> 安装到 $INSTALL_DIR"
    TARGET="$INSTALL_DIR/LyricFeverDirect.app"
    BIN_PATH="$TARGET/Contents/MacOS/LyricFeverDirectApp"
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
