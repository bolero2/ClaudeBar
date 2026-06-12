#!/bin/bash
# Builds ClaudeDeck.app — a proper macOS menu bar agent bundle from the SwiftPM
# executable. Output: ./ClaudeDeck.app
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ClaudeDeck"
DISPLAY_NAME="ClaudeDeck"
BUNDLE_ID="com.claudedeck.app"
# Version: from $CLAUDEDECK_VERSION (CI sets it to the git tag), else the latest
# tag, else 1.0.0. A leading "v" is stripped. Drives CFBundleShortVersionString,
# which the in-app updater compares against the latest GitHub release.
VERSION="${CLAUDEDECK_VERSION:-}"
VERSION="${VERSION#v}"
if [ -z "$VERSION" ]; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
fi
VERSION="${VERSION:-1.0.0}"
BUILD="1"

echo "▶︎ swift build -c release"
swift build -c release

BIN=".build/release/${APP_NAME}"
APP="${APP_NAME}.app"
CONTENTS="${APP}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "▶︎ assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${MACOS}" "${RESOURCES}"
cp "${BIN}" "${MACOS}/${APP_NAME}"
chmod +x "${MACOS}/${APP_NAME}"

# App icon (Dock icon when the dashboard is open + notification icon).
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${RESOURCES}/AppIcon.icns"
fi

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key>           <string>${DISPLAY_NAME}</string>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>            <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundleIconName</key>              <string>AppIcon</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleVersion</key>               <string>${BUILD}</string>
    <key>CFBundleShortVersionString</key>    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>실행 중인 세션의 터미널 창/탭을 앞으로 가져오기 위해 터미널 앱 제어 권한이 필요합니다.</string>
    <key>NSHumanReadableCopyright</key>      <string>ClaudeDeck</string>
</dict>
</plist>
PLIST

# Ad-hoc code signature so macOS will launch it and remember automation grants
# under a stable bundle identifier.
echo "▶︎ codesign (ad-hoc)"
codesign --force --deep --sign - "${APP}" >/dev/null 2>&1 || \
    echo "  (codesign 건너뜀 — 그래도 실행됩니다)"

echo "✓ 완성: $(pwd)/${APP}"
