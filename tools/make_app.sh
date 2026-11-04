#!/bin/bash
# リリースビルドして build/VJPlayer.app を作る
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/VJPlayer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VJPlayer "$APP/Contents/MacOS/VJPlayer"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VJPlayer</string>
  <key>CFBundleDisplayName</key><string>VJPlayer</string>
  <key>CFBundleIdentifier</key><string>local.yama.vjplayer</string>
  <key>CFBundleExecutable</key><string>VJPlayer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
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
