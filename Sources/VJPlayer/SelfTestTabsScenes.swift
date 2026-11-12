import Foundation

// セルフテスト：自由レイアウトのタブの並べ替え・ドラッグの置き場所と、シーンの並べ替え（どちらも中身の計算だけ。保存はしない）

extension SelfTest {
    static func testTabsScenes(check: (Bool, String) -> Void) {
        let tid = UUID()
        let tree = DockNode.split(id: UUID(), axis: .horizontal, ratio: 0.5,
                                  first: .tabs(id: UUID(), panels: [.grid], selected: 0),
                                  second: .tabs(id: tid, panels: [.live, .scenes, .cues, .effects], selected: 1))
        func tabs(_ n: DockNode) -> ([DockPanel], DockPanel)? {
            guard case .tabs(_, let ps, let s)? = n.find(tid) else { return nil }
            return (ps, ps[s])
        }
        let a = tabs(tree.reordering(tid, .effects, before: .live))
        check(a?.0 == [.effects, .live, .scenes, .cues] && a?.1 == .scenes,
              "タブの並べ替え：前へ動かせて、選んでいるタブはそのまま")
        let b = tabs(tree.reordering(tid, .live, before: nil))
        check(b?.0 == [.scenes, .cues, .effects, .live] && b?.1 == .scenes, "タブの並べ替え：最後へ動かせる")
        let c = tabs(tree.reordering(tid, .scenes, before: .scenes))
        check(c?.0 == [.live, .scenes, .cues, .effects], "タブの並べ替え：自分の前へは何も変わらない")
        check(tree.reordering(tid, .grid, before: .live) == tree, "タブの並べ替え：ほかの区画のパネルは動かさない")
        testDockDrop(check: check)

        let e = Engine(persistent: false)
        e.scenes = ["A", "B", "C", "D"].map { e.captureScene(name: $0, fade: 0) }
        let ids = e.scenes.map(\.id)
        e.moveScene(ids[3], before: ids[0])
        let o1 = e.scenes.map(\.name)
        e.moveScene(ids[3], before: nil)
        let o2 = e.scenes.map(\.name)
        e.moveScene(ids[0], before: ids[2])
        let o3 = e.scenes.map(\.name)
        check(o1 == ["D", "A", "B", "C"] && o2 == ["A", "B", "C", "D"] && o3 == ["B", "A", "C", "D"],
              "シーンの並べ替え：前へ・最後へ・途中へ動かせる")
    }

