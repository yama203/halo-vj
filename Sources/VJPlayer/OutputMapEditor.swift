import AppKit
import SwiftUI
import UniformTypeIdentifiers
import simd

// 出力のマッピングの窓（合わせる画面）。
//   左：スライスとマスクの一覧　中：大きな 1 枚の舞台（取る所・映す所）　右：選んだものの設定
// 点の計算（当たり判定・吸い付き・矢印で動かす・点を足す／消す）は MapEdit に分けてある（テストできるように）。
// 変更はそのまま engine.outputMap に入れる（出力にすぐ出る）。元に戻すは、変更が 0.6 秒落ち着いたら 1 歩になる
// 今の仕組みのまま（ドラッグの間の細かな変化は 1 歩にまとまる）。

typealias MapP = SIMD2<Double>

/// 映す所の編集モード（選んだスライスに対して）
enum MapEditMode: Hashable, CaseIterable {
    case corners, mesh, crop
    var label: String {
        switch self {
        case .corners: L("四隅")
        case .mesh: L("メッシュ")
        case .crop: L("切り抜き")
        }
    }
    var guideMode: MapGuide.Mode {
        switch self {
        case .corners: .corners
        case .mesh: .mesh
        case .crop: .crop
        }
    }
}

/// 一覧で選んでいるもの
enum MapItem: Hashable {
    case slice(UUID)
    case mask(UUID)
    var guideTarget: MapGuide.Target {
        switch self {
        case .slice(let id): .slice(id)
        case .mask(let id): .mask(id)
        }
    }
    var isMask: Bool { if case .mask = self { return true }; return false }
}

/// 新しく作るスライスの形
enum NewSliceShape {
    case rect, triangle, polygon
}

// MARK: - 計算（画面に関係しない）

enum MapEdit {
    static func pt(_ a: [Double]) -> MapP { MapP(a.count > 0 ? a[0] : 0, a.count > 1 ? a[1] : 0) }
    static func arr(_ p: MapP) -> [Double] { [p.x, p.y] }

    static func sliceIndex(_ map: OutputMap, _ id: UUID) -> Int? { map.slices.firstIndex { $0.id == id } }
    static func maskIndex(_ map: OutputMap, _ id: UUID) -> Int? { map.masks.firstIndex { $0.id == id } }

    /// 多角形の点を編集するモードか（辺のクリックで点を足す・Delete で消す）
    static func isPolygon(_ item: MapItem, _ mode: MapEditMode) -> Bool {
        item.isMask || mode == .crop
    }

    /// 編集する点（それぞれの座標で。四隅・マスク＝出力の画面、メッシュ＝四隅をかける前、切り抜き＝スライスの中）
    static func points(_ map: OutputMap, _ item: MapItem, _ mode: MapEditMode) -> [MapP] {
        switch item {
        case .mask(let id):
            return maskIndex(map, id).map { map.masks[$0].points.map(pt) } ?? []
        case .slice(let id):
            guard let i = sliceIndex(map, id) else { return [] }
            let s = map.slices[i]
            switch mode {
            case .corners: return s.corners.map(pt)
            case .mesh: return s.mesh.flatMap { $0.isValid ? $0.points.map(pt) : nil } ?? []
            case .crop: return s.crop.map(pt)
            }
        }
    }

    static func setPoints(_ map: inout OutputMap, _ item: MapItem, _ mode: MapEditMode, _ pts: [MapP]) {
        switch item {
        case .mask(let id):
            guard let i = maskIndex(map, id) else { return }
            map.masks[i].points = pts.map(arr)
        case .slice(let id):
            guard let i = sliceIndex(map, id) else { return }
            switch mode {
            case .corners:
                guard pts.count == 4 else { return }
                map.slices[i].corners = pts.map(arr)
            case .mesh:
                guard var m = map.slices[i].mesh, m.points.count == pts.count else { return }
                m.points = pts.map(arr)
                map.slices[i].mesh = m
            case .crop:
                map.slices[i].crop = pts.map(arr)
            }
        }
    }

    /// 点（それぞれの座標）→ 出力の画面。後ろに回った所は nil
    static func toOutput(_ map: OutputMap, _ item: MapItem, _ mode: MapEditMode, _ p: MapP) -> MapP? {
        guard case .slice(let id) = item else { return p }
        guard let i = sliceIndex(map, id) else { return nil }
        let s = map.slices[i]
        switch mode {
        case .corners: return p
        case .mesh:
            let h = s.homography * SIMD3(Float(p.x), Float(p.y), 1)
            guard h.z > 1e-6 else { return nil }
            return MapP(Double(h.x / h.z), Double(h.y / h.z))
        case .crop: return s.outputPoint(u: p.x, v: p.y)
        }
    }

    /// 出力の画面の q → 点の座標（guess：今の点。切り抜きはメッシュがあるので、そこから近づけて解く）
    static func fromOutput(_ map: OutputMap, _ item: MapItem, _ mode: MapEditMode, _ q: MapP, guess: MapP) -> MapP {
        guard case .slice(let id) = item, let i = sliceIndex(map, id) else { return q }
        let s = map.slices[i]
        switch mode {
        case .corners: return q
        case .mesh:
            let h = s.homography.inverse * SIMD3(Float(q.x), Float(q.y), 1)
            guard abs(h.z) > 1e-9 else { return guess }
            return MapP(Double(h.x / h.z), Double(h.y / h.z))
        case .crop:
            return solve({ s.outputPoint(u: $0.x, v: $0.y) }, target: q, guess: guess)
        }
    }

    /// f(x) = target となる x を、guess から近づけて探す（ニュートン法）
    static func solve(_ f: (MapP) -> MapP?, target: MapP, guess: MapP) -> MapP {
        var x = guess
        for _ in 0..<30 {
            guard let y = f(x) else { break }
            let r = target - y
            if simd_length(r) < 1e-9 { break }
            let h = 1e-4
            guard let fx = f(x + MapP(h, 0)), let fy = f(x + MapP(0, h)) else { break }
            let a = (fx - y) / h, b = (fy - y) / h
            let det = a.x * b.y - b.x * a.y
            guard abs(det) > 1e-14 else { break }
            x += MapP((b.y * r.x - b.x * r.y) / det, (-a.y * r.x + a.x * r.y) / det)
        }
        return x
    }

    /// 点を出力の画面の上で出す（舞台・当たり判定用）
    static func outputPoints(_ map: OutputMap, _ item: MapItem, _ mode: MapEditMode) -> [MapP?] {
        points(map, item, mode).map { toOutput(map, item, mode, $0) }
    }

    /// 選んだ点を、出力の画面の上で d だけ動かす（start：動かし始めたときの点）
    static func movePoints(_ map: inout OutputMap, _ item: MapItem, _ mode: MapEditMode,
                           from start: [MapP], indices: Set<Int>, by d: MapP) {
        var pts = start
        for k in indices where pts.indices.contains(k) {
            guard let o = toOutput(map, item, mode, start[k]) else { continue }
            pts[k] = fromOutput(map, item, mode, o + d, guess: start[k])
        }
        setPoints(&map, item, mode, pts)
    }

    /// 矢印キー：選んだ点を出力の dx, dy ピクセルぶん動かす
    static func nudge(_ map: inout OutputMap, _ item: MapItem, _ mode: MapEditMode, selected: Set<Int>,
                      dx: Double, dy: Double, outputSize: (Int, Int)) {
        let d = MapP(dx / Double(max(outputSize.0, 1)), dy / Double(max(outputSize.1, 1)))
        movePoints(&map, item, mode, from: points(map, item, mode), indices: selected, by: d)
    }

    /// スライス（四隅）・マスク（全部の点）ごと動かす。メッシュ・切り抜きはスライスの中の座標なので一緒に動く
    static func moveItem(_ map: inout OutputMap, _ item: MapItem, from start: OutputMap, by d: MapP) {
        switch item {
        case .slice(let id):
            guard let i = sliceIndex(map, id), let j = sliceIndex(start, id) else { return }
            map.slices[i].corners = start.slices[j].corners.map { arr(pt($0) + d) }
        case .mask(let id):
            guard let i = maskIndex(map, id), let j = maskIndex(start, id) else { return }
            map.masks[i].points = start.masks[j].points.map { arr(pt($0) + d) }
        }
    }

    /// 動かすときの目印の点（出力の画面。スライスは面の四隅、マスクは全部の点）
    static func referencePoints(_ map: OutputMap, _ item: MapItem) -> [MapP] {
        switch item {
        case .slice(let id):
            guard let i = sliceIndex(map, id) else { return [] }
            let s = map.slices[i]
            return [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].compactMap { s.outputPoint(u: $0.0, v: $0.1) }
        case .mask(let id):
            return maskIndex(map, id).map { map.masks[$0].points.map(pt) } ?? []
        }
    }

    // MARK: 吸い付く

