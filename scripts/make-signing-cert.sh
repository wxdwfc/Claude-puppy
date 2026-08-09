#!/usr/bin/env bash
# 在登录钥匙串里创建一张自签名的代码签名证书(默认叫 puppy-dev),
# 等价于 Keychain Access → 证书助理 → 创建证书 的那一套点击操作。
#
# 为什么需要:ad-hoc 签名(codesign --sign -)的身份就是二进制自身的 hash,
# 每次重编译都变,TCC 会把它当成一个新 app,已授予的 Automation 权限随之作废。
# 用固定身份签名后,Automation 授权只需要点一次。
set -euo pipefail

IDENTITY="${CODESIGN_IDENTITY:-puppy-dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "'$IDENTITY' 已经存在,不用重复创建。"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = $IDENTITY

[v3]
basicConstraints   = critical,CA:true
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> 生成自签名证书 '$IDENTITY'(有效期 10 年)"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/cert.cnf" -extensions v3 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# 空密码的 p12 在 macOS 的 security 工具里会 MAC 校验失败,所以给个临时口令。
# -legacy: security 只认老的 PKCS#12 加密算法。
P12PASS="puppy-tmp"
openssl pkcs12 -export -legacy \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$IDENTITY" -out "$WORK/cert.p12" -passout "pass:$P12PASS"

echo "==> 导入登录钥匙串"
# -A: 允许任何程序使用这把私钥,免得 codesign 每次弹「允许访问钥匙串」。
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12PASS" -A -T /usr/bin/codesign >/dev/null

echo "==> 标记为受信任的代码签名根证书(会弹一次系统密码框)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "✅ 完成。现在跑 make app 应该会打印「已用 '$IDENTITY' 签名」。"
else
  echo "⚠️  证书已导入,但 find-identity 没把它列为有效身份,请把上面的输出发给我。"
  exit 1
fi

cat <<EOF

想删掉的话:
  security delete-identity -c "$IDENTITY" "$KEYCHAIN"
EOF
