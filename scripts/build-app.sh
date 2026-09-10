#!/usr/bin/env bash
# 组装 .app bundle。之所以不能直接 `swift run`:TCC 的 Automation 弹窗和
# NSAppleEventsUsageDescription 都从 bundle 的 Info.plist 读,裸二进制的授权
# 会错误地归属到父终端上。
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP=".build/Puppy.app"

swift build -c "$CONFIG"
BIN=".build/$CONFIG/Puppy"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Puppy"
cp Support/Info.plist "$APP/Contents/Info.plist"

# 签名身份:优先用 Keychain 里的自签证书 puppy-dev。
# ad-hoc 签名每次重编译指纹都变,会让已授予的 Automation 权限反复失效,
# 所以真正开始用 iTerm 跳转之前应该先建一个 puppy-dev 证书。
IDENTITY="${CODESIGN_IDENTITY:-puppy-dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "已用 '$IDENTITY' 签名"
else
  codesign --force --sign - "$APP"
  echo "⚠️  Keychain 里没有 '$IDENTITY',退回 ad-hoc 签名。"
  echo "    ad-hoc 下每次重编译 Automation 授权都会失效(每次点 session 都重新弹窗)。"
  echo "    修法:Keychain Access → 证书助理 → 创建证书 → 名称 '$IDENTITY',"
  echo "    类型「代码签名」,自签名根证书,然后重新 make app。"
fi

# 装过 Stop hook 的话,顺手把那份拷贝也刷成新的。没装过就什么都不做 ——
# 不该因为编译了一次就往用户的 ~/.puppy 里塞东西。
HOOK_BIN="$HOME/.puppy/bin/puppy"
if [ -f "$HOOK_BIN" ]; then
  cp "$BIN" "$HOOK_BIN.new" && chmod +x "$HOOK_BIN.new" && mv -f "$HOOK_BIN.new" "$HOOK_BIN"
  echo "已刷新 Stop hook 用的二进制 $HOOK_BIN"
fi

echo "已生成 $APP"