    /// 吸い付く先：同じ出力の、ほかのスライスの面の四隅・マスクの点
    static func snapTargets(_ map: OutputMap, output: Int, excluding: MapItem?) -> [MapP] {
        var out: [MapP] = []
        for s in map.slices where s.output == output && excluding != .slice(s.id) {
            out += referencePoints(map, .slice(s.id))
        }
        for m in map.masks where m.output == output && excluding != .mask(m.id) {
            out += m.points.map(pt)
        }
        return out
    }

    /// p（出力の座標）を吸い付かせる。scale：出力の 1 あたりの pt（舞台の上の大きさ）。range pt 以内のいちばん近い点、
    /// 無ければ画面の端・中央の線（縦・横べつべつ）
    static func snap(_ p: MapP, targets: [MapP], scale: MapP, range: Double = 8) -> MapP {
        var best: MapP?
        var bestD = range
        for t in targets {
            let d = simd_length((t - p) * scale)
            if d <= bestD { bestD = d; best = t }
        }
        if let best { return best }
        var q = p
        for axis in 0..<2 {
            var bd = range
            for line in [0.0, 0.5, 1.0] {
                let d = abs(p[axis] - line) * scale[axis]
                if d <= bd { bd = d; q[axis] = line }
            }
        }
        return q
    }

    /// 形ごと動かすとき：目印の点のどれかが吸い付くように d を直す（いちばん小さな直しを使う）
    static func snapDelta(refs: [MapP], delta d: MapP, targets: [MapP], scale: MapP, range: Double = 8) -> MapP {
        var best: MapP?
        for r in refs {
            let p = r + d
            let c = snap(p, targets: targets, scale: scale, range: range) - p
            guard c != .zero else { continue }
            if best == nil || simd_length(c * scale) < simd_length(best! * scale) { best = c }
        }
        return d + (best ?? .zero)
    }

    // MARK: 点を足す・消す

    /// 多角形 poly（出力の座標）の、q にいちばん近い辺の後ろに入れるときの番号
    static func insertIndex(_ poly: [MapP], _ q: MapP, scale: MapP = MapP(1, 1)) -> Int {
        let cg = poly.map { CGPoint(x: $0.x * scale.x, y: $0.y * scale.y) }
        return PolyMaskOverlay<Layer>.nearestEdge(cg, CGPoint(x: q.x * scale.x, y: q.y * scale.y)) + 1
    }

    /// q から多角形の辺までのいちばん近い長さ（scale をかけた pt で）
    static func edgeDistance(_ poly: [MapP], _ q: MapP, scale: MapP) -> Double {
        guard poly.count >= 2 else { return .infinity }
        var best = Double.infinity
        for k in poly.indices {
            let a = poly[k] * scale, b = poly[(k + 1) % poly.count] * scale, p = q * scale
            let e = b - a
            let t = max(0, min(1, simd_dot(p - a, e) / max(simd_length_squared(e), 1e-12)))
            best = min(best, simd_length(p - (a + e * t)))
        }
        return best
    }

    /// 辺の上の q（出力の座標）に点を足す。足した点の番号（足せなければ nil）
    @discardableResult
    static func insertPoint(_ map: inout OutputMap, _ item: MapItem, _ mode: MapEditMode, at q: MapP,
                            scale: MapP = MapP(1, 1)) -> Int? {
        guard isPolygon(item, mode) else { return nil }
        let pts = points(map, item, mode)
        let limit = item.isMask ? OutputMask.maxPoints : OutputSlice.maxCropPoints
        guard pts.count >= 2, pts.count < limit else { return nil }
        let outs = pts.map { toOutput(map, item, mode, $0) }
        guard outs.allSatisfy({ $0 != nil }) else { return nil }
        let at = insertIndex(outs.map { $0! }, q, scale: scale)
        let a = pts[at - 1], b = pts[at % pts.count]
        let p = fromOutput(map, item, mode, q, guess: (a + b) / 2)
        var n = pts
        n.insert(p, at: at)
        setPoints(&map, item, mode, n)
        return at
    }

    /// 選んだ点を消す（keep 個は残す。足りなくなるときは、選んだ点の前のほうから消せるだけ）
    static func deletePoints(_ pts: [MapP], _ sel: Set<Int>, keep: Int = 3) -> [MapP] {
        let can = max(pts.count - keep, 0)
        let drop = Set(sel.filter { pts.indices.contains($0) }.sorted().prefix(can))
        return pts.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    /// 選んだ点を消す（多角形のときだけ）。消せたら true
    @discardableResult
    static func deleteSelected(_ map: inout OutputMap, _ item: MapItem, _ mode: MapEditMode, _ sel: Set<Int>) -> Bool {
        guard isPolygon(item, mode) else { return false }
        let pts = points(map, item, mode)
        let n = deletePoints(pts, sel)
        guard n.count != pts.count else { return false }
        setPoints(&map, item, mode, n)
        return true
    }

    // MARK: メッシュ

    /// メッシュのモードに入る：メッシュが無ければ 2×2 を作る
    static func enterMesh(_ s: inout OutputSlice) {
        if s.mesh?.isValid != true { s.mesh = .regular(cols: 2, rows: 2) }
    }

    /// マスの数を変える（今の形を保つ）
    static func setMeshSize(_ s: inout OutputSlice, cols: Int, rows: Int) {
        let m = s.mesh.flatMap { $0.isValid ? $0 : nil } ?? .regular(cols: 2, rows: 2)
        s.mesh = m.resized(cols: cols, rows: rows)
    }

    // MARK: 当たり判定

    /// q（舞台の pt）にいちばん近い点（radius 以内）
    static func hitPoint(_ pts: [CGPoint?], _ q: CGPoint, radius: CGFloat = 8) -> Int? {
        var best: Int?
        var bd = radius
        for (k, p) in pts.enumerated() {
            guard let p else { continue }
            let d = hypot(p.x - q.x, p.y - q.y)
            if d <= bd { bd = d; best = k }
        }
        return best
    }

    /// 四角の中の点
    static func pointsIn(_ r: CGRect, _ pts: [CGPoint?]) -> Set<Int> {
        Set(pts.enumerated().compactMap { k, p in p.map { r.contains($0) } == true ? k : nil })
    }

    static func contains(_ poly: [MapP], _ q: MapP) -> Bool {
        PolyMaskOverlay<Layer>.contains(poly.map { CGPoint(x: $0.x, y: $0.y) }, CGPoint(x: q.x, y: q.y))
    }

    /// スライスの面のふち（出力の座標。メッシュで曲がる）
    static func outline(_ s: OutputSlice) -> [MapP] {
        let mesh = s.mesh.flatMap { $0.isValid ? $0 : nil }
        let n = mesh.map { max($0.cols, $0.rows) * 4 } ?? 1
        var uv: [(Double, Double)] = []
        for k in 0..<n { uv.append((Double(k) / Double(n), 0)) }
        for k in 0..<n { uv.append((1, Double(k) / Double(n))) }
        for k in 0..<n { uv.append((1 - Double(k) / Double(n), 1)) }
        for k in 0..<n { uv.append((0, 1 - Double(k) / Double(n))) }
        return uv.compactMap { s.outputPoint(u: $0.0, v: $0.1) }
    }

    /// スライスの中の (u,v) の線を、出力の画面へ写した折れ線
    static func mappedLine(_ s: OutputSlice, from a: MapP, to b: MapP, steps: Int) -> [MapP] {
        (0...max(steps, 1)).compactMap { k in
            let t = Double(k) / Double(max(steps, 1))
            let p = a + (b - a) * t
            return s.outputPoint(u: p.x, v: p.y)
        }
    }

    /// 切り抜きの形（出力の座標。メッシュがあれば辺も曲がる）
    static func cropOutline(_ s: OutputSlice) -> [MapP] {
        let n = s.crop.count
        guard n >= 2 else { return [] }
        let steps = s.mesh == nil ? 1 : 12
        var out: [MapP] = []
        for k in 0..<n {
            out += mappedLine(s, from: pt(s.crop[k]), to: pt(s.crop[(k + 1) % n]), steps: steps).dropLast()
        }
        return out
    }

    // MARK: 取る所（コンポジションの UV。aspect は横 ÷ 縦）

    /// 取る所の四角の上の点（hx, hy は -1…1。反転は見ない）
    static func inputPoint(_ s: OutputSlice, hx: Double, hy: Double, aspect: Double) -> MapP {
        var t = s
        t.flipH = false; t.flipV = false
        return t.sourceUV(u: (hx + 1) / 2, v: (hy + 1) / 2, aspect: aspect)
    }

    static func inputQuad(_ s: OutputSlice, aspect: Double) -> [MapP] {
        [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)].map { inputPoint(s, hx: $0.0, hy: $0.1, aspect: aspect) }
    }

    /// 取る所を動かす（中心は 0…1 の中に）
    static func movedInput(_ start: OutputSlice, by d: MapP) -> [Double] {
        let ip = start.input
        let cx = min(max(ip[0] + ip[2] / 2 + d.x, 0), 1), cy = min(max(ip[1] + ip[3] / 2 + d.y, 0), 1)
        return [cx - ip[2] / 2, cy - ip[3] / 2, ip[2], ip[3]]
    }

