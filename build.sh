#!/bin/bash
# 编译并把 LyricFeverDirect 打包成可直接双击运行的 .app
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$PROJECT_DIR/dist/LyricFeverDirect.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> 编译 (release)"
cd "$PROJECT_DIR"
swift build -c release 2>&1 | tail -20

BIN="$(swift build -c release --show-bin-path)/LyricFeverDirectApp"
if [ ! -f "$BIN" ]; then
    echo "!! 找不到可执行文件: $BIN"
    exit 1
fi

echo "==> 生成图标"
ICONSET="$PROJECT_DIR/.build/AppIcon.iconset"
rm -rf "$ICONSET"
if [ ! -f "$PROJECT_DIR/.build/make_icon" ] || [ "$PROJECT_DIR/tools/make_icon.swift" -nt "$PROJECT_DIR/.build/make_icon" ]; then
    swiftc -O "$PROJECT_DIR/tools/make_icon.swift" -o "$PROJECT_DIR/.build/make_icon"
fi
"$PROJECT_DIR/.build/make_icon" "$ICONSET"
rm -f "$APP_DIR/Contents/Resources/AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$PROJECT_DIR/.build/AppIcon.icns"

echo "==> 组装 .app"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN" "$MACOS/LyricFeverDirectApp"
cp "$PROJECT_DIR/.build/AppIcon.icns" "$RESOURCES/AppIcon.icns"
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
    # codesign only searches the keychain *search list*, not an arbitrary
    # --keychain path. Rebuild that list from scratch each time: it easily
    # accumulates duplicates and stale entries (a leftover keychain under a
    # non-ASCII path makes `security` fail outright), and either breaks
    # codesign with errSecInternalComponent.
    OTHERS=$(security list-keychains -d user 2>/dev/null \
        | sed 's/^ *//;s/"//g' \
        | grep -v "LyricFeverDirect.keychain" \
        | grep -v "LFD.keychain" \
        | tr '\n' ' ')
    security list-keychains -d user -s "$KEYCHAIN" $OTHERS >/dev/null 2>&1

    # `codesign ... | tail` would report tail's status, not codesign's, and
    # silently claim success after a failure — capture the status properly.
    SIGN_OUT=$(codesign --force --deep --sign "$IDENTITY" \
        --keychain "$KEYCHAIN" --timestamp=none "$APP_DIR" 2>&1)
    SIGN_RC=$?
    if [ $SIGN_RC -eq 0 ]; then
        echo "    已用固定身份签名：$IDENTITY  (授权只需给一次)"
    else
        echo "    ！固定身份签名失败 (rc=$SIGN_RC): $SIGN_OUT"
        echo "    回退 ad-hoc —— 下次重建后需重新允许“自动化”"
        codesign --force --deep --sign - "$APP_DIR" 2>&1 | tail -3
    fi
else
    echo "    未找到固定签名身份，回退 ad-hoc"
    echo "    跑一次 ./tools/setup_signing.sh 可让授权只需给一次"
    codesign --force --deep --sign - "$APP_DIR" 2>&1 | tail -3
fi

echo "==> 完成: $APP_DIR"
echo "    首次运行需要在「系统设置 ▸ 隐私与安全性 ▸ 自动化」允许控制“音乐”（只需一次）。"
