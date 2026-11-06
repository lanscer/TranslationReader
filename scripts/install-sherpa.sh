#!/usr/bin/env bash
# install-sherpa.sh — 落地本地朗读引擎（文档 §6.6.1）
#
#   sherpa-onnx macOS 预编译包 + vits-piper-zh_CN-huayan-medium（中文·快）
#   + matcha-icefall-zh-baker（中文·自然）+ vits-piper-en_US-amy-medium（英文）
#   + Matcha 共用的 vocos-22khz-univ.onnx vocoder
#
# 落地目录（与 SpeechKit.SherpaPaths 同源，全程不需要 sudo）：
#   ~/Library/Application Support/TranslationReader/models/sherpa-onnx/
#     bin/ lib/ include/        ← 预编译包内容，bin/sherpa-onnx-offline-tts 是入口
#     models/<模型目录>/        ← 每个模型一个目录
#     models/vocoder/vocos-22khz-univ.onnx
#
# 幂等：已存在且 sha256 校验通过即跳过；--force 强制重下。
# 回滚：任何一步校验/解包失败，删除该项半成品后退出非 0。
#
# 版本钉死 v1.13.8：v2.0.0 起官方移除 espeak-ng 前端（--vits-data-dir 被忽略），
# piper 系 zh_CN/en_US 模型会报 "phoneme_codepoints is empty, no lexicon,
# and no frontend available"，只有 matcha 系还能跑。要同时支持华研中文与
# Amy 英文，必须用 1.13.x。
set -uo pipefail

VERSION="v1.13.8"
ROOT="$HOME/Library/Application Support/TranslationReader/models/sherpa-onnx"
FORCE=0
SKIP_ENGLISH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --skip-english) SKIP_ENGLISH=1; shift ;;
    --root) ROOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

DL="$ROOT/.downloads"
LOG="$ROOT/install.log"
mkdir -p "$DL"
: > "$LOG"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
bail() { say "✗ $*"; say "安装中止；已删除该项半成品，修复后重跑本脚本即可（幂等）。"; exit 1; }
sha_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
head12() { printf '%s' "$1" | cut -c1-12; }

# GitHub release 直连在国内常被掐（实测 0 B/s），按顺序回退镜像。
fetch() { # fetch <release-relative-url> <out> <sha256>
  local rel="$1" out="$2" want="$3"
  if [[ "$FORCE" -eq 0 && -f "$out" ]]; then
    if [[ "$(sha_of "$out")" == "$want" ]]; then
      say "· 已存在且校验通过，跳过下载：$(basename "$out")"
      return 0
    fi
    say "· 已有文件校验不符，重新下载：$(basename "$out")"
    rm -f "$out"
  fi
  local url="https://github.com/k2-fsa/sherpa-onnx/releases/download/$rel"
  for mirror in "" "https://gh-proxy.com/" "https://gh-proxy.net/"; do
    if [[ -z "$mirror" ]]; then say "↓ 直连 $url"; else say "↓ 镜像 $mirror"; fi
    rm -f "$out.part"
    if curl -sS -L --http1.1 --retry 3 --retry-delay 2 -C - -m 1800 \
         -o "$out.part" "$mirror$url"; then
      if [[ "$(sha_of "$out.part")" == "$want" ]]; then
        mv "$out.part" "$out"
        say "  ✓ sha256 校验通过：$(basename "$out") $(wc -c < "$out" | tr -d ' ') 字节"
        return 0
      fi
      say "  ✗ sha256 不符，换下一个源"
      rm -f "$out.part"
    else
      say "  ✗ 下载失败，换下一个源"
      rm -f "$out.part"
    fi
  done
  bail "下载失败：$(basename "$out")"
}

verify_file() { # verify_file <path> <sha256> <label>
  local path="$1" want="$2" label="$3"
  if [[ ! -f "$path" ]]; then say "  ✗ 缺文件：$label"; return 1; fi
  local got
  got="$(sha_of "$path")"
  if [[ "$got" != "$want" ]]; then
    say "  ✗ sha256 不符：$label（期望 $(head12 "$want")… 实际 $(head12 "$got")…）"
    return 1
  fi
  say "  ✓ $label sha256=$(head12 "$got")…"
}

