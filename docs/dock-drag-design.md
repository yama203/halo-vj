# 自由レイアウト：タブとパネルの操作（設計）

## ねらい

今は「タブを横にドラッグ = 並べ替え」「右の取っ手（✥）をドラッグ = パネルを動かす」の 2 つに分かれている。
覚えることが 2 つあり、取っ手は気づきにくい。ブラウザーや VS Code と同じ **「タブをつかんで、置きたい所へ持っていく」1 つの動き** にまとめる。

- タブバーの中で動かしている間は「並べ替え」。
- タブバーから外へ出たら、そのまま「パネルを動かす」。置ける場所が光る。
- ほかの区画のタブバーへ持っていけば、その位置にタブとして入る。
- メインのウィンドウの外で離せば、別ウィンドウになる。
- Esc で取り消し。

システムのドラッグ（`.onDrag` / `NSItemProvider` / `DropDelegate`）は使わない。
1 つの `DragGesture` でマウスの位置を追い、置き場所は自分で計算して、いちばん上に 1 枚だけ重ねた絵で見せる。
（今の作りは、区画ごと・境目ごと・四辺ごとに `onDrop` の受け口を重ねている。これを全部やめる。）

古い並び（`sidePanelTab` の、自由レイアウトでない方）は触らない。

## 動き

### つかむ

- タブの上で 4pt 以上動かしたら始まる。クリック（選ぶ）はこれまで通り。
- 始まったら、そのタブを選んだ状態にする（中身が見える）。
- タブバーの何もない所（タブの右の空き）をつかんだら、**今表示しているパネル** をつかんだのと同じ（最初から「動かす」の段階）。
- ✥ の取っ手は無くす。

### 段階

マウスの位置で決まる。行き来できる。

| マウスの場所 | 段階 | 見た目 |
|---|---|---|
| 元のタブバーの帯（上下に 14pt の余裕） | 並べ替え | タブがマウスについて横に動く。ほかのタブは場所を空けるように横へずれる（0.15 秒のアニメーション）。置き場所の絵は出さない |
| それ以外 | 動かす | 元のタブは薄く（不透明度 0.35）元の場所に残る。マウスの所に小さな札（アイコンと名前）がつく。置き場所を 1 つだけ光らせる |

### 置き場所（「動かす」の段階）

上から順に調べて、最初に当たったもの 1 つ。

1. **画面の四辺**：自由レイアウト全体の外枠から内へ 18pt。その辺いっぱいに置く（今の `movingToEdge`）。
2. **区画の境目**：分割のつまみの線から ±9pt。そこに 1 列・1 段差し込む（今の `movingToBorder`）。
3. **タブバー**（どの区画でも）：その位置にタブとして入る。位置は、タブの中心より左なら前、右なら後ろ。落とす位置に青い縦線、タブバー全体をうっすら光らせる。
4. **区画の中身**：端から 25% までは、その側に分けて置く（左・右・上・下。角は近い方）。それより内側は「タブにする」（最後に足す）。
5. **メインのウィンドウの外**：別ウィンドウにできるパネル（`panel.window != nil`）なら「別ウィンドウに出す」。札の文字をそれに変える。できないパネルなら置けない。
6. どれでもない（上のバーの上など）：置けない。離すと何も変わらない。

何も変わらない置き方（自分だけの区画の真ん中、今と同じ位置のタブ、自分の区画が 1 枚だけのときのその区画の端…のうち結果が同じ木になるもの）は「置けない」と同じに扱い、光らせない。
判定は「置いた結果の木が今の木と同じか」で決める（`DockNode` は `Equatable`。新しく作る区画の `id` は比べる前に無視する工夫がいる：下の「形だけ比べる」）。

### 光らせ方

- 塗り：アクセントの色 0.28、枠：アクセントの色 2pt、角丸 6。動くときは 0.12 秒でなめらかに。
- 区画の端（分けて置く）は、その区画の半分を光らせる（実際に置かれる大きさではなく、分かりやすさ優先。今の 40% より大きく）。
- 四辺は、全体のその辺 30%（下だけ 20%）。境目は、線を中心に太さ 40pt の帯。
- 光らせた所の真ん中に、短い言葉の札：「タブにする」「左に置く」「右に置く」「上に置く」「下に置く」「ここに差し込む」「左端いっぱい」…（今ある言葉を使い、足りないものだけ足す）。
- マウスの札：`アイコン 名前`、影つき、マウスの右下 12pt。置けない所では薄く（0.5）。