    /// 取る所の大きさを変える：hx, hy（-1・0・1）の角・辺をつかんで d だけ動かす。向かいの辺は動かない
    static func resizedInput(_ start: OutputSlice, hx: Int, hy: Int, by d: MapP, aspect: Double) -> [Double] {
        let a = max(aspect, 1e-6)
        let ip = start.input
        let t = start.inputRotation * .pi / 180
        // 画面の形のままの座標（横を aspect 倍）で、四角の向きに直す
        let D = MapP(d.x * a, d.y)
        let L = MapP(cos(t) * D.x + sin(t) * D.y, -sin(t) * D.x + cos(t) * D.y)
        let w = max(ip[2] + Double(hx) * L.x / a, 0.01)
        let h = max(ip[3] + Double(hy) * L.y, 0.01)
        let sx = Double(hx) * (w - ip[2]) * a / 2, sy = Double(hy) * (h - ip[3]) / 2
        let cx = ip[0] + ip[2] / 2 + (cos(t) * sx - sin(t) * sy) / a
        let cy = ip[1] + ip[3] / 2 + (sin(t) * sx + cos(t) * sy)
        return [cx - w / 2, cy - h / 2, w, h]
    }

    /// 上の丸をつかんで回す：中心から見たマウスの向き（度。step があればその刻みで）
    static func inputRotation(center c: MapP, mouse m: MapP, aspect: Double, step: Double? = nil) -> Double {
        let v = MapP((m.x - c.x) * aspect, m.y - c.y)
        var deg = atan2(v.x, -v.y) * 180 / .pi
        if let step { deg = (deg / step).rounded() * step }
        return deg
    }

    // MARK: 作る

    static func newSlice(_ shape: NewSliceShape, output: Int, number: Int) -> OutputSlice {
        var s = OutputSlice()
        s.output = output
        s.corners = [[0.2, 0.2], [0.8, 0.2], [0.8, 0.8], [0.2, 0.8]]
        switch shape {
        case .rect:
            s.name = L("スライス \(number)")
        case .triangle:
            s.name = L("三角 \(number)")
            s.crop = [[0.5, 0], [1, 1], [0, 1]]
        case .polygon:
            s.name = L("多角形 \(number)")
            s.crop = (0..<6).map { k in
                let t = Double(k) / 6 * 2 * .pi - .pi / 2
                return [0.5 + 0.5 * cos(t), 0.5 + 0.5 * sin(t)]
            }
        }
        return s
    }

    static func newMask(output: Int, number: Int) -> OutputMask {
        var m = OutputMask()
        m.name = L("マスク \(number)")
        m.output = output
        m.points = [[0.4, 0.4], [0.6, 0.4], [0.6, 0.6], [0.4, 0.6]]
        return m
    }

    /// 複製（少しずらす）。複製したものを返す
    static func duplicate(_ map: inout OutputMap, _ item: MapItem) -> MapItem? {
        let off = MapP(0.03, 0.03)
        switch item {
        case .slice(let id):
            guard let i = sliceIndex(map, id), map.slices.count < OutputMap.maxSlices else { return nil }
            var s = map.slices[i]
            s.id = UUID()
            s.name = L("\(s.name) のコピー")
            s.corners = s.corners.map { arr(pt($0) + off) }
            map.slices.insert(s, at: i + 1)
            return .slice(s.id)
        case .mask(let id):
            guard let i = maskIndex(map, id) else { return nil }
            var m = map.masks[i]
            m.id = UUID()
            m.name = L("\(m.name) のコピー")
            m.points = m.points.map { arr(pt($0) + off) }
            map.masks.insert(m, at: i + 1)
            return .mask(m.id)
        }
    }
}

// MARK: - 舞台の大きさ（拡大・移動）

struct MapStageFrame {
    /// 出力（またはコンポジション）の画面が舞台の上で占める四角
    var content: CGRect

    static let margin: CGFloat = 28

    init(size: CGSize, aspect: Double, zoom: Double, pan: CGSize) {
        let a = CGFloat(max(aspect, 0.05))
        let aw = max(size.width - Self.margin * 2, 10), ah = max(size.height - Self.margin * 2, 10)
        var w = aw, h = aw / a
        if h > ah { h = ah; w = ah * a }
        w *= CGFloat(zoom); h *= CGFloat(zoom)
        content = CGRect(x: (size.width - w) / 2 + pan.width, y: (size.height - h) / 2 + pan.height, width: w, height: h)
    }

    var scale: MapP { MapP(Double(content.width), Double(content.height)) }
    func toView(_ p: MapP) -> CGPoint {
        CGPoint(x: content.minX + CGFloat(p.x) * content.width, y: content.minY + CGFloat(p.y) * content.height)
    }
    func fromView(_ q: CGPoint) -> MapP {
        MapP(Double((q.x - content.minX) / max(content.width, 1)), Double((q.y - content.minY) / max(content.height, 1)))
    }
}

// MARK: - 窓の状態（選んでいるもの・舞台・マウスとキー）

final class MapEditorState: ObservableObject {
    enum Tab: Hashable { case input, output }

    let engine: Engine
    /// false：画面に出さない書き出し（Metal の絵・出力先の一覧を使わない）
    let live: Bool

    @Published var tab = Tab.output { didSet { if tab != oldValue { fit(); marquee = nil } } }
    @Published var output = 0 { didSet { if output != oldValue { selectedPoints = []; fit() } } }
    @Published var item: MapItem? {
        didSet {
            guard item != oldValue else { return }
            selectedPoints = []
            // メッシュの無いスライスでメッシュのモードのままにしない
            if case .slice(let id)? = item, mode == .mesh,
               engine.outputMap.slices.first(where: { $0.id == id })?.mesh == nil { mode = .corners }
            // 選んだものが今の出力に無ければ、その出力を見る
            if let o = outputOf(item), o != output { output = o }
            syncGuide()
        }
    }
    @Published var mode = MapEditMode.corners { didSet { if mode != oldValue { selectedPoints = []; syncGuide() } } }
    @Published var selectedPoints: Set<Int> = [] { didSet { if selectedPoints != oldValue { syncGuide() } } }
    @Published var zoom = 1.0
    @Published var pan = CGSize.zero
    @Published var snapping = true
    @Published var guideOn = true { didSet { syncGuide() } }
    @Published var marquee: CGRect?
    /// 窓が開いているか（開いている間だけ出力にガイドを出す）
    var windowOpen = false { didSet { syncGuide() } }

    init(engine: Engine, live: Bool = true) {
        self.engine = engine
        self.live = live
    }

    var map: OutputMap {
        get { engine.outputMap }
        set { engine.outputMap = newValue }
    }

    func outputOf(_ item: MapItem?) -> Int? {
        switch item {
        case .slice(let id)?: map.slices.first { $0.id == id }?.output
        case .mask(let id)?: map.masks.first { $0.id == id }?.output
        case nil: nil
        }
    }

    /// 出力にガイドを出す（窓が開いていて「出力にガイド」が入っているときだけ）
    func syncGuide() {
        guard windowOpen, guideOn, let item else {
            if engine.mapGuide != nil { engine.mapGuide = nil }
            return
        }
        engine.mapGuide = MapGuide(target: item.guideTarget, mode: item.isMask ? .corners : mode.guideMode, selected: selectedPoints)
    }

    /// 編集モード（スライスのとき）。メッシュに入るとき、無ければ 2×2 を作る
    func setMode(_ m: MapEditMode) {
        if m == .mesh, case .slice(let id)? = item, let i = MapEdit.sliceIndex(map, id) {
            var s = map.slices[i]
            MapEdit.enterMesh(&s)
            if s != map.slices[i] { map.slices[i] = s }
        }
        mode = m
    }

    var aspect: Double {
        switch tab {
        case .input: return Double(engine.outputAspect)
        case .output: return live ? Double(OutputController.shared.aspect(of: output)) : 16.0 / 9
        }
    }

    /// 出力の画面のピクセル数（矢印キーで 1 ピクセルぶん動かすため）
    var outputPixels: (Int, Int) {
        if live, let s = OutputController.shared.screen(of: output) {
            let k = s.backingScaleFactor
            return (Int(s.frame.width * k), Int(s.frame.height * k))
        }
        let a = live ? Double(OutputController.shared.aspect(of: output)) : 16.0 / 9
        return (max(Int((1080 * a).rounded()), 1), 1080)
    }

    func fit() { zoom = 1; pan = .zero }

    func zoom(by f: Double, around q: CGPoint?, size: CGSize) {
        let old = MapStageFrame(size: size, aspect: aspect, zoom: zoom, pan: pan)
        let nz = min(max(zoom * f, 0.25), 4)
        guard nz != zoom else { return }
        let q = q ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let u = old.fromView(q)
        let base = MapStageFrame(size: size, aspect: aspect, zoom: nz, pan: .zero)
        // マウスの下の所が動かないように
        pan = CGSize(width: q.x - base.content.minX - CGFloat(u.x) * base.content.width,
                     height: q.y - base.content.minY - CGFloat(u.y) * base.content.height)
        zoom = nz
    }

    // MARK: マウス