unpack_tbz2() { # unpack_tbz2 <archive> <dest-parent> <expected-dir-name> <label>
  local archive="$1" dest="$2" expect="$3" label="$4"
  local staging="$dest/.staging-$expect"
  rm -rf "$staging"; mkdir -p "$staging"
  if ! tar -xjf "$archive" -C "$staging" 2>>"$LOG"; then
    rm -rf "$staging"; bail "解包失败：$label"
  fi
  if [[ ! -d "$staging/$expect" ]]; then
    rm -rf "$staging"; bail "解包结构不符（缺 $expect/）：$label"
  fi
  rm -rf "$dest/$expect"
  mv "$staging/$expect" "$dest/$expect"
  rm -rf "$staging"
  say "  ✓ 解包到 $dest/$expect"
}

# ---------------------------------------------------------------------------
# 1/5 预编译包（bin/lib/include）
# ---------------------------------------------------------------------------
say ""
say "== 1/5 sherpa-onnx 预编译包 $VERSION =="
PKG="sherpa-onnx-$VERSION-osx-arm64-shared"
PKG_ARCHIVE="$DL/$PKG.tar.bz2"
fetch "$VERSION/$PKG.tar.bz2" "$PKG_ARCHIVE" "b10e5c7e2c30ea03de9c442655d14860d9edc475c6251d58a8f5f06e913a1d56"

STAGE="$ROOT/.staging-bin"
rm -rf "$STAGE"; mkdir -p "$STAGE"
if ! tar -xjf "$PKG_ARCHIVE" -C "$STAGE" 2>>"$LOG"; then rm -rf "$STAGE"; bail "解包失败：预编译包"; fi
if [[ ! -d "$STAGE/$PKG" ]]; then rm -rf "$STAGE"; bail "解包结构不符：预编译包缺 $PKG/"; fi
mkdir -p "$ROOT"
for part in bin lib include; do
  rm -rf "$ROOT/$part"
  mv "$STAGE/$PKG/$part" "$ROOT/$part"
done
rm -rf "$STAGE"
chmod +x "$ROOT/bin/sherpa-onnx-offline-tts"
if ! verify_file "$ROOT/bin/sherpa-onnx-offline-tts" \
      "947a31ca98559ec8e97d35543f43324110514bfe4940d64567b2b54fde6de74c" "bin/sherpa-onnx-offline-tts"; then
  rm -rf "$ROOT/bin" "$ROOT/lib" "$ROOT/include"
  bail "预编译包校验失败（已回滚 bin/lib/include）"
fi

# ---------------------------------------------------------------------------
# 2/5 中文·快：vits-piper-zh_CN-huayan-medium
# ---------------------------------------------------------------------------
MODELS="$ROOT/models"
mkdir -p "$MODELS"
say ""
say "== 2/5 中文·快 vits-piper-zh_CN-huayan-medium =="
HUAYAN="vits-piper-zh_CN-huayan-medium"
fetch "tts-models/$HUAYAN.tar.bz2" "$DL/$HUAYAN.tar.bz2" \
  "dbdfec42b91d9cee31cce9ff4b3e9c305eb6fbf60546d071f7e46273554cce6b"
unpack_tbz2 "$DL/$HUAYAN.tar.bz2" "$MODELS" "$HUAYAN" "中文·快模型"
if ! verify_file "$MODELS/$HUAYAN/zh_CN-huayan-medium.onnx" \
      "04234ec24907e9efa7e153669e07d4e0cf6d260adc005323aa929386dae53f86" "zh_CN-huayan-medium.onnx"; then
  rm -rf "$MODELS/$HUAYAN"; bail "中文·快模型校验失败（已回滚）"
fi
verify_file "$MODELS/$HUAYAN/tokens.txt" \
  "2619c1a9de1bcf928162f40c583caf39368cfd6b2340c7bcad51dc634411ec36" "huayan tokens.txt" || true

# ---------------------------------------------------------------------------
# 3/5 中文·自然：matcha-icefall-zh-baker + vocoder
# ---------------------------------------------------------------------------
say ""
say "== 3/5 中文·自然 matcha-icefall-zh-baker =="
BAKER="matcha-icefall-zh-baker"
fetch "tts-models/$BAKER.tar.bz2" "$DL/$BAKER.tar.bz2" \
  "8da2e113b85dfea37b11bcdc994506aa86b584ee3348c2065271fb6f75cb83b8"