### 離す

- 置ける所なら、その通りに木を変える。変わる所は `withAnimation(.easeOut(duration: 0.18))`。
- 置けない所なら何もしない。
- ウィンドウの外なら `LayoutManager.shared.detach(...)`。できれば新しいウィンドウをマウスの位置に出す（今の `detach` が位置を受け取れないなら、位置は今のままでよい）。

### 取り消し

- ドラッグ中に Esc：何も変えずに終わる。`NSEvent.addLocalMonitorForEvents(matching: .keyDown)` をドラッグの間だけ付ける。
- 終わったあと `DragGesture` の `onEnded` が来ても、取り消し済みなら何もしない。

### そのほか

- **タブが入りきらないとき**：選んでいないタブはアイコンだけにする（`ViewThatFits` で、全部名前つき → 選んだものだけ名前つき）。アイコンだけのタブには `.help` で名前を出す。
- **右クリック**：「左へ」「右へ」「別ウィンドウに出す」（できるものだけ）「閉じる」。
- **ダブルクリック**：その区画を一時的にいっぱいに広げる／戻す。保存はしない（`DockRootView` の `@State`）。広げている間は、その区画だけを全体に描く。タブバーの右に「戻す」ボタン（`arrow.down.right.and.arrow.up.left`）を出す。ドラッグを始めたら自動で戻す。
- ホバーの説明：「ドラッグ：並べ替え・ほかの場所へ動かす / ダブルクリック：広げる」。

## 作り

### 置き場所を表す型

```swift
enum DockDropTarget: Equatable {
    case tabBar(tabsID: UUID, before: DockPanel?)   // before == nil は最後
    case zone(tabsID: UUID, DockZone)               // .center = 最後のタブとして足す
    case border(splitID: UUID)
    case edge(DockZone)
    case detach
}
```

### 画面の形（置き場所の計算に使う）

各区画・境目が、自分の四角を `PreferenceKey` で上へ伝える。座標は `DockRootView` に付けた名前つきの座標（`"dockRoot"`）。

```swift
struct DockGeometry: Equatable {
    var root: CGRect                                   // 自由レイアウト全体
    var areas: [UUID: Area]                            // 区画
    var borders: [UUID: CGRect]                        // 境目（つまみの四角）
    struct Area: Equatable {
        var frame: CGRect                              // 区画全体
        var bar: CGRect                                // タブバー
        var tabs: [DockPanel: CGRect]                  // 見えているタブ
        var order: [DockPanel]                         // 見えているタブの並び
    }
}
```

### 計算（画面なしで試せる、ただの関数）

```swift
enum DockDropResolver {
    /// マウスの位置から置き場所を決める。置けない・変わらないなら nil
    static func target(at p: CGPoint, panel: DockPanel, geometry: DockGeometry,
                       tree: DockNode, insideWindow: Bool, canDetach: Bool) -> DockDropTarget?
    /// 光らせる四角
    static func highlight(_ t: DockDropTarget, geometry: DockGeometry) -> CGRect?
    /// 元のタブバーの中か（並べ替えの段階か）
    static func isReordering(at p: CGPoint, source: UUID, geometry: DockGeometry) -> Bool
}

extension DockNode {
    /// 置き場所の通りに動かした木
    func applying(_ t: DockDropTarget, panel: DockPanel) -> DockNode
    /// ほかの区画のタブバーの、決まった位置へ入れる（今の inserting は最後に足すだけ）
    func moving(_ panel: DockPanel, toTabs tabsID: UUID, before: DockPanel?) -> DockNode
    /// 形だけ比べる（id を無視）。「変わらない置き方」の判定に使う
    func sameShape(as other: DockNode) -> Bool
}
```

`before` は **見えているタブ** の名前で受ける。木の中には閉じた・別ウィンドウのパネルも残っているので、番号では渡さない（今の `reordering` と同じ考え方）。

