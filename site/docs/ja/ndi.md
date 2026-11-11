# NDI

このページでは、上部の「連携」の NDI で、ネットワーク上の別の Mac・PC と映像をやりとりする方法を説明します。

## 送信する

コンポジション（Syphon と同じ映像）を NDI で送信します。

- 名前は変更できます。初期設定は「Halo VJ」です。
- 同じネットワーク上の別の Mac・PC で受信できます（TouchDesigner の NDI In TOP・Resolume・OBS など）。
- 不透明（BGRX）・60 フレーム/秒として扱い、前のフレームを送り終わっていない場合はそのフレームをスキップします。
- 何か所で受信されているかを表示します。

## 受信する

ジェネレーター「NDI から」（分類「ほかのアプリ・カメラから」）をスロットに置き、クリップタブの「映像」で、見つかった送信元を選びます。

- 2 秒ごとに送信元を探し直します。送信元は名前で記憶します。
- 合わせ方・濃さを設定できます。
- 透明部分は透明のまま扱います（BGRA のとき）。
- 自分の出力は一覧に表示しません。

## NDI の本体

NDI の本体（libndi）は起動時に読み込みます。探す順番は次のとおりです。

1. アプリに同梱したもの（`Contents/Frameworks`）。
2. NDI ランタイム・NDI SDK・Resolume などに含まれているもの。

- 使用中の NDI は「連携」の NDI の欄に表示されます。
- 見つからない場合は、その旨が表示されます（ndi.video から NDI Tools をインストールしてください）。

### アプリをビルドするときの同梱

`tools/make_app.sh` は、NDI SDK for Apple（ndi.video からダウンロードし、使用許諾に同意したもの。`/Library/NDI SDK for Apple` に置くか、`NDI_SDK_DIR` で場所を指定）があれば、libndi とライセンス文書（`Contents/Resources/NDI`）を同梱します。無い場合は同梱しません（ほかのアプリの libndi はコピーしません）。

## 商標

NDI を使用している箇所と About ウィンドウに、「NDI® is a registered trademark of Vizrt NDI AB」の表記と ndi.video へのリンクがあります。