    /// 自由レイアウトのドラッグ：手で作った画面の形と木で、置き場所の計算と、置いた結果を調べる
    static func testDockDrop(check: (Bool, String) -> Void) {
        // 左右に 2 つの区画：A（グリッド・出力モニター）｜B（ライブ・シーン・キュー）。全体は 1000×600
        let sid = UUID(), aid = UUID(), bid = UUID()
        let tree = DockNode.split(id: sid, axis: .horizontal, ratio: 0.5,
                                  first: .tabs(id: aid, panels: [.grid, .monitor], selected: 0),
                                  second: .tabs(id: bid, panels: [.live, .scenes, .cues], selected: 0))
        var g = DockGeometry(root: CGRect(x: 0, y: 0, width: 1000, height: 600))
        g.areas[aid] = .init(frame: CGRect(x: 0, y: 0, width: 496, height: 600), bar: CGRect(x: 0, y: 0, width: 496, height: 26),
                             tabs: [.grid: CGRect(x: 4, y: 2, width: 80, height: 22), .monitor: CGRect(x: 86, y: 2, width: 80, height: 22)],
                             order: [.grid, .monitor])
        g.areas[bid] = .init(frame: CGRect(x: 504, y: 0, width: 496, height: 600), bar: CGRect(x: 504, y: 0, width: 496, height: 26),
                             tabs: [.live: CGRect(x: 508, y: 2, width: 80, height: 22), .scenes: CGRect(x: 590, y: 2, width: 80, height: 22),
                                    .cues: CGRect(x: 672, y: 2, width: 80, height: 22)],
                             order: [.live, .scenes, .cues])
        g.borders[sid] = CGRect(x: 496, y: 0, width: 8, height: 600)
        func at(_ x: CGFloat, _ y: CGFloat, _ p: DockPanel = .grid, inside: Bool = true) -> DockDropTarget? {
            DockDropResolver.target(at: CGPoint(x: x, y: y), panel: p, geometry: g, tree: tree, insideWindow: inside, canDetach: p.window != nil)
        }

        // 置き場所と、優先の順（四辺 > 境目 > タブバー > 中身）
        check(at(5, 300) == .edge(.left) && at(995, 300) == .edge(.right) && at(300, 595) == .edge(.bottom),
              "ドラッグ：画面の四辺（外枠から 18pt）は、その辺いっぱい")
        check(at(500, 595) == .edge(.bottom) && at(503, 300) == .border(splitID: sid) && at(491, 300) == .border(splitID: sid)
              && at(486, 300) != .border(splitID: sid),
              "ドラッグ：区画の境目（線から ±9pt）。四辺と重なる所は四辺が先")
        check(at(494, 12) == .border(splitID: sid), "ドラッグ：境目はタブバーより先")
        check(at(600, 12) == .tabBar(tabsID: bid, before: .scenes) && at(547, 12) == .tabBar(tabsID: bid, before: .live)
              && at(549, 12) == .tabBar(tabsID: bid, before: .scenes) && at(900, 12) == .tabBar(tabsID: bid, before: nil),
              "ドラッグ：タブバーは、タブの中心の左なら前・右なら後ろ、最後より右は最後")
        check(at(600, 3) == .tabBar(tabsID: bid, before: .scenes), "ドラッグ：上の辺に重なるタブバーの上は、タブバーが先")
        check(at(520, 300) == .zone(tabsID: bid, .left) && at(970, 300) == .zone(tabsID: bid, .right)
              && at(750, 60) == .zone(tabsID: bid, .top) && at(750, 560) == .zone(tabsID: bid, .bottom)
              && at(750, 300) == .zone(tabsID: bid, .center) && at(530, 40) == .zone(tabsID: bid, .left),
              "ドラッグ：区画の中は、端から 25% までその側・内側はタブにする（角は近い方）")
        check(at(1200, 300, .monitor, inside: false) == .detach && at(1200, 300, .grid, inside: false) == nil,
              "ドラッグ：ウィンドウの外は、別ウィンドウに出せるパネルだけ「別ウィンドウに出す」")

        // 変わらない置き方は置けないのと同じ
        let single = DockNode.split(id: sid, axis: .horizontal, ratio: 0.5,
                                    first: .tabs(id: aid, panels: [.grid], selected: 0),
                                    second: .tabs(id: bid, panels: [.live, .scenes, .cues], selected: 0))
        func atSingle(_ x: CGFloat, _ y: CGFloat) -> DockDropTarget? {
            DockDropResolver.target(at: CGPoint(x: x, y: y), panel: .grid, geometry: g, tree: single, insideWindow: true, canDetach: false)
        }
        check(atSingle(250, 300) == nil && atSingle(30, 300) == nil && atSingle(250, 560) == nil,
              "ドラッグ：自分だけの区画の真ん中・端は、置けない（変わらない）")
        check(at(20, 12) == nil && at(120, 12, .monitor) == nil && at(180, 12) == .tabBar(tabsID: aid, before: nil),
              "ドラッグ：自分のタブバーの今と同じ位置は置けない・違う位置には置ける")
        check(at(800, 300, .cues) == nil, "ドラッグ：最後のタブを自分の区画の真ん中へは、変わらない")

        // 置いた結果
        let t1 = tree.applying(.tabBar(tabsID: bid, before: .scenes), panel: .grid)
        if case .tabs(_, let ps, let s)? = t1.find(bid), case .tabs(_, let pa, _)? = t1.find(aid) {
            check(ps == [.live, .grid, .scenes, .cues] && ps[s] == .grid && pa == [.monitor],
                  "ドラッグ：ほかの区画のタブバーに置くと、その位置に入って選ばれる")
        } else {
            check(false, "ドラッグ：ほかの区画のタブバーに置くと、その位置に入って選ばれる")
        }
        check(tree.applying(.zone(tabsID: bid, .left), panel: .grid).sameShape(as: tree.moving(.grid, to: bid, zone: .left))
              && tree.applying(.zone(tabsID: bid, .center), panel: .grid).sameShape(as: tree.moving(.grid, to: bid, zone: .center))
              && tree.applying(.border(splitID: sid), panel: .cues).sameShape(as: tree.movingToBorder(.cues, sid))
              && tree.applying(.edge(.bottom), panel: .grid).sameShape(as: tree.movingToEdge(.grid, .bottom))
              && tree.applying(.detach, panel: .monitor) == tree,
              "ドラッグ：区画の端・真ん中・境目・四辺は、今の動かし方と同じ形になる")
        check(DockNode.clubVJ.sameShape(as: DockNode.clubVJ) && !DockNode.clubVJ.sameShape(as: DockNode.cuePlayback)
              && DockNode.clubVJ != DockNode.clubVJ,
              "ドラッグ：形だけ比べる（id は見ない）")

        // どの置き方でも、パネルは全部ちょうど 1 回ずつ残る
        let full = DockNode.clubVJ
        var targets: [DockDropTarget] = [.edge(.left), .edge(.right), .edge(.top), .edge(.bottom)]
        func walk(_ n: DockNode) {
            switch n {
            case .tabs(let id, let ps, _):
                for z in [DockZone.center, .left, .right, .top, .bottom] { targets.append(.zone(tabsID: id, z)) }
                for b in ps + [nil] as [DockPanel?] { targets.append(.tabBar(tabsID: id, before: b)) }
            case .split(let id, _, _, let a, let b):
                targets.append(.border(splitID: id))
                walk(a)
                walk(b)
            }
        }
        walk(full)
        var allOK = true
        for p in DockPanel.allCases {
            for t in targets {
                let r = full.applying(t, panel: p)
                if r.panels.count != DockPanel.allCases.count || Set(r.panels) != Set(DockPanel.allCases) || r.normalized() != r {
                    allOK = false
                }
            }
        }
        check(allOK, "ドラッグ：どこへ置いても、パネルは全部ちょうど 1 回ずつ残る（\(targets.count * DockPanel.allCases.count) 通り）")

        // 並べ替えの段階：元のタブバーの帯（上下 14pt）
        func reo(_ y: CGFloat) -> Bool { DockDropResolver.isReordering(at: CGPoint(x: 100, y: y), source: aid, geometry: g) }
        check(reo(13) && reo(26 + 13) && !reo(26 + 15) && reo(-13) && !reo(-15) && !DockDropResolver.isReordering(at: CGPoint(x: 600, y: 13), source: aid, geometry: g),
              "ドラッグ：元のタブバーの上下 14pt までは並べ替え、それより外は動かす")
        // 並べ替えの位置：つかんだタブの真ん中で決める
        let slot = DockDropResolver.reorderSlot(of: .live, pointerX: 600 + 40, grabOffset: 40, in: g.areas[bid]!)
        let stay = DockDropResolver.reorderSlot(of: .scenes, pointerX: 590 + 20 + 30, grabOffset: 20, in: g.areas[bid]!)
        check(slot?.before == .cues && slot?.from == 0 && slot?.to == 1 && stay?.from == stay?.to,
              "ドラッグ：並べ替えは、つかんだタブの真ん中がほかのタブの中心を越えたら入れ替わる")
    }
}
