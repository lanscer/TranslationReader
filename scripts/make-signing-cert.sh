#!/bin/bash
# 生成带 codeSigning EKU 的自签名证书并导入 login keychain，供 codesign 使用（文档 §8 / 风险 R2）。
# 任何需要提权的步骤都不执行 sudo：直接非零退出并打印手动命令。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="TranslationReader Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$ROOT/Resources/signing"
P12_PASS="tr-dev-signing"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "已存在可用签名身份「$NAME」，无需重建。"
  exit 0
fi

mkdir -p "$WORK"
chmod 700 "$WORK"

cat > "$WORK/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = TranslationReader Dev
O = Local Dev
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

echo "==> openssl 生成自签名证书（10 年有效，含 codeSigning EKU）"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/dev.key" -out "$WORK/dev.crt" \
  -config "$WORK/openssl.cnf" -extensions ext -subj "/CN=$NAME/O=Local Dev" 2>/dev/null
chmod 600 "$WORK/dev.key"

openssl pkcs12 -export \
  -inkey "$WORK/dev.key" -in "$WORK/dev.crt" \
  -name "$NAME" -out "$WORK/dev.p12" -passout "pass:$P12_PASS"

echo "==> security import 导入 login keychain（不执行 sudo）"
if ! security import "$WORK/dev.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
     -T /usr/bin/codesign -T /usr/bin/security 2>"$WORK/import.err"; then
  echo "!! 导入 login keychain 失败（未执行 sudo）。错误如下：" >&2
  cat "$WORK/import.err" >&2 || true
  echo "!! 证书与私钥已留在：$WORK" >&2
  echo "!! 请确认钥匙串已解锁后重试；或手动执行：" >&2
  echo "   security import \"$WORK/dev.p12\" -k \"$KEYCHAIN\" -P '<密码>' -T /usr/bin/codesign" >&2
  exit 2
fi

echo "==> security add-trusted-cert（仅用户域，不提权）"
if ! security add-trusted-cert -k "$KEYCHAIN" -p codeSign -r trustRoot "$WORK/dev.crt" 2>"$WORK/trust.err"; then
  echo "!! 无法在用户域信任该证书（通常需要管理员口令/交互授权）。本脚本不会执行 sudo。" >&2
  cat "$WORK/trust.err" >&2 || true
  echo "!! 证书与私钥已留在：$WORK" >&2
  echo "!! 需要信任时请由用户手动在终端执行： sudo security add-trusted-cert -d -r trustRoot -p codeSign -k \"$KEYCHAIN\" \"$WORK/dev.crt\"" >&2
  exit 3
fi

echo "==> 完成"
security find-identity -v -p codesigning | grep "$NAME" || true
echo "现在执行 make app，脚本会自动用「$NAME」签名。"
