#!/bin/bash
# 组装 TranslationReader.app（文档 §8）：swift build -c release → 组装 → codesign。
# 产物固定装到 ~/Applications（不要放在 ~/Documents 下运行：launchd/自启子进程没有该目录的 TCC 权限）。
# 幂等：重复执行会先删掉旧 .app 再重建。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG=release
ARCH=arm64
APP="$HOME/Applications/TranslationReader.app"
BIN_NAME=TranslationReader
SIGN_ID="TranslationReader Dev"

started_at=$(date +%s)
echo "==> swift build -c $CONFIG --arch $ARCH"
swift build -c "$CONFIG" --arch "$ARCH"
BIN_DIR="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)"
echo "==> build 完成，耗时 $(( $(date +%s) - started_at ))s"

if [ ! -x "$BIN_DIR/$BIN_NAME" ]; then
  echo "error: 找不到可执行文件 $BIN_DIR/$BIN_NAME" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN_DIR/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
chmod +x "$APP/Contents/MacOS/$BIN_NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> codesign"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "${SIGN_ID}"; then
  codesign --force --sign "${SIGN_ID}" "$APP"
  echo "已用稳定自签名证书「${SIGN_ID}」签名：重建后 TCC 授权保持有效。"
else
  codesign --force --sign - "$APP"
  echo "!! 未找到名为「${SIGN_ID}」的签名身份，本次使用 ad-hoc 签名（--sign -）。"
  echo "!! ad-hoc 签名每次重建都会重置 TCC 授权（辅助功能 / 屏幕录制要反复授权）。"
  echo "!! 执行 ./scripts/make-signing-cert.sh 生成稳定证书后重跑 make app 即可。"
fi

codesign --verify --verbose=2 "$APP" || true
echo "==> 产物：$APP"
ls -l "$APP/Contents/MacOS/"
