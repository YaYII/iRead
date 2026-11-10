#!/bin/bash
# 监听 Xcode 账号登录，检测到账号后立即执行签名构建 + 安装。
# 最多等待 10 分钟（120 次 × 5 秒）。
set -uo pipefail
cd "$(dirname "$0")/.."

echo "开始监听 Xcode 账号（最长 10 分钟）…"
for i in $(seq 1 120); do
  count=$(defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null | grep -c "identifier")
  if [ "${count:-0}" -gt 0 ]; then
    echo "检测到 Xcode 账号，开始构建签名并安装"
    ./scripts/install-device.sh
    exit $?
  fi
  sleep 5
done
echo "等待超时：10 分钟内未检测到 Xcode 账号"
exit 1
