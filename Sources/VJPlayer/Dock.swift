import AppKit
import SwiftUI

// MARK: - 自由レイアウト（試験中）：画面を区画に分けて、パネルのタブをドラッグで好きな所へ置く

/// 区画に置くパネル
enum DockPanel: String, Codable, CaseIterable, Identifiable {
    case grid, monitor, pads, preview, params, live, scenes, cues, effects, generators, sources
    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: L("グリッド")
        case .monitor: L("出力モニター")
        case .pads: L("FX パッド")
        case .preview: L("プレビュー")
        case .params: L("パラメーター")
        case .live: L("ライブ")
        case .scenes: L("シーン")
        case .cues: L("キュー")
        case .effects: L("エフェクト")
        case .generators: L("ジェネレーター")
        case .sources: L("ソース")
        }
    }

    /// タブのアイコンの色（出力モニターとプレビューだけ。映像の枠・札と同じ色）
    var tint: Color? {
        switch self {
        case .monitor: UI.liveTint
        case .preview: UI.previewTint
        default: nil
        }
    }

    var icon: String {
        switch self {
        case .grid: "square.grid.3x3"
        case .monitor: "display"
        case .pads: "bolt.fill"
        case .preview: "eye"
        case .params: "slider.horizontal.3"
        case .live: "play.circle"
        case .scenes: "square.stack.3d.up"
        case .cues: "list.number"
        case .effects: "camera.filters"
        case .generators: "paintpalette"
        case .sources: "folder"
        }
    }

    /// 別ウィンドウに出せるときの、そのパネル
    var window: PanelID? { PanelID(rawValue: rawValue) }
}

enum DockAxis: String, Codable {
    /// 左右に並べる
    case horizontal
    /// 上下に並べる
    case vertical
}

/// 置き場所：区画の真ん中（タブとして足す）か、端（区画を分けてその側へ）
enum DockZone: Equatable {
    case center, left, right, top, bottom
}

