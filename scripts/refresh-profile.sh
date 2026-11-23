#!/bin/bash
# 强制刷一次免费账号的 7 天签名。
#
# 为什么需要它：免费 Apple ID 的描述文件只有 7 天，Xcode 会一直复用本地缓存
# （哪怕只剩 4 天也不换），于是手机上天天弹「还有 N 天到期」。
# 光重新 build 没用 —— 得先把本地缓存的那份移走，Xcode 才会去开发者门户领新的。
#
# 前置条件：Xcode → Settings(⌘,) → Accounts 里已登录 Apple ID。
# 没登录时 xcodebuild 会报 "No Accounts"，本脚本会把备份放回去并提示。
#
# 用法：./scripts/refresh-profile.sh [设备UDID]
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:-8VM4LPD9YP}"
BUNDLE_ID="com.yingyang.iread"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
BACKUP_DIR="/tmp/iread-profile-backup-$(date +%Y%m%d-%H%M%S)"
APP="build-device/Build/Products/Debug-iphoneos/iRead.app"

mkdir -p "$BACKUP_DIR"
moved=0

restore() {
  for file in "$BACKUP_DIR"/*.mobileprovision; do
    [ -e "$file" ] || continue
    cp "$file" "$PROFILE_DIR/"
  done
  if [ "$moved" -gt 0 ]; then
    echo "==> 已把旧描述文件放回去，App 至少还能用到原到期日"
  fi
}

# 任何一步出错都要把描述文件放回去：移动之后脚本中途死掉，
# 这台机器就没有可用的描述文件了，连原来的构建都恢复不了。
trap 'restore' EXIT

# 只动这个 App 的描述文件：同机还有别的项目在用同一个免费账号，
# 把人家的描述文件删了会连带把别的 App 弄成装不上。
if [ -d "$PROFILE_DIR" ]; then
  for file in "$PROFILE_DIR"/*.mobileprovision; do
    [ -e "$file" ] || continue
    ident=$(security cms -D -i "$file" 2>/dev/null | plutil -p - 2>/dev/null \
      | grep -o '"application-identifier" => "[^"]*"' | head -1 || true)
    case "$ident" in
      *"$TEAM_ID.$BUNDLE_ID"*)
        cp "$file" "$BACKUP_DIR/"
        rm "$file"
        moved=$((moved + 1))
        ;;
    esac
  done
fi

echo "==> 移走 ${moved} 份旧描述文件（备份在 ${BACKUP_DIR}）"

# 删掉旧的产物，否则增量构建可能跳过重签
rm -rf "$APP"

LOG=$(mktemp)
if ! xcodebuild -project iRead.xcodeproj -scheme iRead -configuration Debug \
  -destination "id=${1:-BC079DD9-F5BB-5D2A-9883-D97A99B1F8A9}" \
  -derivedDataPath build-device \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic build > "$LOG" 2>&1; then
  tail -20 "$LOG"
  if grep -q "No Accounts" "$LOG"; then
    echo
    echo "⚠️  Xcode 里没有登录 Apple ID，签不出新描述文件。"
    echo "    打开 Xcode → Settings(⌘,) → Accounts → 左下角 + → Apple ID 登录一次，再跑本脚本。"
  fi
  exit 1
fi
grep -E "BUILD SUCCEEDED" "$LOG" | tail -1
trap - EXIT

echo "==> 新签名到期（UTC）"
security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
  | plutil -p - 2>/dev/null | grep "ExpirationDate" || echo "（没读到，检查 $APP/embedded.mobileprovision）"

echo "==> 安装到设备"
./scripts/install-device.sh "${1:-BC079DD9-F5BB-5D2A-9883-D97A99B1F8A9}"
