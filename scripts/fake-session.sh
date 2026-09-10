#!/usr/bin/env bash
# 测试夹具:在临时目录里伪造一份 session 注册表,驱动状态机走一圈。
# 用法:
#   term A: PUPPY_SESSIONS_DIR=/tmp/pupfix PUPPY_EVENTS_DIR=/tmp/pupev swift run Puppy --watch
#   term B: scripts/fake-session.sh /tmp/pupfix /tmp/pupev
#
# 给了第二个参数就顺便伪造 Stop hook 的 sidecar,可以看到「跑完了」被换成真话。
#
# alpha 用真实 spawn 出来的进程 pid,所以活性过滤走的是真实路径;
# 另外故意放一个死 pid 的文件,期望被丢弃。
set -euo pipefail

DIR="${1:?用法: fake-session.sh <sessions-dir> [events-dir]}"
EVENTS="${2:-}"
DELAY="${STEP_DELAY:-3}"
mkdir -p "$DIR"
[ -n "$EVENTS" ] && mkdir -p "$EVENTS"

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

# Stop hook 那一端:摘要必须先落地,才配得上紧接着写的 idle
# (SessionStore.noteSlop 只认时间戳对得上的那一条)。
if [ -n "$EVENTS" ]; then
  cat > "$EVENTS/fake-$ALIVE.json" <<EOF
{"sessionId":"fake-$ALIVE","summary":"把 DirectoryWatcher 换成了 FSEvents,省了一半唤醒",
 "at":$(( $(date +%s) * 1000 ))}
EOF
  echo ">>> 写入 Stop hook sidecar(期望气泡说人话,而不是「跑完了」)"
fi
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

echo "完成。清理:rm -rf $DIR ${EVENTS:-}"
