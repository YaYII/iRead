#!/bin/bash
# 一键重新签名并安装 iRead 到已连接的 iPhone。
#
# 免费 Apple ID（Personal Team）签出的**描述文件**只有 7 天有效期；
# 到期后 iOS 拒绝启动 App（图标变灰 / 闪退），但沙盒数据还在。
# 覆盖安装会刷新 7 天有效期，书架、阅读进度、朗读记录都不会丢。
#
# 前置条件：Xcode → Settings(⌘,) → Accounts 里已添加 Apple ID（免费账号即可）。
# 注意：macOS 系统设置里登录的 iCloud / App Store 账号不算，必须是 Xcode 的 Accounts。
#
# 用法：./scripts/install-device.sh [设备UDID]
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE_ID="${1:-BC079DD9-F5BB-5D2A-9883-D97A99B1F8A9}"
TEAM_ID="${TEAM_ID:-8VM4LPD9YP}"
BUNDLE_ID="com.yingyang.iread"
APP="build-device/Build/Products/Debug-iphoneos/iRead.app"

echo "==> 目标设备：$DEVICE_ID"
echo "==> 构建并自动签名"
LOG=$(mktemp)
if ! xcodebuild -project iRead.xcodeproj -scheme iRead -configuration Debug \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath build-device \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic build > "$LOG" 2>&1; then
  tail -25 "$LOG"
  if grep -q "No Accounts" "$LOG"; then
    echo
    echo "⚠️  Xcode 的 Accounts 里没有 Apple ID：打开 Xcode → Settings(⌘,) → Accounts"
    echo "    左下角 + → Apple ID 登录一次，再跑本脚本。（系统 iCloud 账号不算）"
  fi
  exit 1
fi
grep -E "BUILD SUCCEEDED" "$LOG" | tail -1

if [ ! -d "$APP" ]; then
  echo "构建产物不存在：$APP"
  exit 1
fi

echo "==> 安装到设备（覆盖安装，数据保留）"
INSTALL_LOG=$(mktemp)
if ! xcrun devicectl device install app --device "$DEVICE_ID" "$APP" > "$INSTALL_LOG" 2>&1; then
  tail -20 "$INSTALL_LOG"
  exit 1
fi
grep -E "App installed|bundleID" "$INSTALL_LOG" | head -3

echo "==> 启动 App"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" 2>&1 | tail -2 || \
  echo "（启动失败多半是锁屏，解锁后手动点开 iRead 即可）"

echo "==> 新签名到期（UTC）"
security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
  | plutil -extract ExpirationDate raw - 2>/dev/null || echo "(读不到)"
echo "    7 天内再跑一次本脚本即可，数据不会丢。"
