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

/// いまドラッグしているパネル（ドラッグ中だけ、各区画の上に置き場所を出す）
final class DockDragState: ObservableObject {
    static let shared = DockDragState()
    @Published var panel: DockPanel?
    private var timer: Timer?

    func begin(_ p: DockPanel) {
        panel = p
        timer?.invalidate()
        // ドラッグが外で終わっても置き場所が残らないよう、マウスを離したら消す
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.end() }
            self?.timer?.invalidate()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func end() {
        timer?.invalidate()
        timer = nil
        panel = nil
    }
}

// MARK: - 画面

/// 自由レイアウトのメインの画面（上のバーと下の状態表示の間）
struct DockRootView: View {
    @ObservedObject private var layout = LayoutManager.shared
    @ObservedObject private var drag = DockDragState.shared

    var body: some View {
        let hidden = Set(DockPanel.allCases.filter { ($0.window.map(layout.isDetached) ?? false) || layout.isClosed($0) })
        Group {
            if let tree = layout.state.dock?.pruned(hidden) {
                DockNodeView(node: tree)
                    // ドラッグ中は、画面の四辺にも置き場所（辺いっぱいに置く）
                    .overlay { if let p = drag.panel { DockEdgeOverlay(panel: p) } }
            } else {
                Text(L("パネルはすべて別ウィンドウに出しています"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
    }
}

private struct DockNodeView: View {
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
    @ObservedObject private var drag = DockDragState.shared
    static let handle: CGFloat = 8

    var body: some View {
        GeometryReader { g in
            let total = axis == .horizontal ? g.size.width : g.size.height
            let a = max((total - Self.handle) * CGFloat(ratio), 0)
            let b = max(total - Self.handle - a, 0)
            let h = SplitHandle(axis: axis == .horizontal ? .vertical : .horizontal, onDrag: { d in
                let s = start ?? ratio
                start = s
                let r = s + Double(d / max(total - Self.handle, 1))
                LayoutManager.shared.state.dock = LayoutManager.shared.state.dock?.settingRatio(id, r)
            }, onEnd: { start = nil })
            Group {
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        DockNodeView(node: first).frame(width: a)
                        h.frame(width: Self.handle)
                        DockNodeView(node: second).frame(width: b)
                    }
                } else {
                    VStack(spacing: 0) {
                        DockNodeView(node: first).frame(height: a)
                        h.frame(height: Self.handle)
                        DockNodeView(node: second).frame(height: b)
                    }
                }
            }
            // ドラッグ中は、境目にも置き場所（ここに 1 列・1 段を差し込む）
            .overlay(alignment: .topLeading) {
                if drag.panel != nil {
                    let t = DockBorderStrip.thickness
                    DockBorderStrip(splitID: id, vertical: axis == .horizontal)
                        .frame(width: axis == .horizontal ? t : g.size.width, height: axis == .horizontal ? g.size.height : t)
                        .offset(x: axis == .horizontal ? a + Self.handle / 2 - t / 2 : 0,
                                y: axis == .horizontal ? 0 : a + Self.handle / 2 - t / 2)
                }
            }
        }
    }
}

/// 1 つの区画：上にタブ、下に選んだパネル。ドラッグ中は置き場所を出す
private struct DockTabsView: View {
    let id: UUID
    let panels: [DockPanel]
    let selected: Int
    @ObservedObject private var drag = DockDragState.shared

    var body: some View {
        let sel = min(max(selected, 0), panels.count - 1)
        let shown = panels[sel]
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Array(panels.enumerated()), id: \.element) { i, p in
                    DockTab(panel: p, on: i == sel) {
                        // 見えている並び（閉じた・別ウィンドウのものを除く）と、元の並びの番号は違うので、パネルで選ぶ
                        LayoutManager.shared.state.dock = LayoutManager.shared.state.dock?.selecting(id, panel: p)
                    }
                }
                Spacer(minLength: 0)
                if let w = shown.window { DetachButton(panel: w) }
                PanelCloseButton(panel: shown)
            }
            .padding(.horizontal, 4)
            .frame(height: 26)
            GeometryReader { g in
                DockPanelContent(panel: shown, size: g.size)
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                    // 区画からはみ出した分は隣に描かない
                    .clipped()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.panelBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            if let p = drag.panel {
                DockDropOverlay(tabsID: id, panel: p)
            }
        }
    }
}

private struct DockTab: View {
    let panel: DockPanel
    let on: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: panel.icon).font(.system(size: 10))
            Text(panel.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.white.opacity(0.14) : Color.clear))
        .foregroundStyle(on ? Color.primary : Color.secondary)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            Button(L("「\(panel.title)」を閉じる")) { LayoutManager.shared.close(panel) }
                .disabled(!LayoutManager.shared.canClose(panel))
        }
        .onDrag {
            DockDragState.shared.begin(panel)
            return NSItemProvider(object: ("halovj-dock:" + panel.rawValue) as NSString)
        }
        .help(L("「\(panel.title)」：タブをドラッグして、ほかの区画の真ん中（タブにする）か端（分けて置く）へ"))
    }
}

