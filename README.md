# Halo VJ

ライブでのポン出し用の、自分で保守できる macOS 用 VJ ソフト。（ソースコードの中の名前は VJPlayer のまま）

Swift + SwiftUI + Metal + AVFoundation。取り込んでいるもの：Syphon（BSD）、Sparkle（自動アップデート、MIT）。NDI は入っている NDI ランタイムを実行時に読み込む。

## 使い方・インストール

**説明書：https://yama203.github.io/halo-vj/docs/**（元の Markdown は `site/docs/ja/`、目次は `site/docs/toc.json`）

- [Releases](https://github.com/yama203/halo-vj/releases) から `Halo-VJ-x.y.z.zip` を落として開き、「Halo VJ」をアプリケーションに入れる。Apple シリコンの Mac・macOS 14 以上。
- Apple の公証を通していないので、初めて開くときは止められる。システム設定 → プライバシーとセキュリティ →「このまま開く」で一度許可する。
- そのあとは、アプリが自分で新しい版を確かめる（Sparkle。公開鍵 Info.plist の SUPublicEDKey で署名を確かめてから入れる）。

## リリースの作り方

```bash
tools/release.sh 0.2.0 --dry-run   # build/release に zip と appcast.xml を作るだけ
tools/release.sh 0.2.0             # タグ v0.2.0 を付けて push し、GitHub Releases に zip と appcast.xml を置く
```

- 先にコミットしておく（変更が残っているとやめる）。変更点は前のタグからのコミットの題名（`HALO_NOTES=ファイル` で書いたものにできる）。
- 版の番号は `CFBundleShortVersionString`、ビルド番号はコミットの数（Sparkle はビルド番号で新しいかを比べる）。
- アプリは `https://github.com/yama203/halo-vj/releases/latest/download/appcast.xml` を見る。いちばん新しい Release に appcast.xml があればよい（リポジトリは公開にしておく）。
- 署名の秘密鍵：ログインキーチェーン（Sparkle の `generate_keys` で作ったもの）と、その書き出し `~/.halo-vj/sparkle_ed25519`。**無くすと、今入っているアプリに新しい版を届けられなくなる**ので、どこか安全な所にも控えておく。リポジトリには入れない。
- NDI SDK for Apple が入っていれば、libndi も同梱される（説明書の「NDI」）。
- キーチェーンに「Developer ID Application」の証明書があれば、Hardened Runtime で署名して Apple の公証に出し、結果を貼り付けてから zip にする。準備の手順は [docs/notarization.md](docs/notarization.md)。

## 紹介ページ

`site/` が紹介ページ（https://yama203.github.io/halo-vj/ ）、`site/docs/` が説明書（`ja/` の Markdown を、表示するときに HTML にする。ページを足すときは `toc.json` にも書く）。main に push すると `.github/workflows/pages.yml` が GitHub Pages に出す（初回だけ、リポジトリの Settings → Pages → Source を「GitHub Actions」にする）。手元で見るときは `python3 -m http.server --directory site`。

## ビルド

```bash
./tools/make_app.sh        # build/Halo VJ.app を作成
swift run                  # 開発中の起動
```

## 再生エンジンのセルフテスト

画面を出さずに、ポン出しの遅延・速度変更・切り替えを検証する（音量 0）。

```bash
.build/debug/VJPlayer --selftest a.mov b.mov
.build/debug/VJPlayer --od-preview out.png 0.8 40 80 0.8 24 0.4 1.5 300   # オーバードライブ加算の見え方を 1 枚書き出す（値はレイヤータブの並び）
.build/debug/VJPlayer --blend-preview 13 out.png text 下の画像.png   # 重ね方（番号：13 屈折〜18 溶け込む）の見え方を 1 枚書き出す（上はジェネレーター。続けて値）
```

## 素材の変換（DXV → ProRes）

```bash
tools/convert_to_prores.sh clip1.mov clip2.mov          # ProRes 422
PROFILE=1 tools/convert_to_prores.sh clip1.mov          # ProRes 422 LT（軽量）
```

## 英語の表示

英語の Mac では、画面の文言が英語で出る（訳のある所だけ。無い所は日本語のまま）。

- 画面に出す文言は日本語のまま `L("…")` で包む（`Sources/VJPlayer/Localize.swift`）。`L("選んだ \(n) 個")` のように値を入れてもよい。
- 訳は `Resources/en.lproj/Localizable.strings`（日本語 = 英語）。値の入る所は `%@`、順番を変えるときは `%1$@` `%2$@`。
- 同じ日本語でも場所によって訳を変えたいときは `L("出す", note: "動詞")`。訳の見出しは `出す#動詞`（無ければふつうの `出す` の訳）。
- `python3 tools/i18n_check.py` で、訳の抜け・使われていない訳・書式の食い違いが出る。`--stub` で抜けを訳の形で出す。
- 英語で確かめる：`"build/Halo VJ.app/Contents/MacOS/HaloVJ" -AppleLanguages "(en)"`
- フォルダ名・ファイルの中に書く文字（「素材」フォルダ、録画のフォルダ、MIDI のポート名など）は訳さない（包まない）。

## 構成

- `ClipSlot.swift` … 1クリップの再生。自前の再生時計（速度を変えても位置が連続）で映像と音声を同じ時刻から動かす
- `FrameStream.swift` … 映像の先読みデコード（AVAssetReader）。先頭からデコード済みの待機ストリームを差し替えてポン出しする。逆再生は後ろから数コマずつ読んで逆順に渡す
- `AudioOutput.swift` … AVAudioEngine。音声はタイムストレッチ（AVAudioUnitTimePitch）で速度変更しても音程維持。PCM を ~/Library/Caches/Halo VJ/audio にキャッシュ（往復モードの逆再生用に、区間を逆順にしたファイルも作る）
- `Engine.swift` … スロット・レイヤー管理、フレーム取得、コーナーピン、保存
- `Inspector.swift` … パラメーターパネル（コンポジション／レイヤー／クリップ）と、数値をドラッグで変えるフィールド
- `PreviewPlayer.swift` … 出力せずにクリップをプレビュー再生（音なし）
- `Layer.swift` … レイヤーの設定（重ね方・不透明度・音量・切り替えフェード）、フェード計算
- `SettingsView.swift` … 設定ウィンドウ（⌘,）
- `Effects.swift` … エフェクトの種類と値（足すときは `EffectKind` に追加し、シェーダー `feffect` に処理を書く。一覧には自動で並ぶ）。`EffectBrowser.swift` … エフェクト一覧とドラッグ＆ドロップ。処理は `Metal.swift` の `feffect` シェーダーと `EffectProcessor`（クリップ → レイヤー → コンポジションの順）
- `Animation.swift` / `AnimationViews.swift` … パラメーターのアニメーション（時刻から値を計算するので描画スレッドで毎フレーム求める）、BPM の時計とタップテンポ、その UI
- 描画は専用スレッド（CVDisplayLink）で vsync ごとに行う。画面操作でメインスレッドが重くても出力は止まらない
- `Metal.swift` … 描画。レイヤーを合成（Compositor）→ 合成した画に射影変換でコーナーピン、テストパターン
- `Output.swift` … 出力ウィンドウ
- `SpeedControl.swift` … 速度コントロール
- `Views.swift` / `App.swift` … 画面・キーボード操作
- `tools/make_icon.swift` … アプリとプロジェクトファイルのアイコンを描く（作り直すときは `Resources/*.icns` を消してから `tools/make_app.sh`）
- `Project.swift` … プロジェクトファイルのメニュー操作（開く・保存・見つからない動画）
- `Sources/ObjCSupport` … AVFoundation の例外を Swift からつかまえるための小さな補助（音声の再生開始で落ちないように）