/// 区画の木。分割（2 つに分ける）か、タブの並び
indirect enum DockNode: Codable, Equatable {
    case split(id: UUID, axis: DockAxis, ratio: Double, first: DockNode, second: DockNode)
    case tabs(id: UUID, panels: [DockPanel], selected: Int)

    var panels: [DockPanel] {
        switch self {
        case .split(_, _, _, let a, let b): a.panels + b.panels
        case .tabs(_, let p, _): p
        }
    }

    /// 最初の並べ方（今のメインのウィンドウと同じ形）
    static var standard: DockNode {
        let top = DockNode.split(id: UUID(), axis: .horizontal, ratio: 0.72,
                                 first: .tabs(id: UUID(), panels: [.grid], selected: 0),
                                 second: .tabs(id: UUID(), panels: [.monitor], selected: 0))
        let upper = DockNode.split(id: UUID(), axis: .vertical, ratio: 0.86,
                                   first: top, second: .tabs(id: UUID(), panels: [.pads], selected: 0))
        let inspector = DockNode.split(id: UUID(), axis: .horizontal, ratio: 0.32,
                                       first: .tabs(id: UUID(), panels: [.preview], selected: 0),
                                       second: .tabs(id: UUID(), panels: [.params], selected: 0))
        let lower = DockNode.split(id: UUID(), axis: .horizontal, ratio: 0.68,
                                   first: inspector,
                                   second: .tabs(id: UUID(), panels: [.live, .scenes, .cues, .effects, .generators, .sources], selected: 0))
        return .split(id: UUID(), axis: .vertical, ratio: 0.6, first: upper, second: lower)
    }

    private static func t(_ ps: [DockPanel], _ sel: Int = 0) -> DockNode { .tabs(id: UUID(), panels: ps, selected: sel) }
    private static func h(_ r: Double, _ a: DockNode, _ b: DockNode) -> DockNode { .split(id: UUID(), axis: .horizontal, ratio: r, first: a, second: b) }
    private static func v(_ r: Double, _ a: DockNode, _ b: DockNode) -> DockNode { .split(id: UUID(), axis: .vertical, ratio: r, first: a, second: b) }

    /// おすすめ：ポン出し用。左にグリッド（シーンはタブ）とプレビュー・パラメーター、
    /// 右にキューリストと出力モニター・ライブ、下いっぱいに FX パッド
    static var cuePlayback: DockNode {
        v(0.925,
          h(0.458,
            v(0.6, t([.grid, .scenes]), h(0.4, t([.preview]), t([.params, .effects, .generators, .sources]))),
            h(0.427, t([.cues]), v(0.607, t([.monitor]), t([.live])))),
          t([.pads]))
    }

    /// おすすめ：VJ 用。左にグリッド（大きく）とプレビュー・パラメーター・エフェクト、
    /// 右に出力モニターとライブ（シーン・キューはタブ）、下いっぱいに FX パッド
    static var clubVJ: DockNode {
        v(0.921,
          h(0.778,
            v(0.388, t([.grid]), h(0.327, t([.preview]), h(0.641, t([.params]), t([.effects, .generators, .sources])))),
            v(0.45, t([.monitor]), t([.live, .scenes, .cues]))),
          t([.pads]))
    }

    /// panel を取り除く（空になった区画は閉じる）。全部無くなれば nil
    func removing(_ panel: DockPanel) -> DockNode? {
        switch self {
        case .tabs(let id, var ps, let sel):
            guard let i = ps.firstIndex(of: panel) else { return self }
            ps.remove(at: i)
            guard !ps.isEmpty else { return nil }
            let s = sel > i ? sel - 1 : (sel == i ? min(i, ps.count - 1) : sel)
            return .tabs(id: id, panels: ps, selected: min(max(s, 0), ps.count - 1))
        case .split(let id, let axis, let r, let a, let b):
            let na = a.removing(panel), nb = b.removing(panel)
            switch (na, nb) {
            case (nil, nil): return nil
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (let x?, let y?): return .split(id: id, axis: axis, ratio: r, first: x, second: y)
            }
        }
    }

    /// panel を、tabsID の区画の zone に置く
    func inserting(_ panel: DockPanel, at tabsID: UUID, zone: DockZone) -> DockNode {
        switch self {
        case .tabs(let id, var ps, _) where id == tabsID:
            if zone == .center {
                ps.removeAll { $0 == panel }
                ps.append(panel)
                return .tabs(id: id, panels: ps, selected: ps.count - 1)
            }
            let new = DockNode.tabs(id: UUID(), panels: [panel], selected: 0)
            switch zone {
            case .left: return .split(id: UUID(), axis: .horizontal, ratio: 0.3, first: new, second: self)
            case .right: return .split(id: UUID(), axis: .horizontal, ratio: 0.7, first: self, second: new)
            case .top: return .split(id: UUID(), axis: .vertical, ratio: 0.3, first: new, second: self)
            case .bottom: return .split(id: UUID(), axis: .vertical, ratio: 0.7, first: self, second: new)
            case .center: return self
            }
        case .tabs:
            return self
        case .split(let id, let axis, let r, let a, let b):
            return .split(id: id, axis: axis, ratio: r, first: a.inserting(panel, at: tabsID, zone: zone),
                          second: b.inserting(panel, at: tabsID, zone: zone))
        }
    }

    /// 動かす：取り除いてから置く。置き先が自分だけの区画の真ん中なら何もしない
    func moving(_ panel: DockPanel, to tabsID: UUID, zone: DockZone) -> DockNode {
        if case .tabs(let id, let ps, _)? = find(tabsID), id == tabsID, ps == [panel] { return self }
        // 取り除くと置き先の区画が消える（その区画にそのパネルだけ）ことはない（上で除いた）。
        // 置き先の区画は id が変わらないので、取り除いたあとでも見つかる
        guard let removed = removing(panel) else { return .tabs(id: tabsID, panels: [panel], selected: 0) }
        return removed.inserting(panel, at: tabsID, zone: zone)
    }

    /// panel を画面全体の端に置く（その辺いっぱいに広がる。たとえばグリッドを左端に縦いっぱい）
    func movingToEdge(_ panel: DockPanel, _ zone: DockZone) -> DockNode {
        let new = DockNode.tabs(id: UUID(), panels: [panel], selected: 0)
        guard let rest = removing(panel) else { return new }
        // 下・右は細め、左・上は 3 割
        switch zone {
        case .left: return .split(id: UUID(), axis: .horizontal, ratio: 0.3, first: new, second: rest)
        case .right: return .split(id: UUID(), axis: .horizontal, ratio: 0.7, first: rest, second: new)
        case .top: return .split(id: UUID(), axis: .vertical, ratio: 0.3, first: new, second: rest)
        case .bottom: return .split(id: UUID(), axis: .vertical, ratio: 0.8, first: rest, second: new)
        case .center: return self
        }
    }

    func containsSplit(_ splitID: UUID) -> Bool {
        switch self {
        case .tabs: false
        case .split(let id, _, _, let a, let b): id == splitID || a.containsSplit(splitID) || b.containsSplit(splitID)
        }
    }

    /// panel を、splitID の境目に差し込む（その分割の向きに 1 列・1 段増やす。分割の長さいっぱい）
    func movingToBorder(_ panel: DockPanel, _ splitID: UUID) -> DockNode {
        guard let rest = removing(panel), rest.containsSplit(splitID) else { return self }
        return rest.insertingAtBorder(panel, splitID)
    }

    private func insertingAtBorder(_ panel: DockPanel, _ splitID: UUID) -> DockNode {
        switch self {
        case .tabs: return self
        case .split(let id, let axis, let r, let a, let b):
            if id == splitID {
                // 前の側はそのままの大きさで、後ろの側の頭に差し込む
                let new = DockNode.tabs(id: UUID(), panels: [panel], selected: 0)
                return .split(id: id, axis: axis, ratio: r, first: a,
                              second: .split(id: UUID(), axis: axis, ratio: 0.3, first: new, second: b))
            }
            return .split(id: id, axis: axis, ratio: r, first: a.insertingAtBorder(panel, splitID),
                          second: b.insertingAtBorder(panel, splitID))
        }
    }

    /// tabsID の区画の中で、panel のタブを before のタブの前へ（nil なら最後へ）動かす。選んでいるタブはそのまま
    func reordering(_ tabsID: UUID, _ panel: DockPanel, before: DockPanel?) -> DockNode {
        switch self {
        case .tabs(let id, var ps, let s) where id == tabsID:
            guard panel != before, let from = ps.firstIndex(of: panel) else { return self }
            let shown = ps[min(max(s, 0), ps.count - 1)]
            ps.remove(at: from)
            let to = before.flatMap { b in ps.firstIndex(of: b) } ?? ps.count
            ps.insert(panel, at: to)
            return .tabs(id: id, panels: ps, selected: ps.firstIndex(of: shown) ?? 0)
        case .tabs:
            return self
        case .split(let id, let axis, let r, let a, let b):
            return .split(id: id, axis: axis, ratio: r, first: a.reordering(tabsID, panel, before: before),
                          second: b.reordering(tabsID, panel, before: before))
        }
    }

    func find(_ tabsID: UUID) -> DockNode? {
        switch self {
        case .tabs(let id, _, _): return id == tabsID ? self : nil
        case .split(_, _, _, let a, let b): return a.find(tabsID) ?? b.find(tabsID)
        }
    }

    func settingRatio(_ splitID: UUID, _ ratio: Double) -> DockNode {
        switch self {
        case .tabs: return self
        case .split(let id, let axis, let r, let a, let b):
            if id == splitID { return .split(id: id, axis: axis, ratio: min(max(ratio, 0.05), 0.95), first: a, second: b) }
            return .split(id: id, axis: axis, ratio: r, first: a.settingRatio(splitID, ratio), second: b.settingRatio(splitID, ratio))
        }
    }

    /// tabsID の区画で、panel のタブを選ぶ
    func selecting(_ tabsID: UUID, panel: DockPanel) -> DockNode {
        guard case .tabs(_, let ps, _)? = find(tabsID), let i = ps.firstIndex(of: panel) else { return self }
        return selecting(tabsID, i)
    }

    func selecting(_ tabsID: UUID, _ index: Int) -> DockNode {
        switch self {
        case .tabs(let id, let ps, let s):
            return id == tabsID ? .tabs(id: id, panels: ps, selected: min(max(index, 0), ps.count - 1)) : .tabs(id: id, panels: ps, selected: s)
        case .split(let id, let axis, let r, let a, let b):
            return .split(id: id, axis: axis, ratio: r, first: a.selecting(tabsID, index), second: b.selecting(tabsID, index))
        }
    }

    /// 全部のパネルがちょうど 1 回ずつ入っているようにする（無いものはいちばん大きい区画へ足す）
    func normalized() -> DockNode {
        var seen = Set<DockPanel>()
        func dedupe(_ n: DockNode) -> DockNode? {
            switch n {
            case .tabs(let id, let ps, let s):
                let keep = ps.filter { seen.insert($0).inserted }
                return keep.isEmpty ? nil : .tabs(id: id, panels: keep, selected: min(s, keep.count - 1))
            case .split(let id, let axis, let r, let a, let b):
                let x = dedupe(a), y = dedupe(b)
                switch (x, y) {
                case (nil, nil): return nil
                case (let p?, nil): return p
                case (nil, let q?): return q
                case (let p?, let q?): return .split(id: id, axis: axis, ratio: r, first: p, second: q)
                }
            }
        }
        guard var out = dedupe(self) else { return .standard }
        // 後から増えたパネルは、近い仲間のいる区画へ（無ければ最初の区画）
        let buddy: [DockPanel: DockPanel] = [.cues: .scenes, .preview: .params, .sources: .effects]
        for p in DockPanel.allCases where !seen.contains(p) {
            let t = buddy[p].flatMap { out.tabsID(containing: $0) } ?? out.firstTabsID
            if let t { out = out.inserting(p, at: t, zone: .center) }
        }
        return out
    }

    func tabsID(containing p: DockPanel) -> UUID? {
        switch self {
        case .tabs(let id, let ps, _): ps.contains(p) ? id : nil
        case .split(_, _, _, let a, let b): a.tabsID(containing: p) ?? b.tabsID(containing: p)
        }
    }

    var firstTabsID: UUID? {
        switch self {
        case .tabs(let id, _, _): id
        case .split(_, _, _, let a, _): a.firstTabsID
        }
    }

    /// 表示用：別ウィンドウにしたパネルを除いた形（空の区画は閉じる）
    func pruned(_ hidden: Set<DockPanel>) -> DockNode? {
        var n: DockNode? = self
        for p in hidden { n = n?.removing(p) }
        return n
    }
}

