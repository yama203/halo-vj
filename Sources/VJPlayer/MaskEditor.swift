import SwiftUI
import simd

/// 自由な形のマスクの点を、プレビューの上で編集する。
/// 点は「エフェクトがかかる絵」の座標（左上 0,0 〜 右下 1,1）。クリップのときはクリップの位置・大きさ・角度で画面に写す
struct PolyMaskOverlay<H: ObservableObject & EffectHolder>: View {
    @ObservedObject var holder: H
    /// エフェクトがかかる絵 → プレビューへの写し方（クリップのトランスフォーム。レイヤー・コンポジションはそのまま）
    var transform = ClipTransform()
    @ObservedObject private var ui = EffectUIState.shared
    /// 形ごと動かしている間：始めたときの点
    @State private var moveStart: [MaskPoint]?

    var body: some View {
        GeometryReader { geo in
            if let id = ui.editingPoly, let i = holder.effects.firstIndex(where: { $0.id == id }) {
                editor(index: i, size: geo.size)
            }
        }
    }

    private func matrix(_ size: CGSize) -> simd_float3x3 {
        transform.matrix(width: Float(size.width), height: Float(size.height))
    }

    /// 絵の座標 → プレビューの座標
    private func toView(_ p: MaskPoint, _ size: CGSize) -> CGPoint {
        let v = matrix(size) * SIMD3(Float(p.x * size.width), Float(p.y * size.height), 1)
        return CGPoint(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
    }

    /// プレビューの座標 → 絵の座標
    private func fromView(_ q: CGPoint, _ size: CGSize) -> MaskPoint {
        let v = matrix(size).inverse * SIMD3(Float(q.x), Float(q.y), 1)
        return MaskPoint(x: Double(v.x / v.z) / size.width, y: Double(v.y / v.z) / size.height)
    }

    @ViewBuilder
    private func editor(index i: Int, size: CGSize) -> some View {
        let pts = holder.effects[i].points
        let vp = pts.map { toView($0, size) }
        ZStack(alignment: .topLeading) {
            // 背景：クリックで点を足す、形の中をドラッグで形ごと動かす
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let d = hypot(v.translation.width, v.translation.height)
                        if moveStart == nil, d > 3, Self.contains(vp, v.startLocation) { moveStart = pts }
                        if let start = moveStart {
                            let a = fromView(v.startLocation, size), b = fromView(v.location, size)
                            update(i) { $0 = start.map { MaskPoint(x: $0.x + b.x - a.x, y: $0.y + b.y - a.y) } }
                        }
                    }
                    .onEnded { v in
                        defer { moveStart = nil }
                        guard moveStart == nil, hypot(v.translation.width, v.translation.height) <= 3,
                              pts.count < Effect.maxPoints else { return }
                        // いちばん近い辺のあいだに入れる
                        let at = Self.nearestEdge(vp, v.location) + 1
                        update(i) { $0.insert(fromView(v.location, size), at: at) }
                    })
            Path { p in
                guard let f = vp.first else { return }
                p.move(to: f)
                vp.dropFirst().forEach { p.addLine(to: $0) }
                p.closeSubpath()
            }
            .fill(Color.cyan.opacity(0.12))
            .overlay(Path { p in
                guard let f = vp.first else { return }
                p.move(to: f)
                vp.dropFirst().forEach { p.addLine(to: $0) }
                p.closeSubpath()
            }.stroke(Color.cyan, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
            .allowsHitTesting(false)
            ForEach(vp.indices, id: \.self) { k in
                Circle()
                    .fill(k == 0 ? Color.yellow : Color.cyan)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1))
                    .frame(width: 13, height: 13)
                    .contentShape(Circle().inset(by: -5))
                    .position(vp[k])
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("polymask"))
                        .onChanged { v in update(i) { if $0.indices.contains(k) { $0[k] = fromView(v.location, size) } } })
                    .contextMenu {
                        Button("この点を消す") { update(i) { if $0.count > 3 { $0.remove(at: k) } } }
                            .disabled(pts.count <= 3)
                    }
                    .help("ドラッグで移動・右クリックで消す")
            }
            HStack(spacing: 6) {
                Text("クリックで点を追加・点をドラッグ・中をドラッグで全体を移動・点を右クリックで削除")
                    .font(.system(size: 10, weight: .semibold))
                Button("完了") { ui.editingPoly = nil }
                    .controlSize(.small)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .coordinateSpace(name: "polymask")
    }

    private func update(_ i: Int, _ f: (inout [MaskPoint]) -> Void) {
        guard holder.effects.indices.contains(i) else { return }
        var e = holder.effects[i]
        f(&e.points)
        holder.effects[i] = e
    }

    /// 点 q が多角形の中か
    static func contains(_ poly: [CGPoint], _ q: CGPoint) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > q.y) != (b.y > q.y), q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// q にいちばん近い辺（点 k と k+1 を結ぶ辺の k）
    static func nearestEdge(_ poly: [CGPoint], _ q: CGPoint) -> Int {
        var best = 0, bestD = CGFloat.infinity
        for k in poly.indices {
            let a = poly[k], b = poly[(k + 1) % poly.count]
            let ex = b.x - a.x, ey = b.y - a.y
            let t = max(0, min(1, ((q.x - a.x) * ex + (q.y - a.y) * ey) / max(ex * ex + ey * ey, 1e-6)))
            let d = hypot(q.x - (a.x + ex * t), q.y - (a.y + ey * t))
            if d < bestD { bestD = d; best = k }
        }
        return best
    }
}

/// 自由な形のマスクのカードの下：編集の切り替え・点の数・リセット
struct PolyMaskControls: View {
    @Binding var effect: Effect
    @ObservedObject private var ui = EffectUIState.shared

    var body: some View {
        let editing = ui.editingPoly == effect.id
        HStack(spacing: 10) {
            Button {
                ui.editingPoly = editing ? nil : effect.id
            } label: {
                Label(editing ? "編集中（プレビューの上で）" : "形を編集", systemImage: "skew")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .tint(editing ? .cyan : Color(white: 0.35))
            .controlSize(.large)
            .help("左のプレビューの上に点が出ます。クリックで点を追加、ドラッグで移動、右クリックで削除")
            Text("点 \(effect.points.count) 個").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("四角に戻す") { var e = effect; e.points = MaskPoint.defaultShape; effect = e }
                .controlSize(.regular)
        }
    }
}
