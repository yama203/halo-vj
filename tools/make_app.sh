#!/bin/bash
# リリースビルドして build/Halo VJ.app を作る（ソースの名前は VJPlayer のまま）
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="build/Halo VJ.app"
# 版の番号：HALO_VERSION（リリースのとき tools/release.sh が渡す）か、いちばん新しいタグ。
# ビルド番号はコミットの数（Sparkle はこれで新しいかを比べる。いつも増える）
VERSION="${HALO_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="${HALO_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
# アップデートの確かめ用（ふだんは使わない）：別のバンドル ID・別の更新の場所で作る
BUNDLE_ID="${HALO_BUNDLE_ID:-local.yama.vjplayer}"
FEED_URL="${HALO_FEED_URL:-https://github.com/yama203/halo-vj/releases/latest/download/appcast.xml}"
APP="${HALO_APP_PATH:-$APP}"
rm -rf "$APP" build/VJPlayer.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VJPlayer "$APP/Contents/MacOS/HaloVJ"
# 自動アップデート（Sparkle）の部品
mkdir -p "$APP/Contents/Frameworks"
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
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
# 英語の訳（英語の Mac では、画面の文言とメニューの標準の項目が英語になる。訳の無い文言は日本語のまま）
ditto Resources/en.lproj "$APP/Contents/Resources/en.lproj"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- 日本語と英語：Mac の言語の設定で決まる（メニューバーの標準の項目も）。元の言語は日本語 -->
  <key>CFBundleDevelopmentRegion</key><string>ja</string>
  <key>CFBundleLocalizations</key><array><string>ja</string><string>en</string></array>
  <key>CFBundleAllowMixedLocalizations</key><true/>
  <key>CFBundleName</key><string>Halo VJ</string>
  <key>CFBundleDisplayName</key><string>Halo VJ</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>HaloVJ</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <!-- 自動アップデート：GitHub Releases のいちばん新しい版の appcast.xml を見る。中身は下の公開鍵で確かめる -->
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>Dl7bmGO0P/Xcgr1ln0/cS0B80UvmeVB7iE3CjkmpF6s=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
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
<p>Sparkle &copy; Sparkle Project (MIT License).<br><a href="https://sparkle-project.org">sparkle-project.org</a></p>
<p>Syphon &copy; Syphon contributors (BSD License).<br><a href="https://syphon.github.io">syphon.github.io</a></p>
</div>
CREDITS
# 署名
SIGN_ID="${HALO_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  # ふだん（開発中）：アドホック署名。作り直しても同じアプリと見なされるように、指定要件をバンドル ID にする
  # （ふつうのアドホック署名だと、作り直すたびにマイクの許可が外れて、音が 0 のまま届く）
  codesign --force --sign - --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
else
  # 公証用（tools/release.sh が「Developer ID Application」の証明書で渡す）：Hardened Runtime で、内側から順に署名する。
  # HALO_SIGN_ID=- にすると、同じ形をアドホックで作る（証明書が無くても、Hardened Runtime で動くかを確かめられる）
  ENT="tools/HaloVJ.entitlements"
  if [ "$SIGN_ID" = "-" ]; then TS=(); REQ=(--requirements "=designated => identifier \"$BUNDLE_ID\""); else TS=(--timestamp); REQ=(); fi
  # （bash 3.2 の set -u では空の配列をそのまま展開できないので ${X[@]+…} の形にしている）
  sign() { codesign --force --sign "$SIGN_ID" --options runtime ${TS[@]+"${TS[@]}"} "$@"; }
  # Sparkle（https://sparkle-project.org/documentation/sandboxing/#code-signing の順）
  SP_FW="$APP/Contents/Frameworks/Sparkle.framework"
  sign "$SP_FW/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SP_FW/Versions/B/XPCServices/Downloader.xpc"
  sign "$SP_FW/Versions/B/Autoupdate"
  sign "$SP_FW/Versions/B/Updater.app"
  sign "$SP_FW"
  # 同梱した NDI
  if [ -f "$APP/Contents/Frameworks/libndi.dylib" ]; then sign "$APP/Contents/Frameworks/libndi.dylib"; fi
  # アプリ本体（最後に）
  sign --entitlements "$ENT" ${REQ[@]+"${REQ[@]}"} "$APP"
  codesign --verify --strict --deep "$APP"
  echo "署名しました（Hardened Runtime）: $SIGN_ID"
fi
# ファイルの種類とアイコンを Finder に覚え直させる
# （確かめ用の別の場所に作ったときは覚えさせない。プロジェクトのファイルがそちらで開くようになるので）
if [ -z "${HALO_APP_PATH:-}" ]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
fi
case "$APP" in /*) SHOW="$APP" ;; *) SHOW="$(pwd)/$APP" ;; esac
echo "作成しました: $SHOW（版 $VERSION・ビルド $BUILD）"