    private enum Drag {
        case none
        case pan(start: CGSize, at: CGPoint)
        case marquee(at: CGPoint, base: Set<Int>)
        case points(item: MapItem, mode: MapEditMode, start: [MapP], indices: Set<Int>, grab: Int, at: MapP)
        case item(MapItem, start: OutputMap, at: MapP)
        case input(id: UUID, start: OutputSlice, hx: Int, hy: Int, rotate: Bool, at: MapP)
    }
    private var drag = Drag.none
    private var downAt = CGPoint.zero
    private var moved = false
    /// 動かさずに離したときにすること
    private var onClick: (() -> Void)?

    /// 選んだスライスの取る所の、つかむ所（舞台の pt）。8 つの角・辺と、上の丸
    func inputHandles(_ s: OutputSlice, _ f: MapStageFrame) -> (handles: [(Int, Int, CGPoint)], knob: CGPoint, top: CGPoint) {
        let a = aspect
        var hs: [(Int, Int, CGPoint)] = []
        for hy in -1...1 { for hx in -1...1 where hx != 0 || hy != 0 {
            hs.append((hx, hy, f.toView(MapEdit.inputPoint(s, hx: Double(hx), hy: Double(hy), aspect: a))))
        } }
        let c = f.toView(MapEdit.inputPoint(s, hx: 0, hy: 0, aspect: a))
        let top = f.toView(MapEdit.inputPoint(s, hx: 0, hy: -1, aspect: a))
        let dx = top.x - c.x, dy = top.y - c.y, len = max(hypot(dx, dy), 1)
        return (hs, CGPoint(x: top.x + dx / len * 24, y: top.y + dy / len * 24), top)
    }

    func mouseDown(_ q: CGPoint, flags: NSEvent.ModifierFlags, size: CGSize) {
        let f = MapStageFrame(size: size, aspect: aspect, zoom: zoom, pan: pan)
        downAt = q; moved = false; onClick = nil; drag = .none
        let shift = flags.contains(.shift)
        let p = f.fromView(q)
        let map = self.map
        if flags.contains(.option) || !f.content.insetBy(dx: -14, dy: -14).contains(q) {
            drag = .pan(start: pan, at: q)
            return
        }
        if tab == .input {
            // 選んだスライスのつかむ所
            if case .slice(let id)? = item, let i = MapEdit.sliceIndex(map, id) {
                let s = map.slices[i]
                let h = inputHandles(s, f)
                if hypot(h.knob.x - q.x, h.knob.y - q.y) <= 9 {
                    drag = .input(id: id, start: s, hx: 0, hy: 0, rotate: true, at: p); return
                }
                if let k = MapEdit.hitPoint(h.handles.map { $0.2 }, q, radius: 7) {
                    drag = .input(id: id, start: s, hx: h.handles[k].0, hy: h.handles[k].1, rotate: false, at: p); return
                }
            }
            // 四角の中（選んだもの → 手前のものから）
            let a = aspect
            var order = Array(map.slices.reversed())
            if case .slice(let id)? = item, let k = order.firstIndex(where: { $0.id == id }) { order.insert(order.remove(at: k), at: 0) }
            if let s = order.first(where: { MapEdit.contains(MapEdit.inputQuad($0, aspect: a), p) }) {
                item = .slice(s.id)
                drag = .input(id: s.id, start: s, hx: 0, hy: 0, rotate: false, at: p)
                return
            }
            drag = .pan(start: pan, at: q)
            return
        }

        // 映す所
        if let it = item, outputOf(it) == output {
            let m = mode
            let vp = MapEdit.outputPoints(map, it, m).map { $0.map(f.toView) }
            if let k = MapEdit.hitPoint(vp, q) {
                var sel = selectedPoints
                if shift {
                    if sel.contains(k) { sel.remove(k) } else { sel.insert(k) }
                } else if !sel.contains(k) {
                    sel = [k]
                }
                selectedPoints = sel
                if sel.contains(k) {
                    drag = .points(item: it, mode: m, start: MapEdit.points(map, it, m), indices: sel, grab: k, at: p)
                }
                return
            }
            // 多角形の辺の上：クリックで点を足す
            if MapEdit.isPolygon(it, m) {
                let poly = MapEdit.outputPoints(map, it, m).compactMap { $0 }
                if MapEdit.edgeDistance(poly, p, scale: f.scale) <= 6 {
                    let scale = f.scale
                    onClick = { [weak self] in
                        guard let self else { return }
                        var mm = self.map
                        if let k = MapEdit.insertPoint(&mm, it, m, at: p, scale: scale) {
                            self.map = mm
                            self.selectedPoints = [k]
                        }
                    }
                    drag = .item(it, start: map, at: p)
                    return
                }
            }
        }
        // 面・マスクの中（選んだもの → 手前のものから）
        var order: [MapItem] = map.masks.reversed().filter { $0.output == output }.map { .mask($0.id) }
            + map.slices.reversed().filter { $0.output == output }.map { .slice($0.id) }
        if let it = item, let k = order.firstIndex(of: it) { order.insert(order.remove(at: k), at: 0) }
        if let hit = order.first(where: { inside($0, p, map) }) {
            if hit != item { item = hit } else { onClick = { [weak self] in self?.selectedPoints = [] } }
            drag = .item(hit, start: map, at: p)
            return
        }
        // 何もない所：囲んで選ぶ
        drag = .marquee(at: q, base: shift ? selectedPoints : [])
        if !shift { onClick = { [weak self] in self?.selectedPoints = [] } }
    }

    private func inside(_ it: MapItem, _ p: MapP, _ map: OutputMap) -> Bool {
        switch it {
        case .slice(let id):
            guard let i = MapEdit.sliceIndex(map, id) else { return false }
            return MapEdit.contains(MapEdit.outline(map.slices[i]), p)
        case .mask(let id):
            guard let i = MapEdit.maskIndex(map, id) else { return false }
            return MapEdit.contains(map.masks[i].points.map(MapEdit.pt), p)
        }
    }

    func mouseDragged(_ q: CGPoint, flags: NSEvent.ModifierFlags, size: CGSize) {
        if !moved && hypot(q.x - downAt.x, q.y - downAt.y) < 3 { return }
        moved = true
        let f = MapStageFrame(size: size, aspect: aspect, zoom: zoom, pan: pan)
        let p = f.fromView(q)
        switch drag {
        case .none:
            break
        case .pan(let start, let at):
            pan = CGSize(width: start.width + q.x - at.x, height: start.height + q.y - at.y)
        case .marquee(let at, let base):
            let r = CGRect(x: min(at.x, q.x), y: min(at.y, q.y), width: abs(q.x - at.x), height: abs(q.y - at.y))
            marquee = r
            guard let it = item, outputOf(it) == output else { return }
            let vp = MapEdit.outputPoints(map, it, mode).map { $0.map(f.toView) }
            selectedPoints = base.union(MapEdit.pointsIn(r, vp))
        case .points(let it, let m, let start, let indices, let grab, let at):
            var d = p - at
            var mm = map
            if snapping && !flags.contains(.command), start.indices.contains(grab),
               let g = MapEdit.toOutput(mm, it, m, start[grab]) {
                let targets = MapEdit.snapTargets(mm, output: output, excluding: it)
                d = MapEdit.snap(g + d, targets: targets, scale: f.scale) - g
            }
            MapEdit.movePoints(&mm, it, m, from: start, indices: indices, by: d)
            map = mm
        case .item(let it, let start, let at):
            var d = p - at
            if snapping && !flags.contains(.command) {
                let targets = MapEdit.snapTargets(start, output: output, excluding: it)
                d = MapEdit.snapDelta(refs: MapEdit.referencePoints(start, it), delta: d, targets: targets, scale: f.scale)
            }
            var mm = map
            MapEdit.moveItem(&mm, it, from: start, by: d)
            map = mm
        case .input(let id, let start, let hx, let hy, let rotate, let at):
            guard let i = MapEdit.sliceIndex(map, id) else { return }
            var s = map.slices[i]
            if rotate {
                let c = MapEdit.inputPoint(start, hx: 0, hy: 0, aspect: aspect)
                s.inputRotation = MapEdit.inputRotation(center: c, mouse: p, aspect: aspect, step: flags.contains(.shift) ? 15 : nil)
            } else if hx == 0 && hy == 0 {
                s.input = MapEdit.movedInput(start, by: p - at)
            } else {
                s.input = MapEdit.resizedInput(start, hx: hx, hy: hy, by: p - at, aspect: aspect)
            }
            map.slices[i] = s
        }
    }

    func mouseUp(_ q: CGPoint) {
        if !moved { onClick?() }
        onClick = nil
        drag = .none
        marquee = nil
    }

    // MARK: キー（舞台にフォーカスがあるとき）