extension DockNode {
    /// 置き場所の通りに動かした木（別ウィンドウに出すときは、木は変えない）
    func applying(_ t: DockDropTarget, panel: DockPanel) -> DockNode {
        switch t {
        case .tabBar(let id, let before): moving(panel, toTabs: id, before: before)
        case .zone(let id, let z): moving(panel, to: id, zone: z)
        case .border(let s): movingToBorder(panel, s)
        case .edge(let z): movingToEdge(panel, z)
        case .detach: self
        }
    }

    /// panel を、tabsID の区画のタブの並びの before の前へ（nil なら最後へ）入れて選ぶ。
    /// before は見えているタブの名前で受ける（木の中には閉じた・別ウィンドウのパネルも残っているので、番号では渡さない）
    func moving(_ panel: DockPanel, toTabs tabsID: UUID, before: DockPanel?) -> DockNode {
        // 置き先の区画がそのパネルだけで、取り除くと消えてしまうときは何もしない
        guard panel != before, let removed = removing(panel), removed.find(tabsID) != nil else { return self }
        return removed.insertingTab(panel, at: tabsID, before: before)
    }

    private func insertingTab(_ panel: DockPanel, at tabsID: UUID, before: DockPanel?) -> DockNode {
        switch self {
        case .tabs(let id, var ps, _) where id == tabsID:
            let i = before.flatMap { ps.firstIndex(of: $0) } ?? ps.count
            ps.insert(panel, at: i)
            return .tabs(id: id, panels: ps, selected: i)
        case .tabs:
            return self
        case .split(let id, let axis, let r, let a, let b):
            return .split(id: id, axis: axis, ratio: r, first: a.insertingTab(panel, at: tabsID, before: before),
                          second: b.insertingTab(panel, at: tabsID, before: before))
        }
    }

    /// 形だけ比べる（区画・分割の id と、選んでいるタブは見ない）。「置いても変わらない」の判定に使う
    func sameShape(as other: DockNode) -> Bool {
        switch (self, other) {
        case (.tabs(_, let a, _), .tabs(_, let b, _)):
            return a == b
        case (.split(_, let x1, let r1, let a1, let b1), .split(_, let x2, let r2, let a2, let b2)):
            return x1 == x2 && abs(r1 - r2) < 0.0001 && a1.sameShape(as: a2) && b1.sameShape(as: b2)
        default:
            return false
        }
    }
}

// MARK: - ドラッグ：置き場所の計算（画面なしで試せる）

/// パネルを置く場所
enum DockDropTarget: Equatable {
    /// 区画のタブバーの、before の前（nil は最後）
    case tabBar(tabsID: UUID, before: DockPanel?)
    /// 区画の真ん中（最後のタブとして足す）か、端（分けてその側へ）
    case zone(tabsID: UUID, DockZone)
    /// 区画の境目に 1 列・1 段差し込む
    case border(splitID: UUID)
    /// 画面の辺いっぱい
    case edge(DockZone)
    /// メインのウィンドウの外：別ウィンドウに出す
    case detach
}

/// 画面の形。座標は DockRootView の "dockRoot"
struct DockGeometry: Equatable {
    /// 自由レイアウト全体（外の余白は含まない）
    var root: CGRect = .zero
    /// 区画
    var areas: [UUID: Area] = [:]
    /// 境目（つまみの四角）
    var borders: [UUID: CGRect] = [:]

    struct Area: Equatable {
        /// 区画全体
        var frame: CGRect = .zero
        /// タブバー
        var bar: CGRect = .zero
        /// 見えているタブ（並べ替えでずらす前の位置）
        var tabs: [DockPanel: CGRect] = [:]
        /// 見えているタブの並び（左から）
        var order: [DockPanel] = []
    }

    /// 下の画面から上がってきた分を足し合わせる
    mutating func merge(_ o: DockGeometry) {
        if o.root != .zero { root = o.root }
        borders.merge(o.borders) { $1 }
        for (id, b) in o.areas {
            var a = areas[id] ?? Area()
            if b.frame != .zero { a.frame = b.frame }
            if b.bar != .zero { a.bar = b.bar }
            if !b.tabs.isEmpty {
                a.tabs.merge(b.tabs) { $1 }
                a.order = a.tabs.keys.sorted { a.tabs[$0]!.minX < a.tabs[$1]!.minX }
            }
            areas[id] = a
        }
    }
}

struct DockGeometryKey: PreferenceKey {
    static var defaultValue: DockGeometry { DockGeometry() }
    static func reduce(value: inout DockGeometry, nextValue: () -> DockGeometry) { value.merge(nextValue()) }
}

enum DockDropResolver {
    /// 画面の四辺：外枠から内へ
    static let edgeBand: CGFloat = 18
    /// 境目：線から両側へ
    static let borderBand: CGFloat = 9
    /// 並べ替えの帯：タブバーの上下へ
    static let reorderBand: CGFloat = 14
    /// 区画の端（分けて置く）：端からこの割合まで
    static let sideFraction: CGFloat = 0.25

