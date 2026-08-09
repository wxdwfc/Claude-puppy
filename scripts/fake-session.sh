#!/usr/bin/env bash
# 测试夹具:在临时目录里伪造一份 session 注册表,驱动状态机走一圈。
# 用法:
#   term A: PUPPY_SESSIONS_DIR=/tmp/pupfix swift run Puppy --watch
#   term B: scripts/fake-session.sh /tmp/pupfix
#
# alpha 用真实 spawn 出来的进程 pid,所以活性过滤走的是真实路径;
# 另外故意放一个死 pid 的文件,期望被丢弃。
set -euo pipefail

DIR="${1:?用法: fake-session.sh <sessions-dir>}"
DELAY="${STEP_DELAY:-3}"
mkdir -p "$DIR"

sleep 600 & ALIVE=$!
trap 'kill $ALIVE 2>/dev/null || true' EXIT
echo ">>> alpha 使用真实存活进程 pid=$ALIVE"

write() {  # write <pid> <name> <status> [waitingFor]
  local pid="$1" name="$2" status="$3" waiting="${4:-}"
  local now; now=$(( $(date +%s) * 1000 ))
  local extra=""
  [ -n "$waiting" ] && extra=",\"waitingFor\":\"$waiting\""
  cat > "$DIR/$pid.json" <<EOF
{"pid":$pid,"sessionId":"fake-$pid","cwd":"/Users/wxd/lab/fake/$name","startedAt":$now,
 "version":"2.1.226","peerProtocol":1,"kind":"interactive","entrypoint":"cli",
 "name":"$name","nameSource":"derived","status":"$status",
 "updatedAt":$now,"statusUpdatedAt":$now$extra}
EOF
  echo ">>> $name -> $status ${waiting:+($waiting)}"
  sleep "$DELAY"
}

write "$ALIVE" fake-alpha idle
write "$ALIVE" fake-alpha busy
write "$ALIVE" fake-alpha waiting "permission prompt"
write "$ALIVE" fake-alpha busy
write "$ALIVE" fake-alpha idle          # ← 期望这里推导出「完成」+ celebrating

echo ">>> 死 pid 残留文件(期望被活性过滤丢弃,列表不变)"
write 999002 fake-dead idle

echo ">>> 半损坏文件(期望跳过,不影响其余行)"
printf '{"pid":999003,"status":"bu' > "$DIR/999003.json"
sleep "$DELAY"

echo ">>> 未知 status(期望降级为中性态而不是崩溃)"
write "$ALIVE" fake-alpha shell

echo ">>> 移除 alpha"
rm -f "$DIR/$ALIVE.json"
sleep "$DELAY"

echo "完成。清理:rm -rf $DIR"
