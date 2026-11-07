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
# 日本語の印（中身は空でよい。これがあるとシステムの文言が日本語になる）
mkdir -p "$APP/Contents/Resources/ja.lproj"
: > "$APP/Contents/Resources/ja.lproj/InfoPlist.strings"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- 日本語のアプリ：メニューバーの標準の項目（ファイル・編集・ウインドウ・ヘルプ・終了など）も日本語で出る -->
  <key>CFBundleDevelopmentRegion</key><string>ja</string>
  <key>CFBundleLocalizations</key><array><string>ja</string></array>
  <key>CFBundleAllowMixedLocalizations</key><true/>
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
  <!-- 音に反応させる：マイク・ライン入力の音を読む -->
  <!-- OSC：iPad や TouchDesigner と、ネットワークで値をやりとりする -->
  <key>NSLocalNetworkUsageDescription</key><string>iPad や TouchDesigner と OSC で値をやりとりする・NDI で映像をやりとりする・照明（Art-Net）に送るために使います。</string>
  <!-- カメラ・キャプチャの入力 -->
  <key>NSBonjourServices</key><array><string>_ndi._tcp</string></array>
  <key>NSCameraUsageDescription</key><string>Web カメラ・HDMI キャプチャ・iPhone の映像をクリップとして使うために使います。</string>
  <key>NSMicrophoneUsageDescription</key><string>音（マイク・ライン入力）に合わせて映像を動かすために使います。</string>
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
# NDI：NDI SDK for Apple（ndi.video から落として、使用許諾に同意したもの）が入っていれば、libndi とライセンス文書を同梱する。
# 無ければ同梱しない（アプリは、入っている NDI ランタイムを探して使う）。ほかのアプリに入っている libndi はコピーしない
NDI_SDK="${NDI_SDK_DIR:-}"
if [ -z "$NDI_SDK" ]; then
  for d in "/Library/NDI SDK for Apple" "/Library/NDI SDK for macOS" "$HOME/NDI SDK for Apple"; do
    [ -f "$d/lib/macOS/libndi.dylib" ] && NDI_SDK="$d" && break
  done
fi
if [ -n "$NDI_SDK" ] && [ -f "$NDI_SDK/lib/macOS/libndi.dylib" ]; then
  mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/NDI"
  cp "$NDI_SDK/lib/macOS/libndi.dylib" "$APP/Contents/Frameworks/"
  find "$NDI_SDK" -maxdepth 3 \( -iname '*licen*' -o -iname '*eula*' \) -type f -exec cp {} "$APP/Contents/Resources/NDI/" \;
  echo "NDI を同梱しました: $NDI_SDK"
else
  echo "NDI SDK が見つからないので、NDI は同梱しません（入っている NDI ランタイムを使います）"
fi
# About の窓に出す文（NDI の商標の表記・Syphon）
cat > "$APP/Contents/Resources/Credits.html" <<'CREDITS'
<div style="font: 11px -apple-system; text-align: center">
<p>NDI&reg; is a registered trademark of Vizrt NDI AB.<br><a href="https://ndi.video">ndi.video</a></p>
<p>Syphon &copy; Syphon contributors (BSD License).<br><a href="https://syphon.github.io">syphon.github.io</a></p>
</div>
CREDITS
# 署名：作り直しても同じアプリと見なされるように、指定要件をバンドル ID にする
# （ふつうのアドホック署名だと、作り直すたびにマイクの許可が外れて、音が 0 のまま届く）
codesign --force --sign - --requirements '=designated => identifier "local.yama.vjplayer"' "$APP"
# ファイルの種類とアイコンを Finder に覚え直させる
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "作成しました: $(pwd)/$APP"
