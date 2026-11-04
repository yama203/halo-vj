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
if [ ! -f Resources/AppIcon.icns ] || [ ! -f Resources/ProjectIcon.icns ]; then
  swift tools/make_icon.swift Resources
  iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
  iconutil -c icns Resources/ProjectIcon.iconset -o Resources/ProjectIcon.icns
fi
cp Resources/AppIcon.icns Resources/ProjectIcon.icns "$APP/Contents/Resources/"
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
  <!-- プロジェクトファイル（.halovj。以前の .vjproj も）：アイコンと、ダブルクリックで開く -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Halo VJ プロジェクト</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>CFBundleTypeIconFile</key><string>ProjectIcon</string>
      <key>LSItemContentTypes</key><array><string>local.yama.halovj.project</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>local.yama.halovj.project</string>
      <key>UTTypeDescription</key><string>Halo VJ プロジェクト</string>
      <key>UTTypeIconFile</key><string>ProjectIcon</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.content</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>halovj</string><string>vjproj</string></array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
# ファイルの種類とアイコンを Finder に覚え直させる
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "作成しました: $(pwd)/$APP"