### ドラッグの状態

```swift
final class DockDragState: ObservableObject {
    static let shared = DockDragState()
    @Published private(set) var panel: DockPanel?            // つかんでいるパネル（nil = していない）
    @Published private(set) var source: UUID?
    @Published private(set) var target: DockDropTarget?      // たまにしか変わらない
    @Published private(set) var reordering = false
    let pointer = DockPointer()                              // 毎コマ変わる位置は別の入れ物に
}
final class DockPointer: ObservableObject { @Published var location: CGPoint = .zero }
```

**重くしないための決まり**：マウスの位置（毎コマ変わる）を見るのは、マウスの札と、並べ替え中のタブバーだけ。
パネルの中身（`DockPanelContent`）や区画の本体は、位置が変わっても描き直さない。
`DockTabsView` 本体は `DockDragState` を見ない。見るのは小さな子（タブバー、いちばん上の 1 枚）だけにする。
今 `DockTabsView` / `DockSplitView` / `DockRootView` が `drag` を見て重ねている `DockDropOverlay` / `DockBorderStrip` / `DockEdgeOverlay` は全部消す。
`begin` のタイマー（マウスを離したかの見張り）も、システムのドラッグをやめるので要らない。

### 画面

- `DockRootView`：`.coordinateSpace(name: "dockRoot")`、`.onPreferenceChange` で `DockGeometry` を集める（`@State`、`DockDragState` には入れない。`Equatable` で同じなら入れ直さない）。いちばん上に `DockDragOverlay`（光る四角・札・マウスの札）を `allowsHitTesting(false)` で重ねる。
- `DockTabBar`（`DockTabsView` から切り出す）：タブ・右のボタン。タブに `DragGesture(minimumDistance: 4, coordinateSpace: .named("dockRoot"))`。
- ウィンドウの外かどうか：`NSEvent.mouseLocation` と `NSApp.mainWindow?.frame`（ドラッグを始めたウィンドウを覚えておく）で見る。

### 保存

`LayoutManager.shared.state` を変えると、利用者の設定に保存される。変えるのは **離したとき 1 回だけ**。ドラッグ中は木を変えない（並べ替えの「ずれ」は見た目だけ）。

## 試す

### セルフテスト（`SelfTestTabsScenes.swift` に足す）

画面なしで、手で作った `DockGeometry` と木を使う。

- 四辺・境目・タブバー・区画の端・真ん中・外、それぞれで期待した `DockDropTarget` になる。優先の順（四辺 > 境目 > タブバー > 中身）。
- タブバーの位置：タブの中心の左右で `before` が変わる。最後より右は `nil`。
- 変わらない置き方は `nil`（自分だけの区画の真ん中、今と同じ位置）。
- `applying` の結果：`tabBar` で途中に入る・選んだタブがそのパネルになる／`zone`・`border`・`edge` は今の関数と同じ木の形。
- どの置き方でも、パネルは全部ちょうど 1 回ずつ残る（`normalized()` しても変わらない）。
- `isReordering`：帯の上下 14pt の境。

### 見た目（開発用の書き出し）

`--dock-drag-preview out.png x y [panel]`：決まった木（`DockNode.clubVJ`）を 1200×760 に描き、`panel`（なければ `scenes`）を (x, y) へドラッグしている途中の絵を書き出す。

- **`LayoutManager.shared.state` には触らない**。`DockRootView` に、木とドラッグの状態を外から渡せる入口を作る。エンジンは `Engine(persistent: false)`。
- 今ある `--dock-tabs-preview` も動くままにする。

## 決まり（このプロジェクトの）

- 利用者の設定（defaults `local.yama.vjplayer`、`~/Library/Application Support/Halo VJ/`）に書かない・消さない。
- 利用者の画面に触らない（キー・クリックを送らない。アプリを前に出さない）。
- 画面の言葉は日本語で書き、`Resources/en.lproj/Localizable.strings` に英語を足す。要らなくなった言葉の行は消す。
- コメントは今のコードと同じ調子の日本語。
- `site/docs/ja/free-layout.md` と `site/docs/en/free-layout.md` の「移動する」を新しい動きに書き直す。
- コミット・push はしない。