    /// マウスの位置から置き場所を決める。置けない・置いても変わらないなら nil
    static func target(at p: CGPoint, panel: DockPanel, geometry g: DockGeometry,
                       tree: DockNode, insideWindow: Bool, canDetach: Bool) -> DockDropTarget? {
        guard insideWindow else { return canDetach ? .detach : nil }
        guard let t = rawTarget(at: p, panel: panel, geometry: g) else { return nil }
        // 置いた結果の木が今と同じ形なら、置けないのと同じ（光らせない）
        return tree.applying(t, panel: panel).sameShape(as: tree) ? nil : t
    }

    /// 上から順に調べて、最初に当たったもの（変わるかどうかは見ない）
    static func rawTarget(at p: CGPoint, panel: DockPanel, geometry g: DockGeometry) -> DockDropTarget? {
        let bar = g.areas.first { $0.value.bar.contains(p) }
        // 上の辺は区画のタブバーと重なるので、タブバーの上ではタブバーを先にする（四辺 > タブバーの例外）
        if bar == nil, let e = edge(at: p, root: g.root) { return .edge(e) }
        if let s = border(at: p, g) { return .border(splitID: s) }
        if let b = bar { return .tabBar(tabsID: b.key, before: insertion(of: panel, x: p.x, in: b.value).before) }
        if let a = g.areas.first(where: { $0.value.frame.contains(p) }) {
            return .zone(tabsID: a.key, zone(at: p, in: a.value.frame))
        }
        return nil
    }

    /// 画面の四辺（外の余白の上も含める）
    static func edge(at p: CGPoint, root r: CGRect) -> DockZone? {
        let pad = DockRootView.padding
        guard r.width > 0, r.insetBy(dx: -pad, dy: -pad).contains(p),
              !r.insetBy(dx: edgeBand, dy: edgeBand).contains(p) else { return nil }
        let d: [(DockZone, CGFloat)] = [(.left, p.x - r.minX), (.right, r.maxX - p.x), (.top, p.y - r.minY), (.bottom, r.maxY - p.y)]
        return d.min { $0.1 < $1.1 }!.0
    }

    /// 境目：つまみの線から ±borderBand。重なるときは近い方
    static func border(at p: CGPoint, _ g: DockGeometry) -> UUID? {
        var best: (UUID, CGFloat)?
        for (id, r) in g.borders where r.width > 0 || r.height > 0 {
            let vertical = r.height >= r.width
            let d = vertical ? abs(p.x - r.midX) : abs(p.y - r.midY)
            let along = vertical ? (p.y >= r.minY && p.y <= r.maxY) : (p.x >= r.minX && p.x <= r.maxX)
            if along, d <= borderBand, d < (best?.1 ?? .infinity) { best = (id, d) }
        }
        return best?.0
    }

    /// 区画の中：端から 25% まではその側（角は近い方）、それより内側は真ん中
    static func zone(at p: CGPoint, in f: CGRect) -> DockZone {
        let x = (p.x - f.minX) / max(f.width, 1), y = (p.y - f.minY) / max(f.height, 1)
        let d: [(DockZone, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        let m = d.min { $0.1 < $1.1 }!
        return m.1 < sideFraction ? m.0 : .center
    }

    /// タブバーの x に入れるとき：ほかのタブの中心より左なら前。before と、ほかのタブの中での番号
    static func insertion(of panel: DockPanel, x: CGFloat, in a: DockGeometry.Area) -> (before: DockPanel?, index: Int) {
        let others = a.order.filter { $0 != panel }
        let k = others.filter { (a.tabs[$0]?.midX ?? 0) < x }.count
        return (k < others.count ? others[k] : nil, k)
    }

    /// 並べ替えの段階で、今離すとどこに入るか（つかんだタブの真ん中で決める）。from == to なら動かない
    static func reorderSlot(of panel: DockPanel, pointerX: CGFloat, grabOffset: CGFloat,
                            in a: DockGeometry.Area) -> (before: DockPanel?, from: Int, to: Int)? {
        guard let f = a.tabs[panel], let from = a.order.firstIndex(of: panel) else { return nil }
        let s = insertion(of: panel, x: pointerX - grabOffset + f.width / 2, in: a)
        return (s.before, from, s.index)
    }

    /// 元のタブバーの帯（上下に reorderBand の余裕）の中か = 並べ替えの段階か
    static func isReordering(at p: CGPoint, source: UUID, geometry g: DockGeometry) -> Bool {
        guard let b = g.areas[source]?.bar, b.width > 0 else { return false }
        return b.insetBy(dx: 0, dy: -reorderBand).contains(p)
    }

    /// 光らせる四角（実際に置かれる大きさではなく、分かりやすさ優先）
    static func highlight(_ t: DockDropTarget, geometry g: DockGeometry) -> CGRect? {
        switch t {
        case .tabBar(let id, _):
            return g.areas[id]?.bar
        case .zone(let id, let z):
            guard let f = g.areas[id]?.frame else { return nil }
            switch z {
            case .center: return f
            case .left: return CGRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height)
            case .right: return CGRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height)
            case .top: return CGRect(x: f.minX, y: f.minY, width: f.width, height: f.height / 2)
            case .bottom: return CGRect(x: f.minX, y: f.midY, width: f.width, height: f.height / 2)
            }
        case .border(let s):
            guard let r = g.borders[s] else { return nil }
            return r.height >= r.width ? CGRect(x: r.midX - 20, y: r.minY, width: 40, height: r.height)
                : CGRect(x: r.minX, y: r.midY - 20, width: r.width, height: 40)
        case .edge(let z):
            let r = g.root
            switch z {
            case .left: return CGRect(x: r.minX, y: r.minY, width: r.width * 0.3, height: r.height)
            case .right: return CGRect(x: r.maxX - r.width * 0.3, y: r.minY, width: r.width * 0.3, height: r.height)
            case .top: return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.3)
            case .bottom: return CGRect(x: r.minX, y: r.maxY - r.height * 0.2, width: r.width, height: r.height * 0.2)
            case .center: return nil
            }
        case .detach:
            return nil
        }
    }

    /// タブバーに入れるときの、青い縦線の x
    static func insertLineX(_ t: DockDropTarget, panel: DockPanel, geometry g: DockGeometry) -> CGFloat? {
        guard case .tabBar(let id, let before) = t, let a = g.areas[id] else { return nil }
        if let b = before, let r = a.tabs[b] { return r.minX - 1 }
        return a.order.filter { $0 != panel }.last.flatMap { a.tabs[$0]?.maxX }.map { $0 + 1 } ?? a.bar.minX + 4
    }

    /// 光らせた所の真ん中に出す言葉
    static func label(_ t: DockDropTarget) -> String? {
        switch t {
        case .tabBar, .detach: nil
        case .zone(_, let z):
            switch z {
            case .center: L("タブにする")
            case .left: L("左に置く")
            case .right: L("右に置く")
            case .top: L("上に置く")
            case .bottom: L("下に置く")
            }
        case .border: L("ここに差し込む")
        case .edge(let z):
            switch z {
            case .left: L("左端いっぱい")
            case .right: L("右端いっぱい")
            case .top: L("上いっぱい")
            case .bottom: L("下いっぱい")
            case .center: nil
            }
        }
    }
}

