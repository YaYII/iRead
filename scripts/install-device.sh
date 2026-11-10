#!/bin/bash
# 一键构建、签名并安装到已连接的 iPhone。
# 前置条件：Xcode → Settings → Accounts 已登录 Apple ID（免费个人账号即可）。
# 用法：./scripts/install-device.sh [设备UDID]
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE_ID="${1:-00008150-00165DE11EE2401C}"
TEAM_ID="${TEAM_ID:-8VM4LPD9YP}"
BUNDLE_ID="com.yingyang.iread"

echo "==> 目标设备：$DEVICE_ID"
echo "==> 构建并自动签名"
xcodebuild -project iRead.xcodeproj -scheme iRead -configuration Debug \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath build/device \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic build

APP="build/device/Build/Products/Debug-iphoneos/iRead.app"
if [ ! -d "$APP" ]; then
  echo "构建产物不存在：$APP"
  exit 1
fi

echo "==> 校验签名"
codesign -dv --entitlements - "$APP" 2>&1 | head -20

echo "==> 安装到设备"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

echo "==> 启动 App"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" || \
  echo "（启动失败通常是因为手机锁屏或未开启开发者模式，解锁后手动点开 iRead 即可）"

echo "==> 完成"
