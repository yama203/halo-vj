#!/bin/bash
# リリース：版の番号を付けて .app を作り、zip と appcast.xml（自動アップデートの知らせ）を作って、GitHub Releases に置く。
# 使い方：tools/release.sh 0.2.0            … タグ v0.2.0 を付けて push し、Release を作る
#         tools/release.sh 0.2.0 --dry-run  … build/release に作るだけ（タグ・Release は作らない）
# 署名の鍵：~/.halo-vj/sparkle_ed25519 があればそれ、無ければキーチェーン（tools の generate_keys で作ったもの）
# 公証：キーチェーンに「Developer ID Application」の証明書があれば、それで署名して公証にも出す（docs/notarization.md）
set -euo pipefail
cd "$(dirname "$0")/.."
VER="${1:-}"
DRY="${2:-}"
if ! [[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "版は 0.2.0 のような形で指定してください"; exit 1; fi
TAG="v$VER"
REPO="yama203/halo-vj"
if [ "$DRY" != "--dry-run" ]; then
  if [ -n "$(git status --porcelain)" ]; then echo "コミットしていない変更があります。先にコミットしてください"; exit 1; fi
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "$TAG はもうあります"; exit 1; fi
fi
PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"

swift package resolve >/dev/null
# 公証：キーチェーンに「Developer ID Application」の証明書があれば、それで署名して Apple の公証に出す
# （無ければ今までどおりアドホック署名で、公証なし）。手順は docs/notarization.md
SIGN_ID="${HALO_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
PROFILE="${HALO_NOTARY_PROFILE:-halo-vj}"
NOTARIZE=0
if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
  NOTARIZE=1
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "公証の資格情報（キーチェーンの「$PROFILE」）が見つかりません。docs/notarization.md の手順 3 を先にしてください"; exit 1
  fi
  echo "署名に使う証明書：$SIGN_ID"
else
  echo "注意：Developer ID の証明書が無いので、公証なしで作ります（docs/notarization.md）"
fi
HALO_VERSION="$VER" HALO_SIGN_ID="$SIGN_ID" tools/make_app.sh
APP="${HALO_APP_PATH:-build/Halo VJ.app}"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

OUT="${HALO_RELEASE_DIR:-build/release}"
rm -rf "$OUT"; mkdir -p "$OUT"

if [ "$NOTARIZE" = 1 ]; then
  echo "Apple の公証に出しています（ふつうは数分）…"
  NZ="$OUT/for-notarization.zip"
  ditto -c -k --keepParent "$APP" "$NZ"
  RES="$(xcrun notarytool submit "$NZ" --keychain-profile "$PROFILE" --wait --output-format json || true)"
  rm -f "$NZ"
  STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<<"$RES" 2>/dev/null || true)"
  SUB_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$RES" 2>/dev/null || true)"
  if [ "$STATUS" != "Accepted" ]; then
    echo "$RES"
    echo "公証が通りませんでした（${STATUS:-不明}）。理由を見る：xcrun notarytool log $SUB_ID --keychain-profile $PROFILE"
    exit 1
  fi
  # 公証の結果をアプリに貼り付ける（ネットにつながっていない Mac でも、初回から止められずに開ける）
  xcrun stapler staple "$APP"
  spctl --assess --type execute -vv "$APP"
  echo "公証が通りました"
fi

ZIP="Halo-VJ-$VER.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"

BIN=.build/artifacts/sparkle/Sparkle/bin
KEY="$HOME/.halo-vj/sparkle_ed25519"
if [ -f "$KEY" ]; then SIG="$("$BIN/sign_update" --ed-key-file "$KEY" "$OUT/$ZIP")"; else SIG="$("$BIN/sign_update" "$OUT/$ZIP")"; fi
# SIG は sparkle:edSignature="…" length="…"
BASE="${HALO_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/$TAG}"
# 変更の一覧：前のタグからのコミット（HALO_NOTES にファイルを渡せば、その中身）。最初の版は「最初の公開版」
if [ -n "${HALO_NOTES:-}" ]; then cp "$HALO_NOTES" "$OUT/notes.txt"
elif [ -n "$PREV" ]; then git log --format='%s' "$PREV..HEAD" > "$OUT/notes.txt"
else echo "最初の公開版" > "$OUT/notes.txt"; fi

python3 - "$OUT" "$VER" "$BUILD" "$BASE/$ZIP" "$SIG" "$NOTARIZE" <<'PY'
import sys, html, email.utils, time
out, ver, build, url, sig, notarized = sys.argv[1:]
notes = [l.strip() for l in open(f"{out}/notes.txt", encoding="utf-8") if l.strip()]
items = "".join(f"<li>{html.escape(n)}</li>" for n in notes[:40]) or "<li>細かな修正</li>"
xml = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Halo VJ</title>
    <item>
      <title>Halo VJ {ver}</title>
      <pubDate>{email.utils.formatdate(time.time())}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{ver}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<h3>Halo VJ {ver}</h3><ul>{items}</ul>]]></description>
      <enclosure url="{html.escape(url)}" type="application/octet-stream" {sig.strip()} />
    </item>
  </channel>
</rss>
'''
open(f"{out}/appcast.xml", "w", encoding="utf-8").write(xml)
md = "\n".join(f"- {n}" for n in notes[:40]) or "- 細かな修正"
first_open = "" if notarized == "1" else "初めて開くときは、システム設定 → プライバシーとセキュリティ →「このまま開く」。"
open(f"{out}/notes.md", "w", encoding="utf-8").write(
    md + f"\n\n**入れ方**：zip を開いて「Halo VJ」をアプリケーションに入れる。{first_open}次からはアプリが自分で新しい版を確かめる。\n")
PY
echo "作りました：$OUT/$ZIP・$OUT/appcast.xml（版 $VER・ビルド $BUILD）"
if [ "$DRY" == "--dry-run" ]; then exit 0; fi

git tag -a "$TAG" -m "Halo VJ $VER"
git push origin "$TAG"
gh release create "$TAG" "$OUT/$ZIP" "$OUT/appcast.xml" --repo "$REPO" --title "Halo VJ $VER" --notes-file "$OUT/notes.md"
echo "Release を作りました：https://github.com/$REPO/releases/tag/$TAG"