// MARK: - ドラッグの状態

/// ドラッグ中のマウスの位置（毎コマ変わるので、見るのはマウスの札だけ）
final class DockPointer: ObservableObject {
    @Published var location: CGPoint = .zero
}

/// いまドラッグしているパネル。タブをつかんで、元のタブバーの中なら並べ替え、外へ出たら置き場所を 1 つ決める。
/// 木を変えるのは離したときの 1 回だけ（ドラッグ中は変えない）
final class DockDragState: ObservableObject {
    static let shared = DockDragState(
        tree: { LayoutManager.shared.state.dock },
        hidden: { DockRootView.hiddenPanels(LayoutManager.shared) },
        commit: { LayoutManager.shared.state.dock = $0 },
        detach: { p, at in LayoutManager.shared.detach(p, at: at) })

    /// 開発用：決まった木で描くとき（どこにも保存しない）
    static func preview(tree: DockNode) -> DockDragState {
        DockDragState(tree: { tree }, hidden: { [] }, commit: { _ in }, detach: { _, _ in })
    }

    /// つかんでいるパネル（nil = していない）
    @Published private(set) var panel: DockPanel?
    /// つかんだ区画
    @Published private(set) var source: UUID?
    /// 今離したときの置き場所（たまにしか変わらない）
    @Published private(set) var target: DockDropTarget?
    /// 元のタブバーの中で並べ替えている
    @Published private(set) var reordering = false
    /// 毎コマ変わる位置は別の入れ物に
    let pointer = DockPointer()
    /// 区画・境目の四角（DockRootView が入れる。描き直しのきっかけにはしない）
    var geometry = DockGeometry()
    /// つかんだ所の、タブの左端からの距離
    private(set) var grabOffset: CGFloat = 0
    /// タブをつかんだか（タブバーの空き = 最初から「動かす」）
    private var allowReorder = true
    /// Esc で取り消したドラッグの始まりの位置（離すまで、もう始めない）
    private var cancelledStart: CGPoint?
    private weak var window: NSWindow?
    private var keyMonitor: Any?
    /// ウィンドウの外で出す札
    private var outsideChip: NSPanel?
    private var outsideChipPanel: DockPanel?

    private let tree: () -> DockNode?
    private let hidden: () -> Set<DockPanel>
    private let commit: (DockNode) -> Void
    private let detach: (PanelID, NSPoint) -> Void

    init(tree: @escaping () -> DockNode?, hidden: @escaping () -> Set<DockPanel>,
         commit: @escaping (DockNode) -> Void, detach: @escaping (PanelID, NSPoint) -> Void) {
        self.tree = tree
        self.hidden = hidden
        self.commit = commit
        self.detach = detach
    }

    /// 見えている木（閉じた・別ウィンドウのパネルを除く）
    private func displayed() -> DockNode? { tree()?.pruned(hidden()) }

    /// 木を変える（タブを選ぶ・境目を動かす。変わらなければ何もしない）
    func edit(_ f: (DockNode) -> DockNode) {
        guard let t = tree() else { return }
        let n = f(t)
        if n != t { commit(n) }
    }

    /// DragGesture の onChanged から。最初の 1 回で始める
    func changed(panel p: DockPanel, source s: UUID, fromTab: Bool, start: CGPoint, location: CGPoint) {
        if let c = cancelledStart {
            if c == start { return }
            cancelledStart = nil
        }
        if panel == nil { begin(p, source: s, fromTab: fromTab, start: start) }
        guard panel == p, source == s else { return }
        update(location)
    }

    private func begin(_ p: DockPanel, source s: UUID, fromTab: Bool, start: CGPoint) {
        let f = geometry.areas[s]?.tabs[p]
        grabOffset = fromTab ? start.x - (f?.minX ?? start.x) : 0
        allowReorder = fromTab
        window = NSApp.currentEvent?.window ?? NSApp.keyWindow
        // ドラッグの間だけ Esc を見る
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53, let self, self.panel != nil else { return e }
            self.cancel(start: start)
            return nil
        }
        panel = p
        source = s
    }

    /// マウスが動いた。insideWindow を渡さなければ、ドラッグを始めたウィンドウの中かをマウスの位置で見る
    func update(_ loc: CGPoint, insideWindow: Bool? = nil) {
        guard let p = panel, let s = source else { return }
        let inside = insideWindow ?? window.map { $0.frame.contains(NSEvent.mouseLocation) } ?? true
        let r = allowReorder && inside && DockDropResolver.isReordering(at: loc, source: s, geometry: geometry)
        if reordering != r { reordering = r }
        let t: DockDropTarget? = r ? nil : displayed().flatMap {
            DockDropResolver.target(at: loc, panel: p, geometry: geometry, tree: $0,
                                    insideWindow: inside, canDetach: p.window != nil)
        }
        if target != t { target = t }
        if !r { pointer.location = loc }
        if insideWindow == nil { showOutsideChip(!inside) }
    }

    /// DragGesture の onEnded から。置ける所なら木を 1 回だけ変える
    func finish(_ loc: CGPoint) {
        defer { reset() }
        guard cancelledStart == nil, let p = panel, let s = source else { return }
        update(loc)
        guard let full = tree() else { return }
        var next = full
        if reordering {
            if let a = geometry.areas[s],
               let slot = DockDropResolver.reorderSlot(of: p, pointerX: loc.x, grabOffset: grabOffset, in: a),
               slot.from != slot.to {
                next = full.reordering(s, p, before: slot.before)
            }
            next = next.selecting(s, panel: p)
        } else if target == .detach, let w = p.window {
            detach(w, NSEvent.mouseLocation)
            return
        } else if let t = target {
            next = full.applying(t, panel: p)
        } else {
            // 置けない所：つかんだときに見せたタブを選んだままにするだけ
            next = full.selecting(s, panel: p)
        }
        guard next != full else { return }
        withAnimation(.easeOut(duration: 0.18)) { commit(next) }
    }

    /// Esc：何も変えずに終わる（そのあと onEnded が来ても何もしない）
    func cancel(start: CGPoint) {
        guard panel != nil else { return }
        cancelledStart = start
        clear()
    }

    private func reset() {
        cancelledStart = nil
        clear()
    }

    private func clear() {
        if let m = keyMonitor {
            keyMonitor = nil
            DispatchQueue.main.async { NSEvent.removeMonitor(m) }
        }
        window = nil
        showOutsideChip(false)
        if panel != nil { panel = nil }
        if source != nil { source = nil }
        if target != nil { target = nil }
        if reordering { reordering = false }
    }

    /// 開発用：panel を loc までドラッグしている途中にする（木は変えない。Esc も見ない）
    func preview(_ p: DockPanel, at loc: CGPoint, insideWindow: Bool) {
        guard let s = displayed()?.tabsID(containing: p) else { return }
        grabOffset = (geometry.areas[s]?.tabs[p]?.width ?? 0) / 2
        allowReorder = true
        panel = p
        source = s
        pointer.location = loc
        update(loc, insideWindow: insideWindow)
    }

    /// メインのウィンドウの外では、画面の上に小さな札を出す（「別ウィンドウに出す」）
    private func showOutsideChip(_ show: Bool) {
        guard show, let p = panel else {
            outsideChip?.orderOut(nil)
            return
        }
        let w: NSPanel
        if let c = outsideChip {
            w = c
        } else {
            w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .floating
            w.appearance = NSAppearance(named: .darkAqua)
            outsideChip = w
        }
        let canDetach = p.window != nil
        if outsideChipPanel != p {
            outsideChipPanel = p
            let v = NSHostingView(rootView: DockChipLabel(panel: p, detach: canDetach).padding(8).opacity(canDetach ? 1 : 0.5))
            w.contentView = v
            w.setContentSize(v.fittingSize)
        }
        let m = NSEvent.mouseLocation
        w.setFrameOrigin(NSPoint(x: m.x + 12 - 8, y: m.y - 12 - w.frame.height + 8))
        if !w.isVisible { w.orderFront(nil) }
    }
}