    /// 矢印：選んだ点を出力の 1 ピクセル（⇧ で 10）。Delete：多角形の選んだ点を消す。使ったら true
    func key(_ e: NSEvent) -> Bool {
        let step: Double = e.modifierFlags.contains(.shift) ? 10 : 1
        var dx = 0.0, dy = 0.0
        switch e.keyCode {
        case 123: dx = -step
        case 124: dx = step
        case 125: dy = step
        case 126: dy = -step
        case 51, 117:
            guard tab == .output, let it = item else { return true }
            var mm = map
            if MapEdit.deleteSelected(&mm, it, mode, selectedPoints) {
                map = mm
                selectedPoints = []
            } else {
                NSSound.beep()
            }
            return true
        default:
            return false
        }
        guard tab == .output, let it = item, !selectedPoints.isEmpty else { return true }
        var mm = map
        MapEdit.nudge(&mm, it, mode, selected: selectedPoints, dx: dx, dy: dy, outputSize: outputPixels)
        map = mm
        return true
    }
}

extension OutputController {
    /// 出力 i が出しているディスプレイ（ディスプレイでなければ nil）
    func screen(of i: Int) -> NSScreen? {
        let t = binding(i).wrappedValue
        guard case .screen(let id) = t else { return nil }
        return screens.first { Self.displayID(of: $0) == id }
    }
}

// MARK: - 舞台のマウス・キーを受ける所

final class MapStageNSView: NSView {
    var state: MapEditorState?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func loc(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        state?.mouseDown(loc(e), flags: e.modifierFlags, size: bounds.size)
    }
    override func mouseDragged(with e: NSEvent) { state?.mouseDragged(loc(e), flags: e.modifierFlags, size: bounds.size) }
    override func mouseUp(with e: NSEvent) { state?.mouseUp(loc(e)) }
    override func scrollWheel(with e: NSEvent) {
        let dy = e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.01 : 0.1)
        guard dy != 0 else { return }
        state?.zoom(by: exp(dy), around: loc(e), size: bounds.size)
    }
    override func magnify(with e: NSEvent) {
        state?.zoom(by: 1 + e.magnification, around: loc(e), size: bounds.size)
    }
    override func keyDown(with e: NSEvent) {
        if state?.key(e) != true { super.keyDown(with: e) }
    }
}

private struct MapStageInput: NSViewRepresentable {
    let state: MapEditorState
    func makeNSView(context: Context) -> MapStageNSView {
        let v = MapStageNSView()
        v.state = state
        return v
    }
    func updateNSView(_ v: MapStageNSView, context: Context) { v.state = state }
}

// MARK: - 窓

final class OutputMapWindow: NSObject, NSWindowDelegate {
    static let shared = OutputMapWindow()
    private var window: NSWindow?
    private lazy var state = MapEditorState(engine: Engine.shared)

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = L("出力のマッピング")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentMinSize = NSSize(width: 1000, height: 620)
        w.contentView = NSHostingView(rootView: OutputMapEditor(state: state).environmentObject(Engine.shared)
            .preferredColorScheme(.dark))
        w.center()
        window = w
        if state.item == nil { state.item = Engine.shared.outputMap.slices.first.map { .slice($0.id) } }
        state.windowOpen = true
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        // 出力に出していたガイドを消す
        state.windowOpen = false
        Engine.shared.mapGuide = nil
    }
}

// MARK: - 画面

private func sliceHue(_ i: Int) -> Color {
    Color(hue: (Double(i) * 0.13 + 0.05).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 1)
}

struct OutputMapEditor: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var state: MapEditorState

    var body: some View {
        VStack(spacing: 0) {
            MapTopBar(state: state)
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            HStack(spacing: 0) {
                MapItemList(state: state)
                    .frame(width: 230)
                Divider()
                MapStageColumn(state: state)
                Divider()
                ScrollView {
                    MapInspector(state: state)
                        .padding(12)
                }
                .frame(width: 290)
            }
        }
        .font(.system(size: 12))
        .frame(minWidth: 1000, minHeight: 620)
    }
}

// MARK: 上の帯

private struct MapTopBar: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var state: MapEditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle(L("マッピングを使う"), isOn: $engine.outputMap.enabled)
                    .toggleStyle(.switch)
                    .help(L("切ると今までどおり（出力 1 に、四隅の調整をかけて全体を出す）"))
                Menu(L("ひな形")) {
                    Button(L("1 台（全体）")) { setSlices(OutputMap.preset(count: 1)) }
                    Button(L("横に 2 台（15% 重ねてなじませる）")) { setSlices(OutputMap.preset(count: 2, overlap: 0.15, separate: true)) }
                    Button(L("横に 3 台（15% 重ねてなじませる）")) { setSlices(OutputMap.preset(count: 3, overlap: 0.15, separate: true)) }
                    Button(L("横に 2 台（重ねない）")) { setSlices(OutputMap.preset(count: 2, separate: true)) }
                    Button(L("縦に 2 台（15% 重ねてなじませる）")) { setSlices(OutputMap.preset(count: 2, vertical: true, overlap: 0.15, separate: true)) }
                    Divider()
                    Button(L("1 つの出力に、横に 2 つ並べる")) { setSlices(OutputMap.preset(count: 2)) }
                    Button(L("1 つの出力に、横に 3 つ並べる")) { setSlices(OutputMap.preset(count: 3)) }
                }
                .fixedSize()
                .help(L("よく使う並べ方で、スライスを入れ替える（マスクはそのまま）"))
                Toggle(L("テストパターン"), isOn: $engine.testPattern).toggleStyle(.button)
                    .help(L("出力に、スライスごとの色の格子とふちを出す"))
                Toggle(L("出力にガイド"), isOn: $state.guideOn).toggleStyle(.button)
                    .help(L("この窓が開いている間、実際の出力に、選んだものの輪郭（黄色）と点を出す"))
                Toggle(L("くっつく"), isOn: $state.snapping).toggleStyle(.button)
                    .help(L("点を動かすとき、ほかのスライス・マスクの点と画面の端・中央に吸い付く（⌘ を押している間は吸い付かない）"))
                Spacer()
                Button(L("読み込む…")) { load() }
                    .help(L("マッピングだけのファイル（.halomap）を読み込む。今のマッピングと入れ替わる"))
                Button(L("保存…")) { save() }
                    .help(L("マッピングだけを .halomap に書き出す"))
            }
            HStack(spacing: 14) {
                ForEach(0..<OutputController.maxOutputs, id: \.self) { i in
                    HStack(spacing: 4) {
                        Text(L("出力 \(i + 1)")).font(.system(size: 12, weight: .semibold))
                        if state.live {
                            OutputTargetPicker(index: i)
                        } else {
                            Text(i == 0 ? L("ディスプレイ 2") : L("なし")).foregroundStyle(.secondary).frame(width: 200, alignment: .leading)
                        }
                    }
                }
                Spacer()
            }
        }
    }

    private func setSlices(_ s: [OutputSlice]) {
        engine.outputMap.slices = s
        engine.outputMap.enabled = true
        state.item = s.first.map { .slice($0.id) }
    }

    private func save() {
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: OutputMap.fileExtension) ?? .json]
        p.nameFieldStringValue = L("マッピング.\(OutputMap.fileExtension)")
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try engine.outputMap.write(to: url) } catch { alert(L("保存できませんでした"), error) }
    }

    private func load() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: OutputMap.fileExtension) ?? .json]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let m = try OutputMap.read(from: url)
            engine.outputMap = m
            state.item = m.slices.first.map { .slice($0.id) }
        } catch {
            alert(L("読み込めませんでした"), error)
        }
    }

    private func alert(_ title: String, _ error: Error) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = error.localizedDescription
        a.runModal()
    }
}

/// 出力 i の出力先（なし・ウィンドウ・ディスプレイ）
private struct OutputTargetPicker: View {
    let index: Int
    @ObservedObject private var outputs = OutputController.shared
    var body: some View {
        Picker("", selection: outputs.binding(index)) {
            Text(L("なし")).tag(OutputTarget.none)
            Text(L("ウィンドウ")).tag(OutputTarget.window)
            ForEach(outputs.screens, id: \.self) { s in
                Text(OutputController.label(of: s)).tag(OutputTarget.screen(OutputController.displayID(of: s)))
            }
        }
        .labelsHidden().frame(width: 200)
    }
}

// MARK: 一覧

