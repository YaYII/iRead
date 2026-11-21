#!/bin/bash
# 后台自动刷新 iRead 的免费账号签名。
#
# 免费 Personal Team 的 provisioning profile 只有 7 天（证书是 1 年，两回事）。
# 由 LaunchAgent 每 6 小时唤起；只在剩余 < 48 小时时才真正重新构建 + 覆盖安装，
# 这样 48 小时窗口里有 8 次重试机会，又不至于天天重装打断阅读。
# 覆盖安装保留沙盒数据；失败写日志，下一次自动重试。
#
# 手动跑一次：./scripts/auto-refresh.sh
# 查看日志：tail -30 ~/Library/Logs/iread-refresh.log
set -uo pipefail
cd "$(dirname "$0")/.."

LOG="$HOME/Library/Logs/iread-refresh.log"
PROFILE="build-device/Build/Products/Debug-iphoneos/iRead.app/embedded.mobileprovision"
WINDOW=$((48 * 3600))

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

read_expiry() {
  security cms -D -i "$PROFILE" 2>/dev/null \
    | plutil -extract ExpirationDate raw - 2>/dev/null || true
}

to_epoch() {
  python3 -c '
import sys, datetime
s = sys.stdin.read().strip()
try:
    print(int(datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()))
except Exception:
    print(0)
'
}

EXP=$(read_expiry)
EXP_TS=$(printf '%s' "$EXP" | to_epoch 2>/dev/null || echo 0)
NOW=$(date +%s)
LEFT=$((EXP_TS - NOW))

if [ "$EXP_TS" -gt 0 ] && [ "$LEFT" -gt "$WINDOW" ]; then
  log "签名到期 ${EXP}，剩余 $((LEFT / 3600)) 小时，跳过"
  exit 0
fi

log "签名到期 ${EXP:-未知}，剩余 $((LEFT / 3600)) 小时 → 开始刷新"
if ./scripts/install-device.sh >> "$LOG" 2>&1; then
  NEW=$(read_expiry)
  log "✅ 刷新完成，新到期 ${NEW:-未知}"
else
  log "❌ 刷新失败（常见：Xcode 账号 session 失效 / 手机没连 / 锁屏），下次自动重试"
fi