/// 区画を一時的にいっぱいに広げる（保存しない）
struct DockMaximize {
    var current: UUID?
    var set: (UUID?) -> Void = { _ in }
    func toggle(_ id: UUID) { set(current == id ? nil : id) }
}

private struct DockMaximizeKey: EnvironmentKey { static var defaultValue: DockMaximize { DockMaximize() } }
private struct DockPlaceholdersKey: EnvironmentKey { static var defaultValue: Bool { false } }
private struct DockDragKey: EnvironmentKey { static var defaultValue: DockDragState { .shared } }

extension EnvironmentValues {
    fileprivate var dockMaximize: DockMaximize {
        get { self[DockMaximizeKey.self] }
        set { self[DockMaximizeKey.self] = newValue }
    }
    /// 開発用：パネルの中身の代わりに名前だけ描く
    fileprivate var dockPlaceholders: Bool {
        get { self[DockPlaceholdersKey.self] }
        set { self[DockPlaceholdersKey.self] = newValue }
    }
    /// ドラッグの状態（見るだけで、変わっても描き直さない）
    fileprivate var dockDrag: DockDragState {
        get { self[DockDragKey.self] }
        set { self[DockDragKey.self] = newValue }
    }
}

// MARK: - 画面

/// 自由レイアウトのメインの画面（上のバーと下の状態表示の間）
struct DockRootView: View {
    static let space = "dockRoot"
    /// 外の余白
    static let padding: CGFloat = 8
    @ObservedObject private var layout = LayoutManager.shared
    /// 開発用：決まった木（nil = 利用者の設定のもの）
    private let previewTree: DockNode?
    private let placeholders: Bool
    /// ドラッグの状態。ここでは見ない（見るのはタブバー・いちばん上の 1 枚だけ）
    private let drag: DockDragState
    @State private var geometry = DockGeometry()
    /// ダブルクリックで一時的に広げている区画
    @State private var maximized: UUID?

    init() {
        previewTree = nil
        placeholders = false
        drag = .shared
    }

    /// 開発用：決まった木とドラッグの状態で描く（利用者の設定には触らない）
    init(previewTree: DockNode, drag: DockDragState, placeholders: Bool) {
        self.previewTree = previewTree
        self.drag = drag
        self.placeholders = placeholders
    }

    /// 別ウィンドウにした・閉じたパネル（区画には出さない）
    static func hiddenPanels(_ layout: LayoutManager) -> Set<DockPanel> {
        Set(DockPanel.allCases.filter { ($0.window.map(layout.isDetached) ?? false) || layout.isClosed($0) })
    }