unpack_tbz2 "$DL/$BAKER.tar.bz2" "$MODELS" "$BAKER" "中文·自然模型"
if ! verify_file "$MODELS/$BAKER/model-steps-3.onnx" \
      "78a9fd17e9a6c20198dca4e69d18f941303f8ab39ec61dde04cfc7595262ddfd" "model-steps-3.onnx"; then
  rm -rf "$MODELS/$BAKER"; bail "中文·自然模型校验失败（已回滚）"
fi
verify_file "$MODELS/$BAKER/lexicon.txt" \
  "38b886d46aefa50da6322a64d72fd595d5f4fae1051adb160d647541b1e0a4a2" "matcha lexicon.txt" || true

mkdir -p "$MODELS/vocoder"
VOCOS="vocos-22khz-univ.onnx"
say "· Matcha vocoder vocos-22khz-univ.onnx"
fetch "vocoder-models/$VOCOS" "$MODELS/vocoder/$VOCOS" \
  "0574a135aa1db2de6e181050db2ec528496cacd4a4701fc5d7faf9f9804c0081"
if ! verify_file "$MODELS/vocoder/$VOCOS" \
      "0574a135aa1db2de6e181050db2ec528496cacd4a4701fc5d7faf9f9804c0081" "vocos-22khz-univ.onnx"; then
  rm -rf "$MODELS/vocoder"; bail "vocoder 校验失败（已回滚）"
fi

# ---------------------------------------------------------------------------
# 4/5 英文：vits-piper-en_US-amy-medium（--skip-english 可跳过）
# ---------------------------------------------------------------------------
if [[ "$SKIP_ENGLISH" -eq 0 ]]; then
  say ""
  say "== 4/5 英文 vits-piper-en_US-amy-medium =="
  AMY="vits-piper-en_US-amy-medium"
  fetch "tts-models/$AMY.tar.bz2" "$DL/$AMY.tar.bz2" \
    "9a5d1fc497f85e8022b785bff5f8105203b1e33099ee6265203efc70b0cb0264"
  unpack_tbz2 "$DL/$AMY.tar.bz2" "$MODELS" "$AMY" "英文模型"
  if ! verify_file "$MODELS/$AMY/en_US-amy-medium.onnx" \
        "fbaa8e36d8f26fe6f3ebb65cab461e629d8b37a5b7c5fb78fb64317db73e1c25" "en_US-amy-medium.onnx"; then
    rm -rf "$MODELS/$AMY"; bail "英文模型校验失败（已回滚）"
  fi
else
  say "== 4/5 英文模型已跳过（--skip-english）=="
fi

# ---------------------------------------------------------------------------
# 5/5 自检 + 汇总
# ---------------------------------------------------------------------------
say ""
say "== 5/5 自检 =="
if ! "$ROOT/bin/sherpa-onnx-offline-tts" --help >/dev/null 2>&1; then
  bail "bin/sherpa-onnx-offline-tts 无法运行（可能缺 lib/ 或架构不符）"
fi
say "  ✓ sherpa-onnx-offline-tts 可执行"

say ""
say "== 落地汇总 =="
say "根目录：$ROOT"
say "$(du -sh "$ROOT" | tr '\t' ' ')"
say ""
say "目录结构："
say "$(cd "$ROOT" && find . -maxdepth 2 -type d ! -path './.downloads*' | sort | sed 's/^/  /')"
say ""
say "关键文件 sha256："
for rel in bin/sherpa-onnx-offline-tts \
           "models/vits-piper-zh_CN-huayan-medium/zh_CN-huayan-medium.onnx" \
           "models/matcha-icefall-zh-baker/model-steps-3.onnx" \
           "models/vocoder/vocos-22khz-univ.onnx" \
           "models/vits-piper-en_US-amy-medium/en_US-amy-medium.onnx"; do
  [[ -f "$ROOT/$rel" ]] && say "  $(sha_of "$ROOT/$rel")  $rel"
done
say ""
say "完成。在 App 设置 → 朗读 里把引擎切到「本地 sherpa-onnx」即可。"
say "校验日志：$LOG"