private struct MapItemList: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var state: MapEditorState

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $state.item) {
                Section(L("スライス（下ほど手前）")) {
                    ForEach(Array(engine.outputMap.slices.enumerated()), id: \.element.id) { i, s in
                        row(color: sliceHue(i), name: s.name, output: s.output, on: s.enabled,
                            icon: s.hasCrop ? "triangle" : "rectangle") {
                            if let k = MapEdit.sliceIndex(engine.outputMap, s.id) { engine.outputMap.slices[k].enabled.toggle() }
                        }
                        .tag(MapItem.slice(s.id))
                    }
                    .onMove { engine.outputMap.slices.move(fromOffsets: $0, toOffset: $1) }
                }
                Section(L("マスク")) {
                    ForEach(engine.outputMap.masks) { m in
                        row(color: .gray, name: m.name, output: m.output, on: m.enabled, icon: "pentagon.fill") {
                            if let k = MapEdit.maskIndex(engine.outputMap, m.id) { engine.outputMap.masks[k].enabled.toggle() }
                        }
                        .tag(MapItem.mask(m.id))
                    }
                    .onMove { engine.outputMap.masks.move(fromOffsets: $0, toOffset: $1) }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 6) {
                Menu {
                    Button(L("スライス（四角）")) { addSlice(.rect) }
                    Button(L("三角のスライス")) { addSlice(.triangle) }
                    Button(L("多角形のスライス")) { addSlice(.polygon) }
                    Divider()
                    Button(L("マスク")) { addMask() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.visible)
                .fixedSize()
                .help(L("スライス・マスクを足す（今見ている出力に）"))
                Button(L("複製")) {
                    guard let it = state.item else { return }
                    var m = engine.outputMap
                    if let n = MapEdit.duplicate(&m, it) { engine.outputMap = m; state.item = n }
                }
                .disabled(state.item == nil)
                .help(L("選んだものを、少しずらして複製"))
                Spacer()
                Button { remove() } label: { Image(systemName: "minus") }
                    .disabled(state.item == nil)
                    .help(L("選んだものを消す"))
            }
            .padding(8)
        }
    }

    private func row(color: Color, name: String, output: Int, on: Bool, icon: String, toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(color)
            Text(name).lineLimit(1)
            Spacer(minLength: 2)
            Text(L("出力 \(output + 1)")).font(.system(size: 10)).foregroundStyle(.secondary)
            Button(action: toggle) {
                Image(systemName: on ? "eye" : "eye.slash")
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(on ? L("出さない") : L("出す"))
        }
        .opacity(on ? 1 : 0.5)
    }

    private func addSlice(_ shape: NewSliceShape) {
        guard engine.outputMap.slices.count < OutputMap.maxSlices else { NSSound.beep(); return }
        let s = MapEdit.newSlice(shape, output: state.output, number: engine.outputMap.slices.count + 1)
        engine.outputMap.slices.append(s)
        state.tab = .output
        state.item = .slice(s.id)
        state.mode = shape == .rect ? .corners : .crop
    }

    private func addMask() {
        let m = MapEdit.newMask(output: state.output, number: engine.outputMap.masks.count + 1)
        engine.outputMap.masks.append(m)
        state.tab = .output
        state.item = .mask(m.id)
    }

    private func remove() {
        guard let it = state.item else { return }
        switch it {
        case .slice(let id):
            guard let i = MapEdit.sliceIndex(engine.outputMap, id) else { return }
            engine.outputMap.slices.remove(at: i)
            let rest = engine.outputMap.slices
            state.item = rest.isEmpty ? nil : .slice(rest[min(i, rest.count - 1)].id)
        case .mask(let id):
            guard let i = MapEdit.maskIndex(engine.outputMap, id) else { return }
            engine.outputMap.masks.remove(at: i)
            let rest = engine.outputMap.masks
            state.item = rest.isEmpty ? nil : .mask(rest[min(i, rest.count - 1)].id)
        }
    }
}

// MARK: 舞台