    var body: some View {
        let tree: DockNode? = previewTree ?? layout.state.dock?.pruned(Self.hiddenPanels(layout))
        let m = maximized.flatMap { tree?.find($0) != nil ? $0 : nil }
        Group {
            if let tree {
                DockNodeView(node: tree)
                    .equatable()
                    .background(GeometryReader { g in
                        Color.clear.preference(key: DockGeometryKey.self, value: DockGeometry(root: g.frame(in: .named(Self.space))))
                    })
            } else {
                Text(L("パネルはすべて別ウィンドウに出しています"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(Self.padding)
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(DockGeometryKey.self) { g in
            guard g != geometry else { return }
            geometry = g
            drag.geometry = g
        }
        // ドラッグ中の絵（光る四角・札・マウスの札）は、いちばん上に 1 枚だけ
        .overlay { DockDragOverlay(geometry: geometry).allowsHitTesting(false) }
        .environment(\.dockMaximize, DockMaximize(current: m, set: { maximized = $0 }))
        .environment(\.dockPlaceholders, placeholders)
        .environment(\.dockDrag, drag)
        .environmentObject(drag)
    }
}

private struct DockNodeView: View, Equatable {
    let node: DockNode

    var body: some View {
        switch node {
        case .tabs(let id, let panels, let selected):
            DockTabsView(id: id, panels: panels, selected: selected)
        case .split(let id, let axis, let ratio, let first, let second):
            DockSplitView(id: id, axis: axis, ratio: ratio, first: first, second: second)
        }
    }
}

private struct DockSplitView: View {
    let id: UUID
    let axis: DockAxis
    let ratio: Double
    let first: DockNode
    let second: DockNode
    @State private var start: Double?
    @Environment(\.dockDrag) private var drag
    @Environment(\.dockMaximize) private var maximize
    static let handle: CGFloat = 8

    var body: some View {
        GeometryReader { g in
            let total = axis == .horizontal ? g.size.width : g.size.height
            // 区画を広げているときは、そちら側だけを描く（並びは同じままにして、つかんだタブのドラッグが続くように）
            let m = maximize.current
            let showA = m.map { first.find($0) != nil } ?? true
            let showB = m.map { second.find($0) != nil } ?? true
            let both = showA == showB
            let hw = both ? Self.handle : 0
            let a = both ? max((total - hw) * CGFloat(ratio), 0) : (showA ? total : 0)
            let b = max(total - hw - a, 0)
            let h = SplitHandle(axis: axis == .horizontal ? .vertical : .horizontal, onDrag: { d in
                let s = start ?? ratio
                start = s
                let r = s + Double(d / max(total - Self.handle, 1))
                drag.edit { $0.settingRatio(id, r) }
            }, onEnd: { start = nil })
                .opacity(both ? 1 : 0)
                .background(GeometryReader { hg in
                    Color.clear.preference(key: DockGeometryKey.self,
                                           value: both ? DockGeometry(borders: [id: hg.frame(in: .named(DockRootView.space))]) : DockGeometry())
                })
            if axis == .horizontal {
                HStack(spacing: 0) {
                    side(first, both || showA).frame(width: a)
                    h.frame(width: hw)
                    side(second, both || showB).frame(width: b)
                }
            } else {
                VStack(spacing: 0) {
                    side(first, both || showA).frame(height: a)
                    h.frame(height: hw)
                    side(second, both || showB).frame(height: b)
                }
            }
        }
    }

    @ViewBuilder private func side(_ n: DockNode, _ show: Bool) -> some View {
        if show { DockNodeView(node: n) } else { Color.clear }
    }
}

/// 1 つの区画：上にタブバー、下に選んだパネル。
/// ここ自体はドラッグの状態を見ない（毎コマ描き直さない）。見るのはタブバーと中身の小さな入れ物だけ
struct DockTabsView: View {
    let id: UUID
    let panels: [DockPanel]
    let selected: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DockTabBar(id: id, panels: panels, selected: selected)
            DockAreaContent(id: id, panels: panels, selected: selected)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.panelBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(GeometryReader { g in
            Color.clear.preference(key: DockGeometryKey.self,
                                   value: DockGeometry(areas: [id: .init(frame: g.frame(in: .named(DockRootView.space)))]))
        })
    }
}

/// 区画の中身。ドラッグを始めたら、つかんだタブの中身を見せる（木は離すまで変えない）
private struct DockAreaContent: View {
    let id: UUID
    let panels: [DockPanel]
    let selected: Int
    @EnvironmentObject private var drag: DockDragState
    @Environment(\.dockPlaceholders) private var placeholders

    var body: some View {
        let sel = min(max(selected, 0), panels.count - 1)
        let shown = (drag.source == id ? drag.panel : nil).flatMap { panels.contains($0) ? $0 : nil } ?? panels[sel]
        GeometryReader { g in
            Group {
                if placeholders {
                    DockPanelPlaceholder(panel: shown)
                } else {
                    DockPanelContent(panel: shown, size: g.size)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            // 区画からはみ出した分は隣に描かない
            .clipped()
        }
    }
}

/// 区画のタブバー。タブをつかんで、バーの中なら並べ替え、外へ出たらパネルを動かす
private struct DockTabBar: View {
    let id: UUID
    let panels: [DockPanel]
    let selected: Int
    @EnvironmentObject private var drag: DockDragState
    @Environment(\.dockMaximize) private var maximize
    /// 並べ替え中のマウスの x（毎コマ変わる。描き直すのはこのタブバーだけ）
    @State private var pointerX: CGFloat?
    /// タブを並べられる幅
    @State private var room: CGFloat = 0
    static let spacing: CGFloat = 2

    var body: some View {
        let sel = min(max(selected, 0), panels.count - 1)
        let dragging = (drag.source == id ? drag.panel : nil).flatMap { panels.contains($0) ? $0 : nil }
        let shown = dragging ?? panels[sel]
        // 入りきらないときは、選んでいるもの（木の上で。ドラッグ中に形が変わらないように）だけ名前つき
        let compact = Self.needsCompact(panels, room: room)
        let shifts = reorderShifts(dragging)
        HStack(spacing: 4) {
            HStack(spacing: Self.spacing) {
                ForEach(Array(panels.enumerated()), id: \.element) { i, p in
                    DockTab(panel: p, on: p == shown, titled: !compact || i == sel,
                            lifted: dragging == p && drag.reordering, ghost: dragging == p && !drag.reordering,
                            canLeft: i > 0, canRight: i < panels.count - 1,
                            select: { drag.edit { $0.selecting(id, panel: p) } },
                            shift: { d in
                                let j = i + d
                                guard panels.indices.contains(j) else { return }
                                let before: DockPanel? = d < 0 ? panels[j] : (j + 1 < panels.count ? panels[j + 1] : nil)
                                drag.edit { $0.reordering(id, p, before: before) }
                            },
                            maximize: { maximize.toggle(id) })
                        .offset(x: shifts[p] ?? 0)
                        .animation(dragging == p ? nil : .easeOut(duration: 0.15), value: shifts[p] ?? 0)
                        .zIndex(dragging == p ? 1 : 0)
                        // ずらす前の位置を伝える（offset の外側の background なので、ずれは入らない）
                        .background(GeometryReader { g in
                            Color.clear.preference(key: DockGeometryKey.self,
                                                   value: DockGeometry(areas: [id: .init(tabs: [p: g.frame(in: .named(DockRootView.space))])]))
                        })
                        .gesture(dragGesture(p, fromTab: true))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { g in
                    // タブの右の空き：つかむと、今表示しているパネルを動かす。ダブルクリックで広げる
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(dragGesture(panels[sel], fromTab: false))
                        .onTapGesture(count: 2) { maximize.toggle(id) }
                        .onAppear { room = g.size.width }
                        .onChange(of: g.size.width) { _, w in room = w }
                }
            }
            if maximize.current == id {
                Button { maximize.set(nil) } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 10, weight: .semibold))
                }
                .controlSize(.small)
                .help(L("元の大きさに戻す（タブのダブルクリックでも戻る）"))
            }
            if let w = shown.window { DetachButton(panel: w) }
            PanelCloseButton(panel: shown)
        }
        .padding(.horizontal, 4)
        .frame(height: 26)
        .background(GeometryReader { g in
            Color.clear.preference(key: DockGeometryKey.self,
                                   value: DockGeometry(areas: [id: .init(bar: g.frame(in: .named(DockRootView.space)))]))
        })
    }

    private func dragGesture(_ p: DockPanel, fromTab: Bool) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(DockRootView.space))
            .onChanged { v in
                // 広げている区画からつかんだら、元に戻してから
                if drag.panel == nil, maximize.current != nil { maximize.set(nil) }
                drag.changed(panel: p, source: id, fromTab: fromTab, start: v.startLocation, location: v.location)
                let x: CGFloat? = drag.reordering && drag.source == id ? v.location.x : nil
                if pointerX != x { pointerX = x }
            }
            .onEnded { v in
                pointerX = nil
                drag.finish(v.location)
            }
    }

    /// 並べ替え中の、タブごとの横のずれ（つかんだタブはマウスについて、ほかは場所を空ける）
    private func reorderShifts(_ dragging: DockPanel?) -> [DockPanel: CGFloat] {
        guard let p = dragging, drag.reordering, let a = drag.geometry.areas[id], let f = a.tabs[p] else { return [:] }
        // 開発用の書き出しではマウスの位置を状態から読む（ここでは見るだけ。毎コマの描き直しのきっかけにはしない）
        let x = pointerX ?? drag.pointer.location.x
        guard let slot = DockDropResolver.reorderSlot(of: p, pointerX: x, grabOffset: drag.grabOffset, in: a) else { return [:] }
        var out: [DockPanel: CGFloat] = [p: x - drag.grabOffset - f.minX]
        let w = f.width + Self.spacing
        let others = a.order.filter { $0 != p }
        if slot.to < slot.from {
            for q in others[slot.to..<slot.from] { out[q] = w }
        } else if slot.to > slot.from {
            for q in others[slot.from..<min(slot.to, others.count)] { out[q] = -w }
        }
        return out
    }

    /// 名前つきのタブの幅（だいたい）
    static func titledWidth(_ p: DockPanel) -> CGFloat {
        let t = (p.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
        return ceil(t) + 16 + 14 + 4
    }

    static func needsCompact(_ ps: [DockPanel], room: CGFloat) -> Bool {
        room > 0 && ps.map(titledWidth).reduce(0, +) + spacing * CGFloat(max(ps.count - 1, 0)) > room
    }
}

private struct DockTab: View {
    let panel: DockPanel
    let on: Bool
    /// 名前も出す（入りきらないときはアイコンだけ）
    let titled: Bool
    /// 並べ替えで持ち上げている
    let lifted: Bool
    /// ほかの場所へ動かしている（元の場所に薄く残す）
    let ghost: Bool
    let canLeft: Bool
    let canRight: Bool
    let select: () -> Void
    let shift: (Int) -> Void
    let maximize: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: panel.icon).font(.system(size: 10))
                .foregroundStyle(panel.tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground))
            if titled {
                Text(panel.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
        }
        .padding(.horizontal, titled ? 8 : 0)
        .frame(minWidth: titled ? nil : 28)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(lifted ? Color.accentColor.opacity(0.45) : on ? Color.white.opacity(0.14) : Color.clear))
        // 持ち上げているときは、下のタブが透けないように
        .background(RoundedRectangle(cornerRadius: 5).fill(lifted ? Color(white: 0.17) : Color.clear))
        .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: 4, y: 1)
        .foregroundStyle(on || lifted ? Color.primary : Color.secondary)
        .opacity(ghost ? 0.35 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .simultaneousGesture(TapGesture(count: 2).onEnded(maximize))
        .contextMenu {
            Button(L("左へ")) { shift(-1) }.disabled(!canLeft)
            Button(L("右へ")) { shift(1) }.disabled(!canRight)
            if let w = panel.window {
                Button(L("別ウィンドウに出す")) { LayoutManager.shared.detach(w) }
            }
            Divider()
            Button(L("「\(panel.title)」を閉じる")) { LayoutManager.shared.close(panel) }
                .disabled(!LayoutManager.shared.canClose(panel))
        }
        .help(L("「\(panel.title)」　ドラッグ：並べ替え・ほかの場所へ動かす / ダブルクリック：広げる"))
    }
}