/// ドラッグ中に区画の上に出す置き場所（真ん中 = タブ、端 = 分けて置く）
private struct DockDropOverlay: View {
    let tabsID: UUID
    let panel: DockPanel
    @State private var zone: DockZone?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(zone == nil ? 0.001 : 0.15)
                if let zone {
                    let r = Self.rect(zone, g.size)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.35))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .overlay(alignment: .topLeading) {
                            Text(zone == .center ? L("タブにする") : L("ここに分けて置く"))
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor, in: Capsule())
                                .offset(x: r.midX - 40, y: r.midY - 10)
                        }
                }
            }
            .onDrop(of: [.plainText], delegate: Delegate(size: g.size, tabsID: tabsID, panel: panel, zone: $zone))
        }
    }

    static func zone(at p: CGPoint, _ s: CGSize) -> DockZone {
        let x = p.x / max(s.width, 1), y = p.y / max(s.height, 1)
        // 真ん中の四角（縦横 40%〜60% 程度）ならタブ、そうでなければ近い端
        if x > 0.3 && x < 0.7 && y > 0.3 && y < 0.7 { return .center }
        let d = [(DockZone.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        return d.min { $0.1 < $1.1 }!.0
    }

    static func rect(_ z: DockZone, _ s: CGSize) -> CGRect {
        switch z {
        case .center: CGRect(x: s.width * 0.1, y: s.height * 0.1, width: s.width * 0.8, height: s.height * 0.8)
        case .left: CGRect(x: 0, y: 0, width: s.width * 0.4, height: s.height)
        case .right: CGRect(x: s.width * 0.6, y: 0, width: s.width * 0.4, height: s.height)
        case .top: CGRect(x: 0, y: 0, width: s.width, height: s.height * 0.4)
        case .bottom: CGRect(x: 0, y: s.height * 0.6, width: s.width, height: s.height * 0.4)
        }
    }

    struct Delegate: DropDelegate {
        let size: CGSize
        let tabsID: UUID
        let panel: DockPanel
        @Binding var zone: DockZone?

        func validateDrop(info: DropInfo) -> Bool { DockDragState.shared.panel != nil }
        func dropUpdated(info: DropInfo) -> DropProposal? {
            zone = DockDropOverlay.zone(at: info.location, size)
            return DropProposal(operation: .move)
        }
        func dropExited(info: DropInfo) { zone = nil }
        func performDrop(info: DropInfo) -> Bool {
            let z = DockDropOverlay.zone(at: info.location, size)
            zone = nil
            if let p = DockDragState.shared.panel {
                LayoutManager.shared.state.dock = LayoutManager.shared.state.dock?.moving(p, to: tabsID, zone: z)
            }
            DockDragState.shared.end()
            return true
        }
    }
}

/// ドラッグ中に、区画の境目に出す置き場所。ここに落とすと、その境目に 1 列（1 段）差し込む
private struct DockBorderStrip: View {
    let splitID: UUID
    /// 縦の境目（左右に並んだ区画の間）か
    let vertical: Bool
    static let thickness: CGFloat = 22
    @State private var targeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.orange.opacity(targeted ? 0.6 : 0.2))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.orange.opacity(targeted ? 1 : 0.55),
                                                              style: StrokeStyle(lineWidth: 1.5, dash: targeted ? [] : [5, 3])))
            .overlay {
                Text(L("ここに差し込む"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .rotationEffect(vertical ? .degrees(-90) : .zero)
                    .opacity(targeted ? 1 : 0.7)
            }
            .onDrop(of: [.plainText], delegate: Delegate(splitID: splitID, targeted: $targeted))
    }

    struct Delegate: DropDelegate {
        let splitID: UUID
        @Binding var targeted: Bool
        func validateDrop(info: DropInfo) -> Bool { DockDragState.shared.panel != nil }
        func dropEntered(info: DropInfo) { targeted = true }
        func dropExited(info: DropInfo) { targeted = false }
        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
        func performDrop(info: DropInfo) -> Bool {
            targeted = false
            if let p = DockDragState.shared.panel {
                LayoutManager.shared.state.dock = LayoutManager.shared.state.dock?.movingToBorder(p, splitID)
            }
            DockDragState.shared.end()
            return true
        }
    }
}

/// ドラッグ中に、画面全体の四辺に出す細い置き場所。ここに落とすと、その辺いっぱいに置く
private struct DockEdgeOverlay: View {
    let panel: DockPanel
    static let thickness: CGFloat = 26

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                strip(.top)
                Spacer(minLength: 0)
                strip(.bottom)
            }
            HStack(spacing: 0) {
                strip(.left)
                Spacer(minLength: 0)
                strip(.right)
            }
            .padding(.vertical, Self.thickness)
        }
    }

    private func strip(_ z: DockZone) -> some View {
        EdgeStrip(zone: z, panel: panel)
            .frame(width: z == .left || z == .right ? Self.thickness : nil,
                   height: z == .top || z == .bottom ? Self.thickness : nil)
    }

    private struct EdgeStrip: View {
        let zone: DockZone
        let panel: DockPanel
        @State private var targeted = false

        var label: String {
            switch zone {
            case .left: L("左端いっぱい")
            case .right: L("右端いっぱい")
            case .top: L("上いっぱい")
            case .bottom: L("下いっぱい")
            case .center: ""
            }
        }

        var body: some View {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(targeted ? 0.55 : 0.18))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor.opacity(targeted ? 1 : 0.5),
                                                                  style: StrokeStyle(lineWidth: 1.5, dash: targeted ? [] : [5, 3])))
                .overlay {
                    Text(label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .rotationEffect(zone == .left || zone == .right ? .degrees(-90) : .zero)
                }
                .onDrop(of: [.plainText], delegate: Delegate(zone: zone, targeted: $targeted))
        }

        struct Delegate: DropDelegate {
            let zone: DockZone
            @Binding var targeted: Bool
            func validateDrop(info: DropInfo) -> Bool { DockDragState.shared.panel != nil }
            func dropEntered(info: DropInfo) { targeted = true }
            func dropExited(info: DropInfo) { targeted = false }
            func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
            func performDrop(info: DropInfo) -> Bool {
                targeted = false
                if let p = DockDragState.shared.panel {
                    LayoutManager.shared.state.dock = LayoutManager.shared.state.dock?.movingToEdge(p, zone)
                }
                DockDragState.shared.end()
                return true
            }
        }
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
