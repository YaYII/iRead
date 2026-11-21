#!/bin/bash
# 把当前真机构建打成 IPA，供 iPhone 上的 SideStore / LiveContainer 导入。
#
# SideStore 会用自己的 Apple ID 重新签名，所以 IPA 里原本那张 7 天描述文件无所谓；
# 之后由手机端后台自动续签，Mac 不用一直开着。
#
# 用法：./scripts/make-ipa.sh [输出路径]   默认 dist/iRead.ipa
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build-device/Build/Products/Debug-iphoneos/iRead.app"
OUT="${1:-dist/iRead.ipa}"

if [ ! -d "$APP" ]; then
  echo "找不到构建产物：$APP"
  echo "先跑 ./scripts/install-device.sh 生成真机包"
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qr -X "$OUT_ABS" Payload)

echo "==> IPA 已生成：$OUT_ABS"
ls -lh "$OUT_ABS"
echo "==> 内容校验"
unzip -l "$OUT_ABS" | grep -E "Payload/iRead.app/(iRead$|Info.plist|embedded.mobileprovision)" | head -5
echo
echo "把 dist/iRead.ipa 隔空投送 / 存到 iPhone 的「文件」里，"
echo "在 SideStore 的 My Apps 点 + 导入（或交给 LiveContainer 跑），之后由手机端续签。"
