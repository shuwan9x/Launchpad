#!/bin/zsh
# 构建 app 并打成可拖入 Applications 的 DMG
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  Launchpad.app/Contents/Info.plist 2>/dev/null || echo '2.0')"
DMG="Launchpad-${VERSION}.dmg"
STAGE="$(mktemp -d /private/tmp/launchpad-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

cp -R Launchpad.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname 'Launchpad' -srcfolder "$STAGE" -ov -format UDZO "$DMG"
echo "DMG 完成: $(pwd)/$DMG"
