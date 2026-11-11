# 出力のスナップショット（静止画で保存・クリップにする） 設計

今出ている絵（コンポジションの合成結果。マッピング・出力ごとの切り出しの前、マスターの明るさ・ブラックアウトの前）を 1 枚、PNG にする。

## 1. 操作

メニュー「出力」に 2 つ：
- **「今の絵を静止画で保存」**（ショートカットは今のメニュー・`App.swift` のキー監視・`shortcuts.md` とぶつからないものを選ぶ。候補 ⌘⇧P。ぶつかるなら無しでよい）：録画と同じフォルダ（`Recorder` が使っている保存先の決め方をそのまま使う）に `Halo VJ <日付 時刻>.png`。保存したら、録画が終わったときと同じ知らせ方（あれば）で知らせる。
- **「今の絵をクリップにする」**：同じ PNG を保存し、**選んでいるレイヤー（無ければいちばん上の、空きのあるレイヤー）の最初の空いているスロット** に静止画のクリップとして置く（`StillImage.swift` の今ある読み込みの道を使う）。空きが無ければ保存だけして知らせる。置くのは 1 回の操作として undo できる。再生は始めない。

OSC にも同じ 2 つ（`/halo/snapshot`、`/halo/snapshot/clip`。`OSCCommands` の今の書き方で。説明書 `osc.md` の表にも）。

## 2. 作り方

- 絵は描画スレッド（`RenderLoop.tick`）にしか無いので、`Engine` に「次のコマで 1 枚ほしい」という頼み（`renderLock` の中で立てる印＋完了のクロージャ）を足し、tick の中で、合成が終わった共有のテクスチャ（Syphon・録画に渡しているのと同じもの。`Recorder` が取っている所が手本）を **別のテクスチャへ blit して**、そのコマンドバッファの完了ハンドラで CPU に読み（`getBytes`。完了ハンドラのスレッドで）、PNG への書き出しは background のキューで。描画スレッドでは待たない（`waitUntilCompleted` を使わない）。
- 全レイヤーが止まっていて絵が無いときは黒い絵（コンポジションの大きさ）。
- 色：合成のテクスチャは rgba16Float（か今の形式）。PNG は sRGB 8 ビット、アルファなし（黒の上に合成した見た目＝出力の窓と同じ見え方）。録画と同じ色の扱いにそろえる（録画したコマと PNG が同じ色になること）。
- 大きさ：コンポジションの解像度そのまま。
- 同時に 2 回頼まれたら、2 回めは無視（1 回めが終わるまで）。

## 3. 守ること・テスト

- 文章は日本語、やさしい言葉で。英語の訳も（`python3 tools/i18n_check.py`。訳は `Localizable.strings` の中の「録画」に関する訳の近くにまとめる。末尾と「ガラス片」のすぐ下には足さない＝別の人が同時に足している）。
- 触るファイル：`Engine.swift`・`Metal.swift`（tick に数行）・`Recorder.swift`（保存先の決め方を使い回すための小さな口）・`App.swift`（メニュー）・`OSC.swift`・新しいファイル `Snapshot.swift`・テストは新しい `SelfTestSnapshot.swift`（`SelfTest.swift` に呼び出し 1 行）・説明書 `site/docs/ja|en/recording.md`・`osc.md`・`shortcuts.md`。**触らない**：`Effects.swift`・`MoreKinds.swift`・`MoreEffects*.swift`・`MoreGenerators*.swift`・`SelfTestKinds2*.swift`・`site/docs/*/effects*.md`・`generators*.md`・`site/index.html`。
- テスト（一時フォルダへ）：赤のテスト動画を出して 1 枚取る → PNG ができる・大きさがコンポジションと同じ・真ん中の画素が赤／何も出していないとき黒／「クリップにする」で空きスロットに静止画のクリップが入り、undo で消える／空きが無いとき落ちない。テストの中では描画ループが回っていないかもしれないので、今のテスト（録画や `sceneFrame` のテスト）がコマを進めている方法に合わせる。
- 利用者の設定・フォルダ（defaults `local.yama.vjplayer`、`~/Library/Application Support/Halo VJ/`、録画のフォルダ）には、確認・テストで書かない。窓を出す起動はしない。コミットは worktree のブランチにだけ。push しない。
