#!/bin/bash
# Author: wilbur
# Version: 1.0
# Date: 2026-06-11
# Description: 使用系统原生工具打包带 Applications 快捷拖拽安装的 DMG

set -e

APP_NAME="pickpick"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 尝试多个可能的 Release App 路径
APP_PATH=""
CANDIDATES=(
    "${PROJECT_DIR}/build/derived/Build/Products/Release/${APP_NAME}.app"
    "${PROJECT_DIR}/build/Release/${APP_NAME}.app"
    "${PROJECT_DIR}/build/${APP_NAME}.xcarchive/Products/Applications/${APP_NAME}.app"
)

for p in "${CANDIDATES[@]}"; do
    if [ -d "$p" ]; then
        APP_PATH="$p"
        break
    fi
done

if [ -z "$APP_PATH" ]; then
    echo "错误：未找到 ${APP_NAME}.app"
    echo "请先用 Xcode 构建 Release 版本"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "unknown")
VOL_NAME="${APP_NAME} ${VERSION}"
DMG_NAME="${APP_NAME}-v${VERSION}.dmg"
DMG_PATH="${PROJECT_DIR}/build/${DMG_NAME}"
TMP_DMG="${PROJECT_DIR}/build/tmp_${APP_NAME}.dmg"

echo "App: ${APP_PATH}"
echo "版本: ${VERSION}"
echo "输出: ${DMG_PATH}"

# 清理旧文件
rm -f "${DMG_PATH}" "${TMP_DMG}"

# 1. 创建临时空白 dmg（略大于 app 体积，给 Applications alias 留空间）
APP_SIZE=$(du -sm "${APP_PATH}" | cut -f1)
DMG_SIZE=$((APP_SIZE + 20))

hdiutil create \
    -srcfolder "${APP_PATH}" \
    -volname "${VOL_NAME}" \
    -fs HFS+ \
    -size "${DMG_SIZE}m" \
    -format UDRW \
    -o "${TMP_DMG}"

# 2. 挂载 dmg，解析设备和挂载点（匹配 Apple_HFS 分区行）
ATTACH_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen "${TMP_DMG}")
DEVICE=$(echo "${ATTACH_OUTPUT}" | grep 'Apple_HFS' | awk '{print $1}')
MOUNT_DIR=$(echo "${ATTACH_OUTPUT}" | grep 'Apple_HFS' | cut -f3-)

if [ -z "${DEVICE}" ] || [ -z "${MOUNT_DIR}" ]; then
    echo "错误：挂载 DMG 失败"
    exit 1
fi

echo "挂载设备: ${DEVICE}"
echo "挂载点: ${MOUNT_DIR}"

sleep 1

# 3. 在 dmg 内创建 Applications 快捷方式
ln -s /Applications "${MOUNT_DIR}/Applications"

# 4. 用 AppleScript 设置窗口布局：app 在左，Applications 在右
osascript <<EOF
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 860, 520}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 110
        set position of item "${APP_NAME}.app" to {180, 200}
        set position of item "Applications" to {480, 200}
        close
    end tell
end tell
EOF

# 5. 设置 dmg 为只读并压缩
hdiutil detach "${DEVICE}" -force || true
sleep 1

hdiutil convert "${TMP_DMG}" -format UDZO -imagekey zlib-level=9 -o "${DMG_PATH}"

# 6. 清理临时文件
rm -f "${TMP_DMG}"

echo "✅ DMG 打包成功: ${DMG_PATH}"
