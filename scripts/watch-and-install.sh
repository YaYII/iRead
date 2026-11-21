#!/bin/bash
# 监听 Xcode 账号登录；检测到账号后立刻重新签名构建 + 安装。
# 免费 Apple ID 的描述文件 7 天过期，登录后跑一次就能把 App 复活（沙盒数据不丢）。
# 最多等待 20 分钟（120 次 × 10 秒）。
set -uo pipefail
cd "$(dirname "$0")/.."

echo "开始监听 Xcode → Settings → Accounts 的登录状态（最长 20 分钟）…"
for i in $(seq 1 120); do
  ACCT=$(defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null | tr '\n' ' ' || true)
  TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | tr '\n' ' ' || true)

  # 空列表形如 { "IDE.Identifiers.Prod" = ( ); }，括号内没有内容
  if printf '%s' "$ACCT" | grep -qE '\([[:space:]]*[^)[:space:]]' \
     || printf '%s' "$TEAM" | grep -qE '\{[[:space:]]*[^}[:space:]]'; then
    echo "检测到 Xcode 账号，开始重新签名并安装"
    ./scripts/install-device.sh
    exit $?
  fi
  sleep 10
done
echo "等待超时：请在 Xcode → Settings → Accounts 登录 Apple ID 后手动跑 ./scripts/install-device.sh"
exit 1
