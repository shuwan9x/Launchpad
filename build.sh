#!/bin/zsh
# 一键编译并打包 启动台.app
set -e
cd "$(dirname "$0")"

# -O：开启优化（默认 -Onone 会让 SwiftUI 泛型、拼音匹配等 CPU 路径慢约 1.6 倍，
# 且二进制大 44%）。一次传入全部源文件默认已是 whole-module optimization。
swiftc -O -disable-sandbox -parse-as-library Sources/*.swift -o Launchpad

mkdir -p Launchpad.app/Contents/MacOS Launchpad.app/Contents/Resources
cp Launchpad Launchpad.app/Contents/MacOS/Launchpad

# 用项目里的 AppIcon.png 生成 macOS 应用图标
if [ -f AppIcon.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Launchpad.app/Contents/Resources/AppIcon.icns
fi

cat > Launchpad.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>启动台</string>
    <key>CFBundleDisplayName</key><string>启动台</string>
    <key>CFBundleIdentifier</key><string>com.local.launchpad</string>
    <key>CFBundleExecutable</key><string>Launchpad</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST

codesign --force --sign - Launchpad.app >/dev/null 2>&1
echo "构建完成: $(pwd)/Launchpad.app"

# 同步到桌面（用 $HOME，不绑定具体用户）
if [ -d "$HOME/Desktop" ]; then
  rm -rf "$HOME/Desktop/启动台.app"
  cp -R Launchpad.app "$HOME/Desktop/启动台.app"
  echo "已同步: $HOME/Desktop/启动台.app"
fi