/// マウスにつける札（アイコンと名前。ウィンドウの外では「別ウィンドウに出す」）
private struct DockChipLabel: View {
    let panel: DockPanel
    var detach = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: detach ? "macwindow.on.rectangle" : panel.icon).font(.system(size: 10))
            Text(detach ? L("別ウィンドウに出す") : panel.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .foregroundStyle(Color.white)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.22)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
        .fixedSize()
    }
}

/// マウスの札（毎コマ描き直すのはここだけ）
private struct DockCursorChip: View {
    @ObservedObject var pointer: DockPointer
    let panel: DockPanel
    let valid: Bool
    /// 今離すとどうなるか（「左に置く」など）。札の下に出すので、光らせた所の真ん中の言葉と重ならない
    var action: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            DockChipLabel(panel: panel)
                .opacity(valid ? 1 : 0.5)
            if let action {
                Text(action)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                    .fixedSize()
            }
        }
        .offset(x: pointer.location.x + 12, y: pointer.location.y + 12)
    }
}

/// ドラッグ中の絵：置き場所を 1 つだけ光らせて、マウスに札をつける（いちばん上の 1 枚）
private struct DockDragOverlay: View {
    let geometry: DockGeometry
    @EnvironmentObject private var drag: DockDragState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let p = drag.panel, !drag.reordering {
                highlight(p)
                    .animation(.easeOut(duration: 0.12), value: drag.target)
                DockCursorChip(pointer: drag.pointer, panel: p, valid: drag.target != nil,
                               action: drag.target.flatMap(DockDropResolver.label))
            }
        }
    }

    @ViewBuilder private func highlight(_ p: DockPanel) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let t = drag.target, let r = DockDropResolver.highlight(t, geometry: geometry) {
                let bar: Bool = { if case .tabBar = t { return true } else { return false } }()
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(bar ? 0.14 : 0.28))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(bar ? 0.6 : 1), lineWidth: bar ? 1 : 2))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                if let x = DockDropResolver.insertLineX(t, panel: p, geometry: geometry) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor)
                        .frame(width: 3, height: r.height - 6)
                        .offset(x: x - 1.5, y: r.minY + 3)
                }
            }
        }
    }
}

/// 開発用：パネルの中身の代わり（名前とアイコンだけ）
private struct DockPanelPlaceholder: View {
    let panel: DockPanel

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: panel.icon).font(.system(size: 22))
            Text(panel.title).font(.system(size: 12))
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.03)))
    }
}

/// パネルの中身（区画の大きさに合わせる）
struct DockPanelContent: View {
    let panel: DockPanel
    let size: CGSize

    var body: some View {
        switch panel {
        case .grid: ClipGrid(size: size)
        case .monitor: OutputMonitor()
        case .pads: FXPadBar()
        case .preview: ParameterPanel(framed: false, part: .preview)
        case .params: ParameterPanel(framed: false, part: .settings)
        case .live: LivePanel()
        case .scenes: ScenesPanel()
        case .cues: CuePanel()
        case .effects: EffectBrowser()
        case .generators: EffectBrowser(generators: true)
        case .sources: SourcePanel()
        }
    }
}
