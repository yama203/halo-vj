# エフェクト・ジェネレーターの「お気に入り」と「最近使った」 設計

種類が 90 近くになるので、よく使うものにすぐ届くようにする。場所は 2 つ：横のパネル（`EffectBrowser`）と、⌘E のピッカー（`EffectPicker`）。

## 1. お気に入り

- タイル（`EffectTile`）とピッカーの行を **右クリック →「お気に入りに入れる／お気に入りから外す」**。タイルにマウスを乗せると右上に小さな星（`star`／入っていれば `star.fill`、黄色）が出て、押しても切り替わる。入っているものは、乗せていなくても小さな星が出たまま。
- パネルの分類の並びの **いちばん上に「お気に入り」の節**（1 つも無ければ節ごと出さない）。並びは入れた順。節の中のタイルはふつうのタイルと同じ（ドラッグで置ける・見本が出る）。エフェクトのパネルにはエフェクトだけ、ジェネレーターのパネルにはジェネレーターだけ。
- ピッカー（⌘E）：検索の文字が空のとき、いちばん上に「お気に入り」、次に「最近使った」、そのあと今までの並び。検索中は今までどおり（ただし、お気に入りは同じ当たり方の中で先に来る）。行の右端に小さな星。

## 2. 最近使った

- エフェクト・ジェネレーターを **置いたとき**（パネルからのドラッグ・ダブルクリック、ピッカー、メニュー「エフェクトを追加」のどれでも。入口が 1 つにまとまっていればそこ、無ければ `EffectRecents.note(kind)` を各入口で呼ぶ）に覚える。新しい順で 8 個まで。同じものは先頭へ。
- パネル：「お気に入り」の下に「最近使った」の節（1 行ぶん・多くて 8 個。無ければ出さない）。お気に入りに入っているものも出してよい。
- undo・シーンの呼び出し・プロジェクトを開く・複製では覚えない（人が選んで置いたときだけ）。

## 3. 保存

- アプリ共通の設定として `UserDefaults`（キー `effectFavorites`・`effectRecents`、中身は kind の名前の配列）。プロジェクトには入れない。
- **テスト・書き出しの起動（`--selftest`、`--*-preview`、`--kind-sheet` など。`EffectPresets` が「ファイルを読み書きしない」と判断しているのと同じ条件）では UserDefaults に読み書きしない**（メモリの中だけ）。`VJ_STATE_PATH` が指定されているときも UserDefaults には書かない（確認用の起動が利用者の設定を汚さないように）。
- 知らない名前（古い版・新しい版の kind）は読むとき黙って飛ばす（消さない＝書き戻すときは、知らない名前も残す）。
- 型：`final class EffectFavorites: ObservableObject { static let shared; @Published private(set) var favorites: [EffectKind]; @Published private(set) var recents: [EffectKind]; func toggle(_:) ; func isFavorite(_:) ; func note(_:) }`。新しいファイル `EffectFavorites.swift`。テストで差し替えられるよう、保存先（`UserDefaults?`）を init で渡せる形に。

## 4. 守ること

- 文章は日本語、やさしい言葉で。英語の訳も（`python3 tools/i18n_check.py`。訳は `Localizable.strings` の **末尾の手前ではなく、「エフェクトを探す」の訳の行のすぐ下** にまとめる）。
- 星がタイルの名前・印・見本（マウスを乗せると出る `KindPreview`）のじゃまをしない。星を押してもドラッグや「置く」が起きない。
- Esc（ブラックアウト）などの今のキーの動きを変えない。
- テストは新しいファイル `SelfTestFavorites.swift` に（`SelfTest.swift` には呼び出し 1 行）：入れる・外す・順番／最近は 8 個まで・重なりは先頭へ／知らない名前を飛ばして、書き戻しても残る／保存先なしで落ちない／一時の `UserDefaults(suiteName:)` で保存と読み直し（終わったら `removePersistentDomain`）。
- 説明書：`site/docs/ja/effects.md`（と `en`）に短い節。
- 見た目は `--picker-preview` などの書き出しで自分で見る。パネルの書き出しの口が無ければ、`CardPreview.writeView` の形で小さな開発用の口を足してよい。
- 利用者の設定（defaults `local.yama.vjplayer`、`~/Library/Application Support/Halo VJ/`）には確認・テストで書かない・消さない。窓を出す起動はしない。コミットは worktree のブランチにだけ。push はしない。
