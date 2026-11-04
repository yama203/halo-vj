#!/bin/bash
# リリースビルドして build/Halo VJ.app を作る（ソースの名前は VJPlayer のまま）
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="build/Halo VJ.app"
rm -rf "$APP" build/VJPlayer.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VJPlayer "$APP/Contents/MacOS/HaloVJ"
# アイコン（無ければ tools/make_icon.swift で作る）
if [ ! -f Resources/AppIcon.icns ]; then
  swift tools/make_icon.swift Resources
  iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Halo VJ</string>
  <key>CFBundleDisplayName</key><string>Halo VJ</string>
  <key>CFBundleIdentifier</key><string>local.yama.vjplayer</string>
  <key>CFBundleExecutable</key><string>HaloVJ</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><false/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "作成しました: $(pwd)/$APP"
