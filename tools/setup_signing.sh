#!/bin/bash
# 建立一次固定的自签名代码签名身份。
#
# 为什么需要它
# ------------
# macOS 的「自动化」(TCC AppleEvents) 授权是按代码签名身份记录的。
# ad-hoc 签名每次重新构建都会产生新的 cdhash，系统就会当成一个全新 App，
# 于是每次打包后都得重新去「系统设置 ▸ 隐私与安全性 ▸ 自动化」允许一次。
# 用一个固定的自签名身份签名后，只需授权一次，之后永久有效。
#
# 钥匙串放在 ~/Library/Keychains（纯 ASCII 路径）：放在含中文的目录下时
# `security` 会找不到它。
set -e

KC="$HOME/Library/Keychains/LyricFeverDirect.keychain"
IDENTITY="LyricFeverDirect Dev"
PW="lyricfever"
TMP="$(mktemp -d)"

echo "==> 生成自签名证书 (仅本机开发用)"
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$IDENTITY" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/lfd.p12" -passout pass:"$PW" >/dev/null 2>&1

echo "==> 建立专用钥匙串"
rm -f "$KC"
security create-keychain -p "$PW" "$KC" >/dev/null 2>&1
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/lfd.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null 2>&1
# 让 codesign 使用私钥时不弹「想要访问钥匙串」对话框
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null 2>&1

rm -rf "$TMP"

echo "==> 确认身份"
security find-identity -p codesigning "$KC" | sed -n '3,5p'
echo
echo "完成。之后 ./build.sh 会自动用这个身份签名。"
