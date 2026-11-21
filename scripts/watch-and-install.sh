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
    # Team 缓存可能只是残留，真正的判据是「构建能不能签出名来」。
    # 失败不要退出，继续等用户把账号加完。
    echo "疑似检测到 Xcode 账号，尝试重新签名并安装…"
    if ./scripts/install-device.sh; then
      echo "✅ 安装完成"
      exit 0
    fi
    echo "构建还没成功（账号可能尚未真正生效），继续等待…"
  fi
  sleep 10
done
echo "等待超时：请在 Xcode → Settings → Accounts 登录 Apple ID 后手动跑 ./scripts/install-device.sh"
exit 1