private struct MapStageColumn: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var state: MapEditorState

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 10).padding(.vertical, 7)
            if state.tab == .output { modeBar.padding(.horizontal, 10).padding(.bottom, 6) }
            GeometryReader { g in
                stage(g.size)
            }
            .background(Color(white: 0.07))
            .clipped()
            footer.padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $state.tab) {
                Text(L("取る所")).tag(MapEditorState.Tab.input)
                Text(L("映す所")).tag(MapEditorState.Tab.output)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            .help(L("取る所：コンポジションのどこを取るか　映す所：出力の画面のどこへ映すか"))
            if state.tab == .output {
                Picker("", selection: $state.output) {
                    ForEach(0..<OutputController.maxOutputs, id: \.self) { Text(L("出力 \($0 + 1)")).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            Spacer()
            Text(L("拡大 \(Int((state.zoom * 100).rounded()))%")).font(.system(size: 11)).foregroundStyle(.secondary)
                .monospacedDigit()
            Button { state.zoom(by: 1 / 1.25, around: nil, size: lastSize) } label: { Image(systemName: "minus.magnifyingglass") }
                .help(L("小さく（スクロールでも）"))
            Button { state.zoom(by: 1.25, around: nil, size: lastSize) } label: { Image(systemName: "plus.magnifyingglass") }
                .help(L("大きく（スクロールでも）"))
            Button(L("合わせる")) { state.fit() }
                .help(L("拡大と移動を元に戻して、全体を見る"))
        }
    }

    @ViewBuilder private var modeBar: some View {
        HStack(spacing: 8) {
            switch state.item {
            case .slice?:
                Text(L("点")).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { state.mode }, set: { state.setMode($0) })) {
                    ForEach(MapEditMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                .help(L("四隅：面の 4 つの角　メッシュ：格子の点で面をゆがめる　切り抜き：面の中の多角形"))
            case .mask?:
                Text(L("マスクの点を動かす")).foregroundStyle(.secondary)
            case nil:
                Text(L("一覧でスライスかマスクを選ぶ")).foregroundStyle(.secondary)
            }
            Spacer()
            if !state.selectedPoints.isEmpty {
                Text(L("選んだ点 \(state.selectedPoints.count) 個")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(height: 22)
    }

    /// 拡大ボタン用：舞台の大きさ（最後に描いたとき）
    private var lastSize: CGSize { MapStageSize.last }

    @ViewBuilder private func stage(_ size: CGSize) -> some View {
        let f = MapStageFrame(size: size, aspect: state.aspect, zoom: state.zoom, pan: state.pan)
        let _ = MapStageSize.last = size
        ZStack(alignment: .topLeading) {
            Group {
                if !state.live {
                    // 書き出しのとき（Metal の絵は出ない）
                    Rectangle().fill(Color(white: 0.2))
                } else if state.tab == .input {
                    MetalPreview(kind: .composition)
                } else {
                    OutputPreview(output: state.output)
                }
            }
            .frame(width: f.content.width, height: f.content.height)
            .position(x: f.content.midX, y: f.content.midY)
            if state.tab == .output, let img = backdrop {
                Image(nsImage: img).resizable()
                    .frame(width: f.content.width, height: f.content.height)
                    .position(x: f.content.midX, y: f.content.midY)
                    .opacity(engine.outputMap.backdropOpacity)
                    .allowsHitTesting(false)
            }
            MapStageOverlay(state: state, frame: f)
                .allowsHitTesting(false)
            MapStageInput(state: state)
        }
        .frame(width: size.width, height: size.height)
    }

    private var backdrop: NSImage? {
        guard let path = engine.outputMap.backdrops[String(state.output)] else { return nil }
        return MapBackdropCache.image(path)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(hint).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if state.tab == .output {
                Text(L("下敷き")).font(.system(size: 11)).foregroundStyle(.secondary)
                Button(L("写真を選ぶ…")) { chooseBackdrop() }
                    .help(L("会場の写真などを、この出力の舞台に薄く敷く（合わせる画面だけ。出力には出ない）"))
                Button(L("外す")) { engine.outputMap.backdrops[String(state.output)] = nil }
                    .disabled(engine.outputMap.backdrops[String(state.output)] == nil)
                ValueDrag(label: L("濃さ"), value: $engine.outputMap.backdropOpacity, range: 0...1, perPoint: 0.005,
                          defaultValue: 0.5, format: EffectParam.percent)
                    .frame(width: 110, height: 24)
            }
        }
    }

    private var hint: String {
        if state.tab == .input {
            return L("四角をドラッグで動かす・角と辺で大きさ・上の丸で回す（⇧ で 15° ずつ）。何もない所のドラッグで舞台を動かす・スクロールで拡大")
        }
        let common = L("点はクリックで選ぶ（⇧で足す・囲んでも）・矢印キーで 1 ピクセル（⇧で 10）。⌥ドラッグで舞台を動かす")
        switch state.item {
        case .mask?: return L("辺をクリックで点を足す・Delete で消す。中をドラッグで全体を動かす。") + common
        case .slice?:
            switch state.mode {
            case .corners: return L("角をドラッグ・面の中をドラッグで全体を動かす。") + common
            case .mesh: return L("格子の点をドラッグして面をゆがめる。") + common
            case .crop: return L("辺をクリックで点を足す・Delete で消す。") + common
            }
        case nil: return L("スライスかマスクをクリックで選ぶ。") + common
        }
    }

    private func chooseBackdrop() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        engine.outputMap.backdrops[String(state.output)] = url.path
    }
}

/// 舞台の大きさ（拡大のボタンで、真ん中を中心にするため）
private enum MapStageSize {
    static var last = CGSize(width: 800, height: 500)
}

/// 下敷きの写真（読み込んだものを覚えておく）
enum MapBackdropCache {
    private static var cache: [String: NSImage] = [:]
    static func image(_ path: String) -> NSImage? {
        if let i = cache[path] { return i }
        guard let i = NSImage(contentsOfFile: path) else { return nil }
        cache[path] = i
        return i
    }
}

/// 舞台の上の線・点（マウスは受けない）
private struct MapStageOverlay: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var state: MapEditorState
    let frame: MapStageFrame

    var body: some View {
        Canvas { ctx, _ in
            let f = frame
            ctx.stroke(Path(f.content), with: .color(.white.opacity(0.35)), lineWidth: 1)
            if state.tab == .input { drawInput(&ctx, f) } else { drawOutput(&ctx, f) }
            if let r = state.marquee {
                ctx.fill(Path(r), with: .color(.yellow.opacity(0.08)))
                ctx.stroke(Path(r), with: .color(.yellow), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }

    private func poly(_ pts: [CGPoint], closed: Bool = true) -> Path {
        Path { p in
            guard let first = pts.first else { return }
            p.move(to: first)
            pts.dropFirst().forEach { p.addLine(to: $0) }
            if closed { p.closeSubpath() }
        }
    }

    private func handle(_ ctx: inout GraphicsContext, _ q: CGPoint, selected: Bool, round: Bool = false) {
        let r: CGFloat = selected ? 6 : 4.5
        let rect = CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)
        let shape = round ? Path(ellipseIn: rect) : Path(rect)
        ctx.fill(shape, with: .color(selected ? .yellow : .white))
        ctx.stroke(shape, with: .color(.black), lineWidth: 1)
    }

    private func label(_ ctx: inout GraphicsContext, _ text: String, at q: CGPoint, color: Color) {
        ctx.draw(Text(text).font(.system(size: 11, weight: .bold)).foregroundStyle(color), at: q)
    }

    // 取る所
    private func drawInput(_ ctx: inout GraphicsContext, _ f: MapStageFrame) {
        let map = engine.outputMap
        let a = state.aspect
        for (i, s) in map.slices.enumerated() {
            let sel = state.item == .slice(s.id)
            let q = poly(MapEdit.inputQuad(s, aspect: a).map(f.toView))
            ctx.fill(q, with: .color(sliceHue(i).opacity(sel ? 0.22 : 0.1)))
            let dash: [CGFloat] = s.source == .composition ? [] : [5, 3]
            ctx.stroke(q, with: .color(sel ? .yellow : sliceHue(i).opacity(s.enabled ? 0.9 : 0.4)),
                       style: StrokeStyle(lineWidth: sel ? 2 : 1, dash: dash))
            // 取った絵の左上（反転・回転の向きがわかるように）
            let o = f.toView(s.sourceUV(u: 0.06, v: 0.06, aspect: a))
            ctx.fill(Path(ellipseIn: CGRect(x: o.x - 3, y: o.y - 3, width: 6, height: 6)), with: .color(sliceHue(i)))
            label(&ctx, s.name, at: f.toView(MapEdit.inputPoint(s, hx: 0, hy: 0, aspect: a)), color: .white)
        }
        if case .slice(let id)? = state.item, let s = map.slices.first(where: { $0.id == id }) {
            let h = state.inputHandles(s, f)
            ctx.stroke(poly([h.top, h.knob], closed: false), with: .color(.yellow), lineWidth: 1)
            handle(&ctx, h.knob, selected: true, round: true)
            for (_, _, q) in h.handles { handle(&ctx, q, selected: false) }
        }
    }

    // 映す所
    private func drawOutput(_ ctx: inout GraphicsContext, _ f: MapStageFrame) {
        let map = engine.outputMap
        let out = state.output
        for (i, s) in map.slices.enumerated() where s.output == out {
            let sel = state.item == .slice(s.id)
            let o = poly(MapEdit.outline(s).map(f.toView))
            ctx.fill(o, with: .color(sliceHue(i).opacity(sel ? 0.16 : 0.08)))
            ctx.stroke(o, with: .color(sel ? .yellow : sliceHue(i).opacity(s.enabled ? 0.9 : 0.35)), lineWidth: sel ? 2 : 1)
            if s.hasCrop {
                let c = poly(MapEdit.cropOutline(s).map(f.toView))
                ctx.stroke(c, with: .color(sliceHue(i).opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let c = s.outputPoint(u: 0.5, v: 0.5) { label(&ctx, s.name, at: f.toView(c), color: .white) }
        }
        for m in map.masks where m.output == out && m.points.count >= 2 {
            let sel = state.item == .mask(m.id)
            let p = poly(m.points.map { f.toView(MapEdit.pt($0)) })
            ctx.fill(p, with: .color(.black.opacity(m.enabled ? 0.45 : 0.2)))
            ctx.stroke(p, with: .color(sel ? .yellow : .cyan.opacity(0.8)), style: StrokeStyle(lineWidth: sel ? 2 : 1, dash: [5, 3]))
            let c = m.points.map(MapEdit.pt).reduce(MapP.zero, +) / Double(m.points.count)
            label(&ctx, m.name, at: f.toView(c), color: .cyan)
        }
        // 選んだものの点
        guard let it = state.item, state.outputOf(it) == out else { return }
        let mode = it.isMask ? MapEditMode.corners : state.mode
        if case .slice(let id) = it, let s = map.slices.first(where: { $0.id == id }) {
            switch mode {
            case .mesh:
                if let mesh = s.mesh, mesh.isValid {
                    let steps = max(mesh.cols, mesh.rows) * 6
                    for i in 0...mesh.cols {
                        let u = Double(i) / Double(mesh.cols)
                        ctx.stroke(poly(MapEdit.mappedLine(s, from: MapP(u, 0), to: MapP(u, 1), steps: steps).map(f.toView), closed: false),
                                   with: .color(.yellow.opacity(0.55)), lineWidth: 1)
                    }
                    for j in 0...mesh.rows {
                        let v = Double(j) / Double(mesh.rows)
                        ctx.stroke(poly(MapEdit.mappedLine(s, from: MapP(0, v), to: MapP(1, v), steps: steps).map(f.toView), closed: false),
                                   with: .color(.yellow.opacity(0.55)), lineWidth: 1)
                    }
                }
            case .crop:
                if s.crop.count >= 2 {
                    ctx.stroke(poly(MapEdit.cropOutline(s).map(f.toView)), with: .color(.yellow), lineWidth: 1.5)
                }
            case .corners:
                break
            }
        }
        let pts = MapEdit.outputPoints(map, it, mode)
        for (k, p) in pts.enumerated() {
            guard let p else { continue }
            handle(&ctx, f.toView(p), selected: state.selectedPoints.contains(k), round: mode != .corners || it.isMask)
        }
        if case .slice = it, mode == .crop, pts.isEmpty, let c = MapEdit.referencePoints(map, it).first {
            label(&ctx, L("切り抜きはまだありません（右の設定で作る）"), at: f.toView(c) + CGPoint(x: 120, y: -14), color: .yellow)
        }
    }
}

private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }

// MARK: 設定

private struct MapInspector: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var state: MapEditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state.item {
            case .slice(let id)?:
                if let i = MapEdit.sliceIndex(engine.outputMap, id) {
                    SliceInspector(slice: $engine.outputMap.slices[i], state: state, layers: engine.layers.map { ($0.id, $0.displayName) },
                                   gamma: $engine.outputMap.blendGamma)
                        .id(id)
                }
            case .mask(let id)?:
                if let i = MapEdit.maskIndex(engine.outputMap, id) {
                    MaskInspector(mask: $engine.outputMap.masks[i]).id(id)
                }
            case nil:
                Text(L("一覧でスライスかマスクを選ぶと、ここに設定が出ます。"))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func sectionTitle(_ s: String) -> some View {
    Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 6)
}

private func outputChoice(_ b: Binding<Int>) -> some View {
    Picker(L("出力"), selection: b) {
        ForEach(0..<OutputController.maxOutputs, id: \.self) { Text(L("出力 \($0 + 1)")).tag($0) }
    }
    .pickerStyle(.segmented)
}

private struct SliceInspector: View {
    @Binding var slice: OutputSlice
    @ObservedObject var state: MapEditorState
    let layers: [(UUID, String)]
    @Binding var gamma: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L("名前"), text: $slice.name)
            HStack {
                Toggle(L("出す"), isOn: $slice.enabled)
                Spacer()
            }
            outputChoice($slice.output)
            Picker(L("元の絵", note: "マッピング"), selection: $slice.source) {
                Text(L("全体（コンポジション）")).tag(SliceSource.composition)
                ForEach(layers, id: \.0) { Text($0.1).tag(SliceSource.layer($0.0)) }
                if let id = slice.source.layerID, !layers.contains(where: { $0.0 == id }) {
                    Text(L("（無いレイヤー）")).tag(slice.source)
                }
            }
            .help(L("レイヤーを選ぶと、そのレイヤーだけ（レイヤーのエフェクト込み）を映す"))

            sectionTitle(L("取る所"))
            HStack(spacing: 4) { inputDrag("X", 0); inputDrag("Y", 1) }
            HStack(spacing: 4) { inputDrag(L("幅"), 2); inputDrag(L("高さ"), 3) }
            ValueDrag(label: L("回転"), value: $slice.inputRotation, range: -180...180, perPoint: 0.2, defaultValue: 0,
                      format: { String(format: "%.1f°", $0) })
                .frame(height: 26)
            HStack {
                Toggle(L("左右反転"), isOn: $slice.flipH)
                Toggle(L("上下反転"), isOn: $slice.flipV)
            }

            sectionTitle(L("端をなじませる"))
            HStack(spacing: 4) { feather(L("左"), 0); feather(L("右"), 1) }
            HStack(spacing: 4) { feather(L("上"), 2); feather(L("下"), 3) }
            ValueDrag(label: L("ガンマ"), value: $gamma, range: 1...3, perPoint: 0.005, defaultValue: 2.2,
                      format: { String(format: "%.2f", $0) })
                .frame(height: 26)
                .help(L("なじませる所の明るさのつながり方（全部のスライスで共通。プロジェクターに合わせる。ふつうは 2.2）"))

            sectionTitle(L("色"))
            ValueDrag(label: L("不透明度"), value: $slice.opacity, range: 0...1, perPoint: 0.003, defaultValue: 1, format: EffectParam.percent)
                .frame(height: 26)
            HStack(spacing: 4) {
                ValueDrag(label: L("明るさ"), value: $slice.brightness, range: -1...1, perPoint: 0.003, defaultValue: 0, format: EffectParam.percent)
                    .frame(height: 26)
                ValueDrag(label: L("コントラスト"), value: $slice.contrast, range: -1...1, perPoint: 0.003, defaultValue: 0, format: EffectParam.percent)
                    .frame(height: 26)
            }
            HStack(spacing: 4) { gain(L("赤"), 0); gain(L("緑"), 1); gain(L("青"), 2) }
                .help(L("プロジェクターごとの色の違いを合わせる"))

            sectionTitle(L("映す所（\(state.mode.label)）"))
            modeSettings
        }
    }

    @ViewBuilder private var modeSettings: some View {
        switch state.mode {
        case .corners:
            Button(L("四隅を元に戻す")) { slice.corners = [[0, 0], [1, 0], [1, 1], [0, 1]] }
                .help(L("出力の画面いっぱいに戻す"))
        case .mesh:
            if let m = slice.mesh, m.isValid {
                Stepper(L("横のマス \(m.cols)"), value: Binding(get: { m.cols }, set: { MapEdit.setMeshSize(&slice, cols: $0, rows: m.rows) }),
                        in: 1...SliceMesh.maxCells)
                    .help(L("今の形を保ったまま、点の数を変える"))
                Stepper(L("縦のマス \(m.rows)"), value: Binding(get: { m.rows }, set: { MapEdit.setMeshSize(&slice, cols: m.cols, rows: $0) }),
                        in: 1...SliceMesh.maxCells)
                Toggle(L("なめらかに"), isOn: Binding(get: { m.smooth }, set: { slice.mesh?.smooth = $0 }))
                    .help(L("点の間をなめらかな曲線でつなぐ。切ると折れ線"))
                HStack {
                    Button(L("メッシュを元に戻す")) { slice.mesh = .regular(cols: m.cols, rows: m.rows) }
                        .help(L("点を等間隔に戻す（マスの数はそのまま）"))
                    Button(L("外す")) {
                        slice.mesh = nil
                        state.mode = .corners
                    }
                    .help(L("メッシュを使わない（四隅だけ）"))
                }
            } else {
                Button(L("メッシュを作る（2×2）")) { MapEdit.enterMesh(&slice) }
            }
        case .crop:
            Text(slice.hasCrop ? L("点 \(slice.crop.count) 個") : L("切り抜きはまだありません"))
                .foregroundStyle(.secondary)
            HStack {
                Button(L("三角で作る")) { slice.crop = [[0.5, 0], [1, 1], [0, 1]]; state.selectedPoints = [] }
                Button(L("四角で作る")) { slice.crop = [[0.1, 0.1], [0.9, 0.1], [0.9, 0.9], [0.1, 0.9]]; state.selectedPoints = [] }
            }
            .help(L("今の切り抜きと入れ替える"))
            Toggle(L("内と外を入れ替える"), isOn: $slice.cropInvert)
                .help(L("形の中を消して、外だけ出す"))
                .disabled(!slice.hasCrop)
            Button(L("切り抜きを外す")) { slice.crop = []; state.selectedPoints = [] }
                .disabled(slice.crop.isEmpty)
        }
    }

    private func inputDrag(_ label: String, _ i: Int) -> some View {
        ValueDrag(label: label, value: Binding(get: { slice.input[i] },
                                               set: { slice.input[i] = i >= 2 ? min(max($0, 0.01), 1) : min(max($0, -1), 2) }),
                  range: i >= 2 ? 0.01...1 : -1...2, perPoint: 0.001, defaultValue: i >= 2 ? 1 : 0, format: EffectParam.percent)
            .frame(height: 26)
    }
    private func feather(_ label: String, _ i: Int) -> some View {
        ValueDrag(label: label, value: Binding(get: { slice.feather.count == 4 ? slice.feather[i] : 0 },
                                               set: { if slice.feather.count != 4 { slice.feather = [0, 0, 0, 0] }; slice.feather[i] = $0 }),
                  range: 0...0.5, perPoint: 0.001, defaultValue: 0, format: EffectParam.percent)
            .frame(height: 26)
    }
    private func gain(_ label: String, _ i: Int) -> some View {
        ValueDrag(label: label, value: Binding(get: { slice.gain.count == 3 ? slice.gain[i] : 1 },
                                               set: { if slice.gain.count != 3 { slice.gain = [1, 1, 1] }; slice.gain[i] = $0 }),
                  range: 0...2, perPoint: 0.003, defaultValue: 1, format: EffectParam.percent)
            .frame(height: 26)
    }
}

private struct MaskInspector: View {
    @Binding var mask: OutputMask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L("名前"), text: $mask.name)
            HStack {
                Toggle(L("使う"), isOn: $mask.enabled)
                Spacer()
            }
            outputChoice($mask.output)
            Toggle(L("内と外を入れ替える"), isOn: $mask.invert)
                .help(L("切ると形の中を黒く、入れると形の外を黒く"))
            Text(L("点 \(mask.points.count) 個")).foregroundStyle(.secondary)
            Button(L("形を元に戻す（四角）")) { mask.points = [[0.4, 0.4], [0.6, 0.4], [0.6, 0.6], [0.4, 0.6]] }
            Text(L("マスクは、スライスを全部描いたあとに、その出力の上を黒く塗ります。"))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 開発用：窓を画像に書き出す（画面には出さない）

enum MapEditorPreview {
    /// 見本のマッピング：四角・メッシュ付き・三角の切り抜き、マスク
    static func exampleMap() -> OutputMap {
        var m = OutputMap()
        m.enabled = true
        var a = OutputSlice()
        a.name = L("左の壁")
        a.input = [0, 0, 0.5, 1]
        a.corners = [[0.05, 0.1], [0.45, 0.06], [0.47, 0.9], [0.04, 0.85]]
        a.feather = [0, 0.1, 0, 0]
        var b = OutputSlice()
        b.name = L("柱（メッシュ）")
        b.input = [0.5, 0, 0.5, 1]
        b.inputRotation = 12
        b.corners = [[0.52, 0.08], [0.95, 0.12], [0.93, 0.92], [0.55, 0.88]]
        var mesh = SliceMesh.regular(cols: 3, rows: 2)
        mesh.points[mesh.index(col: 1, row: 1)] = [0.3, 0.6]
        mesh.points[mesh.index(col: 2, row: 1)] = [0.72, 0.42]
        b.mesh = mesh
        var c = OutputSlice()
        c.name = L("三角")
        c.input = [0.3, 0.2, 0.4, 0.5]
        c.corners = [[0.3, 0.45], [0.7, 0.45], [0.7, 0.98], [0.3, 0.98]]
        c.crop = [[0.5, 0], [1, 1], [0, 1]]
        var mask = OutputMask()
        mask.name = L("ドア")
        mask.points = [[0.12, 0.5], [0.24, 0.48], [0.25, 0.86], [0.2, 0.7], [0.13, 0.84]]
        m.slices = [a, b, c]
        m.masks = [mask]
        return m
    }

    /// VJPlayer --map-editor-preview out.png [input|output] [corners|mesh|crop|mask]
    static func write(path: String, tab: String, mode: String) {
        let engine = Engine(persistent: false)
        engine.outputMap = exampleMap()
        let state = MapEditorState(engine: engine, live: false)
        let m = engine.outputMap
        state.tab = tab == "input" ? .input : .output
        switch mode {
        case "mask":
            state.item = .mask(m.masks[0].id)
            state.selectedPoints = [1, 2]
        case "mesh":
            state.item = .slice(m.slices[1].id)
            state.setMode(.mesh)
            state.selectedPoints = [5]
        case "crop":
            state.item = .slice(m.slices[2].id)
            state.setMode(.crop)
            state.selectedPoints = [0]
        default:
            state.item = .slice(m.slices[tab == "input" ? 1 : 0].id)
            state.setMode(.corners)
            state.selectedPoints = [1]
        }
        let root = OutputMapEditor(state: state)
            .environmentObject(engine)
            .frame(width: 1240, height: 800)
        CardPreview.writeView(AnyView(root), path: path)
    }
}
