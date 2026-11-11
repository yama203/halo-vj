# NDI

上部の「連携」の NDI で、ネットワークの別の Mac・PC と映像をやりとりする方法を説明する。

## 出す

コンポジション（Syphon と同じもの）を NDI で出す。

- 名前は変えられる。はじめは「Halo VJ」。
- 同じネットワークの別の Mac・PC で受け取れる（TouchDesigner の NDI In TOP・Resolume・OBS など）。
- 不透明（BGRX）・60 コマ/秒の扱いで、前の 1 枚を送り終わっていなければ飛ばす。
- 何か所で受け取られているかが出る。

## 受け取る

ジェネレーター「NDI から」（分類「ほかのアプリ・カメラから」）を枠に置き、クリップタブの「映像」で、見つかった送り手を選ぶ。

- 2 秒ごとに探し直す。名前で覚える。
- 合わせ方・濃さ。
- 透明はそのまま（BGRA のとき）。
- 自分の出力は一覧に出さない。

## NDI の本体

NDI の本体（libndi）は起動中に読み込む。探す順：

1. アプリに同梱したもの（`Contents/Frameworks`）。
2. NDI ランタイム・NDI SDK・Resolume などに入っているもの。

- どの NDI を使っているかは「連携」の NDI の欄に出る。
- 見つからなければそう出る（ndi.video から NDI Tools を入れる）。

### アプリを作るときの同梱

`tools/make_app.sh` は、NDI SDK for Apple（ndi.video から落として使用許諾に同意したもの。`/Library/NDI SDK for Apple` か、`NDI_SDK_DIR` で場所を指定）があれば、libndi とライセンス文書（`Contents/Resources/NDI`）を同梱する。無ければ同梱しない（ほかのアプリの libndi はコピーしない）。

## 商標

NDI を使う所と About の窓に「NDI® is a registered trademark of Vizrt NDI AB」と ndi.video へのリンクがある。
