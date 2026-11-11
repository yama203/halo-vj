import AppKit
import Metal
import QuartzCore
import SwiftUI
import simd

// 出力の分割（マッピング）：コンポジションのどこを（取る所＝四角）、どの出力のどこへ（映す所＝四隅・メッシュ）、
// 端をどれだけなじませて（エッジブレンド）出すか。
// 複数のプロジェクター・LED ウォール・別々のディスプレイ（出力 1〜3）に、コンポジションの一部ずつを出す。
// 分割を使わないときは今までどおり（出力 1 に、四隅の調整をかけて全体を出す）。プロジェクトに保存される。
//
// スライス 1 つの絵の流れ：
//   元の絵 → 取る所（四角＋回転・反転） → スライスの中の座標 (u,v) 0…1
//   → 切り抜き（多角形） → メッシュ（(u,v) → (u',v')） → 四隅（射影変換） → 出力の画面
//   出力ごとに最後にマスク（多角形で黒く塗る）

/// スライスの元の絵
enum SliceSource: Codable, Equatable, Hashable {
    /// 全体（コンポジション）
    case composition
    /// このレイヤーだけ（レイヤーのエフェクト込み。コンポジションのエフェクト・変形は無し）
    case layer(UUID)

    var layerID: UUID? {
        if case .layer(let id) = self { return id }
        return nil
    }
}

/// メッシュ：スライスの面を格子の点でゆがめる。点は「スライスの中の座標」で持つ（四隅を動かすとメッシュごと動く）
struct SliceMesh: Codable, Equatable {
    static let maxCells = 8
    /// マスの数（1…8）
    var cols = 2, rows = 2
    /// (cols+1)*(rows+1) 個。行ごとに左→右、上→下
    var points: [[Double]] = []
    /// 点の間をなめらかに（Catmull-Rom）。false は折れ線
    var smooth = true

    /// 等間隔の格子
    static func regular(cols: Int, rows: Int) -> SliceMesh {
        let c = min(max(cols, 1), maxCells), r = min(max(rows, 1), maxCells)
        var pts: [[Double]] = []
        for j in 0...r { for i in 0...c { pts.append([Double(i) / Double(c), Double(j) / Double(r)]) } }
        return SliceMesh(cols: c, rows: r, points: pts, smooth: true)
    }

    var isValid: Bool {
        cols >= 1 && rows >= 1 && points.count == (cols + 1) * (rows + 1) && points.allSatisfy { $0.count >= 2 }
    }

    /// 点の番号
    func index(col i: Int, row j: Int) -> Int { j * (cols + 1) + i }

    /// 格子の点（外側は、端の 2 点をまっすぐ伸ばした所）
    func point(col i: Int, row j: Int) -> SIMD2<Double> {
        if i < 0 { return 2 * point(col: 0, row: j) - point(col: 1, row: j) }
        if i > cols { return 2 * point(col: cols, row: j) - point(col: cols - 1, row: j) }
        if j < 0 { return 2 * point(col: i, row: 0) - point(col: i, row: 1) }
        if j > rows { return 2 * point(col: i, row: rows) - point(col: i, row: rows - 1) }
        let p = points[index(col: i, row: j)]
        return SIMD2(p[0], p[1])
    }

    /// (u,v) → 動かした先（スライスの中の座標）
    func position(u: Double, v: Double) -> SIMD2<Double> {
        guard isValid else { return SIMD2(u, v) }
        let fx = min(max(u, 0), 1) * Double(cols), fy = min(max(v, 0), 1) * Double(rows)
        let i = min(Int(fx), cols - 1), j = min(Int(fy), rows - 1)
        let tx = fx - Double(i), ty = fy - Double(j)
        // 端の外へはまっすぐ伸ばす（0…1 の外の u,v も同じ形のまま）
        let ex = u < 0 ? u * Double(cols) : (u > 1 ? (u - 1) * Double(cols) : 0)
        let ey = v < 0 ? v * Double(rows) : (v > 1 ? (v - 1) * Double(rows) : 0)
        let ttx = tx + ex, tty = ty + ey
        if !smooth {
            let a = point(col: i, row: j), b = point(col: i + 1, row: j)
            let c = point(col: i, row: j + 1), d = point(col: i + 1, row: j + 1)
            let top = a + (b - a) * ttx, bottom = c + (d - c) * ttx
            return top + (bottom - top) * tty
        }
        func cr(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ p3: SIMD2<Double>, _ t: Double) -> SIMD2<Double> {
            let t2 = t * t, t3 = t2 * t
            let a = 2 * p1
            let b = (p2 - p0) * t
            let c = (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
            let d = (3 * p1 - p0 - 3 * p2 + p3) * t3
            return 0.5 * (a + b + c + d)
        }
        var col: [SIMD2<Double>] = []
        for jj in (j - 1)...(j + 2) {
            col.append(cr(point(col: i - 1, row: jj), point(col: i, row: jj), point(col: i + 1, row: jj), point(col: i + 2, row: jj), ttx))
        }
        return cr(col[0], col[1], col[2], col[3], tty)
    }

    /// 今の形を保ったまま点の数を変える（今の面を新しい格子で取り直す）
    func resized(cols: Int, rows: Int) -> SliceMesh {
        var m = SliceMesh.regular(cols: cols, rows: rows)
        m.smooth = smooth
        for j in 0...m.rows {
            for i in 0...m.cols {
                let p = position(u: Double(i) / Double(m.cols), v: Double(j) / Double(m.rows))
                m.points[m.index(col: i, row: j)] = [p.x, p.y]
            }
        }
        return m
    }
}

extension SliceMesh {
    private enum CodingKeys: String, CodingKey { case cols, rows, points, smooth }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cols = min(max(try c.decodeIfPresent(Int.self, forKey: .cols) ?? 2, 1), Self.maxCells)
        let rows = min(max(try c.decodeIfPresent(Int.self, forKey: .rows) ?? 2, 1), Self.maxCells)
        var m = SliceMesh.regular(cols: cols, rows: rows)
        if let p = try c.decodeIfPresent([[Double]].self, forKey: .points), p.count == m.points.count, p.allSatisfy({ $0.count >= 2 }) {
            m.points = p
        }
        m.smooth = try c.decodeIfPresent(Bool.self, forKey: .smooth) ?? true
        self = m
    }
}

struct OutputSlice: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = L("スライス")
    var enabled = true
    /// 出す出力（0 = 出力 1）
    var output = 0
    /// 取る所：コンポジションの左上を 0,0、右下を 1,1 とした四角（x, y, 幅, 高さ）
    var input: [Double] = [0, 0, 1, 1]
    /// 映す所：出力の画面の左上を 0,0、右下を 1,1 とした四隅（左上・右上・右下・左下）
    var corners: [[Double]] = [[0, 0], [1, 0], [1, 1], [0, 1]]
    /// 端をなじませる幅（スライスの幅・高さに対する割合。左・右・上・下）
    var feather: [Double] = [0, 0, 0, 0]
    /// 元の絵（全体・レイヤー）
    var source = SliceSource.composition
    /// 取る所の四角を、その中心で回す（度。時計回り）
    var inputRotation = 0.0
    /// 取る所を左右・上下に反転
    var flipH = false, flipV = false
    /// メッシュ（nil ＝ メッシュなし）
    var mesh: SliceMesh? = nil
    /// 切り抜き：スライスの中の座標の多角形（3 点以上で有効）
    var crop: [[Double]] = []
    /// true：形の中を消す（外だけ出す）
    var cropInvert = false
    var opacity = 1.0
    /// -1…1
    var brightness = 0.0
    /// -1…1
    var contrast = 0.0
    /// 赤・緑・青
    var gain: [Double] = [1, 1, 1]

    var inputRect: CGRect { CGRect(x: input[0], y: input[1], width: input[2], height: input[3]) }

    /// 切り抜きの点の上限（描くときに渡せる数）
    static let maxCropPoints = 32

    /// 切り抜きが効いているか
    var hasCrop: Bool { crop.count >= 3 }

    /// 四隅の射影変換（スライスの中の座標 → 出力の画面）
    var homography: simd_float3x3 {
        let q = (corners.count == 4 ? corners : [[0, 0], [1, 0], [1, 1], [0, 1]]).map { SIMD2(Float($0[0]), Float($0[1])) }
        return Homography.squareToQuad(q)
    }

    /// スライスの中の (u,v) が、出力の画面のどこに出るか（メッシュ・四隅込み）。後ろにある所（w ≦ 0）は nil
    func outputPoint(u: Double, v: Double) -> SIMD2<Double>? {
        let p = mesh?.position(u: u, v: v) ?? SIMD2(u, v)
        let h = homography * SIMD3(Float(p.x), Float(p.y), 1)
        guard h.z > 1e-6 else { return nil }
        return SIMD2(Double(h.x / h.z), Double(h.y / h.z))
    }

    /// 取る所：スライスの中の (u,v) → 元の絵の UV（回転・反転込み）。aspect は元の絵の横 ÷ 縦
    func sourceUV(u: Double, v: Double, aspect: Double) -> SIMD2<Double> {
        let ip = input.count == 4 ? input : [0, 0, 1, 1]
        let lx = flipH ? 1 - u : u, ly = flipV ? 1 - v : v
        let a = max(aspect, 1e-6)
        // 画面の形のままで回す（横は aspect 倍した長さで）
        let dx = (lx - 0.5) * ip[2] * a, dy = (ly - 0.5) * ip[3]
        let t = inputRotation * .pi / 180
        let rx = cos(t) * dx - sin(t) * dy, ry = sin(t) * dx + cos(t) * dy
        return SIMD2(ip[0] + ip[2] / 2 + rx / a, ip[1] + ip[3] / 2 + ry)
    }

    /// 取る所の四角の四隅（元の絵の UV。左上・右上・右下・左下。回転・反転込み）
    func inputCorners(aspect: Double) -> [SIMD2<Double>] {
        [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map { sourceUV(u: $0.0, v: $0.1, aspect: aspect) }
    }
}

extension OutputSlice {
    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, output, input, corners, feather, source, inputRotation, flipH, flipV, mesh, crop, cropInvert
        case opacity, brightness, contrast, gain
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = OutputSlice()
        s.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        s.name = try c.decodeIfPresent(String.self, forKey: .name) ?? s.name
        s.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        s.output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        if let v = try c.decodeIfPresent([Double].self, forKey: .input), v.count == 4 { s.input = v }
        if let v = try c.decodeIfPresent([[Double]].self, forKey: .corners), v.count == 4, v.allSatisfy({ $0.count >= 2 }) { s.corners = v }
        if let v = try c.decodeIfPresent([Double].self, forKey: .feather), v.count == 4 { s.feather = v }
        s.source = (try? c.decodeIfPresent(SliceSource.self, forKey: .source)) ?? .composition
        s.inputRotation = try c.decodeIfPresent(Double.self, forKey: .inputRotation) ?? 0
        s.flipH = try c.decodeIfPresent(Bool.self, forKey: .flipH) ?? false
        s.flipV = try c.decodeIfPresent(Bool.self, forKey: .flipV) ?? false
        s.mesh = try c.decodeIfPresent(SliceMesh.self, forKey: .mesh)
        s.crop = (try c.decodeIfPresent([[Double]].self, forKey: .crop) ?? []).filter { $0.count >= 2 }
        s.cropInvert = try c.decodeIfPresent(Bool.self, forKey: .cropInvert) ?? false
        s.opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        s.brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        s.contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        if let v = try c.decodeIfPresent([Double].self, forKey: .gain), v.count == 3 { s.gain = v }
        self = s
    }
}

/// マスク：出力の画面の上の多角形を黒く塗る（スライスを全部描いたあと）
struct OutputMask: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = L("マスク")
    var enabled = true
    /// 塗る出力（0 = 出力 1）
    var output = 0
    /// 出力の画面の座標（0…1）。3 点以上で有効
    var points: [[Double]] = []
    /// true：形の外を黒く
    var invert = false

    static let maxPoints = 256
    var isValid: Bool { points.count >= 3 }
}

extension OutputMask {
    private enum CodingKeys: String, CodingKey { case id, name, enabled, output, points, invert }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var m = OutputMask()
        m.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        m.name = try c.decodeIfPresent(String.self, forKey: .name) ?? m.name
        m.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        m.output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        m.points = (try c.decodeIfPresent([[Double]].self, forKey: .points) ?? []).filter { $0.count >= 2 }
        m.invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        self = m
    }
}

struct OutputMap: Codable, Equatable {
    var enabled = false
    /// 並び順に上へ重ねる（後ろのものが手前）
    var slices: [OutputSlice] = []
    var masks: [OutputMask] = []
    /// 端をなじませるときのガンマ
    var blendGamma = 2.2
    /// "0"…"2" → 下敷きの写真のパス（合わせる画面だけ。出力には出さない）
    var backdrops: [String: String] = [:]
    var backdropOpacity = 0.5

    var active: Bool { enabled && slices.contains { $0.enabled } }

    /// 描けるスライスの上限
    static let maxSlices = 64

    /// よく使う並べ方：count 台を横（または縦）に、overlap の割合だけ重ねて並べる。separate なら別々の出力へ
    static func preset(count: Int, vertical: Bool = false, overlap: Double = 0, separate: Bool = false) -> [OutputSlice] {
        let n = max(count, 1)
        // 重ねた分も入れて、n 台で 1 になる 1 台の幅
        let w = 1 / (Double(n) - overlap * Double(n - 1))
        return (0..<n).map { i in
            var s = OutputSlice()
            s.name = vertical ? L("上から \(i + 1)") : L("左から \(i + 1)")
            let start = Double(i) * w * (1 - overlap)
            s.input = vertical ? [0, start, 1, w] : [start, 0, w, 1]
            // 映す所：別々の出力なら画面いっぱい、同じ出力なら並べて置く
            if separate {
                s.output = min(i, OutputController.maxOutputs - 1)
            } else {
                let a = Double(i) / Double(n), b = Double(i + 1) / Double(n)
                s.corners = vertical ? [[0, a], [1, a], [1, b], [0, b]] : [[a, 0], [b, 0], [b, 1], [a, 1]]
            }
            // 重ねた所をなじませる（隣と重なる側だけ。重ねた幅 ＝ 1 台の幅 × overlap）
            let ff = min(max(overlap, 0), 0.5)
            if vertical {
                s.feather = [0, 0, i > 0 ? ff : 0, i < n - 1 ? ff : 0]
            } else {
                s.feather = [i > 0 ? ff : 0, i < n - 1 ? ff : 0, 0, 0]
            }
            return s
        }
    }

    // MARK: マッピングだけのファイル（.halomap）

    static let fileExtension = "halomap"

    /// マッピングだけを JSON で書き出す
    func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// .halomap を読む
    static func read(from url: URL) throws -> OutputMap {
        try JSONDecoder().decode(OutputMap.self, from: Data(contentsOf: url))
    }
}

extension OutputMap {
    private enum CodingKeys: String, CodingKey { case enabled, slices, masks, blendGamma, backdrops, backdropOpacity }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var m = OutputMap()
        m.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        m.slices = try c.decodeIfPresent([OutputSlice].self, forKey: .slices) ?? []
        m.masks = try c.decodeIfPresent([OutputMask].self, forKey: .masks) ?? []
        m.blendGamma = try c.decodeIfPresent(Double.self, forKey: .blendGamma) ?? 2.2
        m.backdrops = try c.decodeIfPresent([String: String].self, forKey: .backdrops) ?? [:]
        m.backdropOpacity = try c.decodeIfPresent(Double.self, forKey: .backdropOpacity) ?? 0.5
        self = m
    }
}

/// 合わせる窓で選んでいるもの。実際の出力に輪郭・点・メッシュの線を出す（保存しない）
struct MapGuide: Equatable {
    enum Target: Equatable {
        case slice(UUID)
        case mask(UUID)
    }
    /// どの点を見せるか（スライスのとき）
    enum Mode: Equatable {
        case corners, mesh, crop
    }
    var target: Target
    var mode = Mode.corners
    /// 選んだ点の番号（大きく描く）
    var selected: Set<Int> = []
}

// MARK: - 描く

private let sliceShaderSource = """
#include <metal_stdlib>
using namespace metal;
struct SV { float4 pos; float2 uv; };
struct VO { float4 pos [[position]]; float2 uv; };
vertex VO os_v(uint vid [[vertex_id]], const device SV* vs [[buffer(0)]]) {
    VO o; o.pos = vs[vid].pos; o.uv = vs[vid].uv; return o;
}
struct SliceU {
    float4 feather;
    float4 m0;      // 取る所：元の絵の uv.x = m0.x * u + m0.y * v + m0.z
    float4 m1;      //          uv.y = m1.x * u + m1.y * v + m1.z
    float4 color;   // 明るさ, コントラスト, 不透明度, 1 / ガンマ
    float4 gain;    // 赤, 緑, 青, master
    int4 info;      // 番号, テストパターン, 切り抜きの点の数, 切り抜きの反転
};

static float3 sliceColor(float i) {
    float3 k = abs(fract(float3(i * 0.13 + 0.05) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return saturate(k - 1.0);
}
// 多角形の中か（偶奇。へこんだ形でもよい）
static bool insidePoly(float2 p, constant float2* pts, int n) {
    bool c = false;
    for (int i = 0, j = n - 1; i < n; j = i++) {
        float2 a = pts[i], b = pts[j];
        if ((a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) c = !c;
    }
    return c;
}
fragment float4 os_f(VO in [[stage_in]], constant SliceU& u [[buffer(0)]], constant float2* crop [[buffer(1)]],
                     texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 l = clamp(in.uv, 0.0, 1.0);
    // 切り抜き
    if (u.info.z >= 3) {
        bool ins = insidePoly(l, crop, u.info.z);
        if (ins == (u.info.w != 0)) discard_fragment();
    }
    // 端をなじませる（隣と重なる所で、足して元の明るさになるように、光の量で混ぜる）
    float4 f = u.feather;
    float w = u.color.z;
    if (f.x > 0.0) w *= smoothstep(0.0, 1.0, l.x / f.x);
    if (f.y > 0.0) w *= smoothstep(0.0, 1.0, (1.0 - l.x) / f.y);
    if (f.z > 0.0) w *= smoothstep(0.0, 1.0, l.y / f.z);
    if (f.w > 0.0) w *= smoothstep(0.0, 1.0, (1.0 - l.y) / f.w);
    float3 c;
    if (u.info.y != 0) {
        // テストパターン：スライスごとの色の格子と、ふち
        float2 g = abs(fract(l * 8.0) - 0.5);
        float line = step(0.46, max(g.x, g.y));
        float edge = step(min(min(l.x, 1.0 - l.x), min(l.y, 1.0 - l.y)), 0.01);
        c = mix(sliceColor(float(u.info.x)) * 0.55, float3(1.0), max(line, edge));
    } else {
        float2 suv = float2(dot(u.m0.xyz, float3(l, 1.0)), dot(u.m1.xyz, float3(l, 1.0)));
        if (any(suv < -0.0001) || any(suv > 1.0001)) {
            c = 0.0;   // 元の絵の外は黒
        } else {
            c = tex.sample(s, suv).rgb;
            // 色：明るさ・コントラスト・赤緑青
            c = (c - 0.5) * (1.0 + u.color.y) + 0.5 + u.color.x;
            c = saturate(c) * u.gain.rgb;
        }
    }
    // 重ね方：上のスライスが下を覆う（黒の上なら、光の量が w 倍）
    float g = pow(max(w, 0.0), u.color.w);
    return float4(max(c, 0.0) * g * u.gain.w, g);
}

// マスク：画面全体に描いて、塗らない所を捨てる
struct MV { float4 pos [[position]]; float2 uv; };
vertex MV om_v(uint vid [[vertex_id]]) {
    float2 c = float2(float(vid & 1), float(vid >> 1));
    MV o; o.pos = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0); o.uv = c; return o;
}
fragment float4 om_f(MV in [[stage_in]], constant int2& info [[buffer(0)]], constant float2* pts [[buffer(1)]]) {
    bool ins = insidePoly(in.uv, pts, info.x);
    if (ins == (info.y != 0)) discard_fragment();
    return float4(0.0, 0.0, 0.0, 1.0);
}

// ガイド：色つきの三角形（線・点）
struct GV { float4 pos; float4 color; };
struct GO { float4 pos [[position]]; float4 color; };
vertex GO og_v(uint vid [[vertex_id]], const device GV* vs [[buffer(0)]]) {
    GO o; o.pos = vs[vid].pos; o.color = vs[vid].color; return o;
}
fragment float4 og_f(GO in [[stage_in]]) { return in.color; }
"""

private struct SliceVertex {
    var pos: SIMD4<Float>
    var uv: SIMD2<Float>
}
private struct SliceUniform {
    var feather: SIMD4<Float>
    var m0: SIMD4<Float>
    var m1: SIMD4<Float>
    var color: SIMD4<Float>
    var gain: SIMD4<Float>
    var info: SIMD4<Int32>
}
private struct GuideVertex {
    var pos: SIMD4<Float>
    var color: SIMD4<Float>
}

final class SliceRenderer {
    static let shared = SliceRenderer()
    let pipe: MTLRenderPipelineState
    private let maskPipe: MTLRenderPipelineState
    private let guidePipe: MTLRenderPipelineState

    /// スライスの網（頂点）。形（四隅・メッシュ）が変わったときだけ作り直す
    private struct Shape: Equatable {
        var corners: [[Double]]
        var mesh: SliceMesh?
    }
    private var meshCache: [UUID: (shape: Shape, buffer: MTLBuffer, count: Int)] = [:]
    private let lock = NSLock()

    private init() {
        let dev = MetalContext.shared.device
        let lib = try! dev.makeLibrary(source: sliceShaderSource, options: nil)
        func make(_ v: String, _ f: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            let a = d.colorAttachments[0]!
            a.pixelFormat = .bgra8Unorm
            // 上に重ねる：rgb = 上 + 下 × (1 − 上の a)
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try! dev.makeRenderPipelineState(descriptor: d)
        }
        pipe = make("os_v", "os_f")
        maskPipe = make("om_v", "om_f")
        guidePipe = make("og_v", "og_f")
    }

    /// 網のマスの割り方：メッシュなしは 1 マス（射影は頂点の w で正しく出る）。メッシュはマスごとに 8×8
    private static let meshSubdiv = 8

    /// スライスの網を作る（クリップ座標。w を残す）
    private static func buildVertices(_ s: OutputSlice) -> [SliceVertex] {
        let h = s.homography
        let mesh = s.mesh.flatMap { $0.isValid ? $0 : nil }
        let nx = mesh.map { $0.cols * meshSubdiv } ?? 1, ny = mesh.map { $0.rows * meshSubdiv } ?? 1
        var grid: [SliceVertex] = []
        grid.reserveCapacity((nx + 1) * (ny + 1))
        for j in 0...ny {
            for i in 0...nx {
                let u = Double(i) / Double(nx), v = Double(j) / Double(ny)
                let p = mesh?.position(u: u, v: v) ?? SIMD2(u, v)
                let q = h * SIMD3(Float(p.x), Float(p.y), 1)
                grid.append(SliceVertex(pos: SIMD4(q.x * 2 - q.z, q.z - q.y * 2, 0, q.z), uv: SIMD2(Float(u), Float(v))))
            }
        }
        var out: [SliceVertex] = []
        out.reserveCapacity(nx * ny * 6)
        for j in 0..<ny {
            for i in 0..<nx {
                let a = grid[j * (nx + 1) + i], b = grid[j * (nx + 1) + i + 1]
                let c = grid[(j + 1) * (nx + 1) + i], d = grid[(j + 1) * (nx + 1) + i + 1]
                // 後ろ（w ≦ 0）にかかる三角形は捨てる
                if a.pos.w > 1e-6 && b.pos.w > 1e-6 && d.pos.w > 1e-6 { out += [a, b, d] }
                if a.pos.w > 1e-6 && d.pos.w > 1e-6 && c.pos.w > 1e-6 { out += [a, d, c] }
            }
        }
        return out
    }

    private func vertexBuffer(for s: OutputSlice) -> (MTLBuffer, Int)? {
        let shape = Shape(corners: s.corners, mesh: s.mesh)
        return lock.withLock {
            if let c = meshCache[s.id], c.shape == shape { return (c.buffer, c.count) }
            let v = Self.buildVertices(s)
            guard !v.isEmpty, let b = MetalContext.shared.device.makeBuffer(
                bytes: v, length: v.count * MemoryLayout<SliceVertex>.stride, options: .storageModeShared) else {
                meshCache[s.id] = nil
                return nil
            }
            meshCache[s.id] = (shape, b, v.count)
            return (b, v.count)
        }
    }

    /// 消えたスライスの網を捨てる
    private func prune(_ map: OutputMap) {
        lock.withLock {
            guard meshCache.count > map.slices.count else { return }
            let ids = Set(map.slices.map(\.id))
            meshCache = meshCache.filter { ids.contains($0.key) }
        }
    }

    /// 出力 output の画面（target）に、そこへ出すスライス・マスク・ガイドを描く。
    /// layers：元の絵がレイヤーのスライス用の絵（レイヤーの UUID → 絵。無ければ黒）
    func draw(_ map: OutputMap, output: Int, composite: MTLTexture?, layers: [UUID: MTLTexture] = [:],
              master: Float, testPattern: Bool, guide: MapGuide? = nil,
              into target: MTLTexture, cb: MTLCommandBuffer) {
        prune(map)
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        defer { enc.endEncoding() }

        // 1. スライス（並び順に上へ重ねる）
        let invGamma = Float(1 / min(max(map.blendGamma, 1), 3))
        var drawn = 0
        for (i, s) in map.slices.enumerated() where s.enabled && s.output == output && s.corners.count == 4 && s.input.count == 4 {
            if drawn >= OutputMap.maxSlices { break }
            drawn += 1
            let tex: MTLTexture?
            switch s.source {
            case .composition: tex = composite
            case .layer(let id): tex = layers[id]
            }
            // 元の絵が無い（レイヤーが無い・まだ絵が無い）スライスは黒（下のスライスは覆う）
            guard let (vb, count) = vertexBuffer(for: s) else { continue }
            let aspect = tex.map { Double($0.width) / Double(max($0.height, 1)) } ?? 16.0 / 9
            let o = s.sourceUV(u: 0, v: 0, aspect: aspect)
            let ux = s.sourceUV(u: 1, v: 0, aspect: aspect) - o, vy = s.sourceUV(u: 0, v: 1, aspect: aspect) - o
            let f = s.feather.count == 4 ? s.feather : [0, 0, 0, 0]
            let g = tex == nil ? [0, 0, 0] : (s.gain.count == 3 ? s.gain : [1, 1, 1])
            let crop = s.hasCrop ? Array(s.crop.prefix(OutputSlice.maxCropPoints)) : []
            var u = SliceUniform(
                feather: SIMD4(f.map { Float(min(max($0, 0), 1)) }),
                m0: SIMD4(Float(ux.x), Float(vy.x), Float(o.x), 0),
                m1: SIMD4(Float(ux.y), Float(vy.y), Float(o.y), 0),
                color: SIMD4(Float(min(max(s.brightness, -1), 1)), Float(min(max(s.contrast, -1), 1)),
                             Float(min(max(s.opacity, 0), 1)), invGamma),
                gain: SIMD4(Float(max(g[0], 0)), Float(max(g[1], 0)), Float(max(g[2], 0)), master),
                info: SIMD4(Int32(i), testPattern ? 1 : 0, Int32(crop.count), s.cropInvert ? 1 : 0))
            var pts = crop.map { SIMD2(Float($0[0]), Float($0[1])) }
            if pts.isEmpty { pts = [SIMD2(0, 0)] }
            enc.setRenderPipelineState(pipe)
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<SliceUniform>.stride, index: 0)
            pts.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            enc.setFragmentTexture(tex ?? MetalContext.shared.dummyTexture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        }

        // 2. マスク（その出力の形を黒く）
        for m in map.masks where m.enabled && m.output == output && m.isValid {
            var info = SIMD2<Int32>(Int32(min(m.points.count, OutputMask.maxPoints)), m.invert ? 1 : 0)
            let pts = m.points.prefix(OutputMask.maxPoints).map { SIMD2(Float($0[0]), Float($0[1])) }
            enc.setRenderPipelineState(maskPipe)
            enc.setFragmentBytes(&info, length: MemoryLayout<SIMD2<Int32>>.stride, index: 0)
            pts.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // 3. 合わせる画面のガイド
        if let guide {
            let v = Self.guideVertices(map, output: output, guide: guide, width: target.width, height: target.height)
            if !v.isEmpty, let b = MetalContext.shared.device.makeBuffer(
                bytes: v, length: v.count * MemoryLayout<GuideVertex>.stride, options: .storageModeShared) {
                enc.setRenderPipelineState(guidePipe)
                enc.setVertexBuffer(b, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: v.count)
            }
        }
    }

    // MARK: ガイド（輪郭は黄色・点・メッシュの線）

    private static func guideVertices(_ map: OutputMap, output: Int, guide: MapGuide, width: Int, height: Int) -> [GuideVertex] {
        let W = Double(max(width, 1)), H = Double(max(height, 1))
        var out: [GuideVertex] = []
        let yellow = SIMD4<Float>(1, 0.85, 0, 1)
        let faint = SIMD4<Float>(0.6, 0.5, 0, 0.6)
        let black = SIMD4<Float>(0, 0, 0, 1)
        func clip(_ p: SIMD2<Double>) -> SIMD4<Float> { SIMD4(Float(p.x / W * 2 - 1), Float(1 - p.y / H * 2), 0, 1) }
        func px(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(p.x * W, p.y * H) }
        // 線（太さ t ピクセル）
        func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ t: Double, _ c: SIMD4<Float>) {
            let pa = px(a), pb = px(b)
            let d = pb - pa, len = simd_length(d)
            guard len > 1e-6 else { return }
            let n = SIMD2(-d.y, d.x) / len * (t / 2)
            let q = [pa + n, pb + n, pb - n, pa - n].map(clip)
            out += [GuideVertex(pos: q[0], color: c), GuideVertex(pos: q[1], color: c), GuideVertex(pos: q[2], color: c),
                    GuideVertex(pos: q[0], color: c), GuideVertex(pos: q[2], color: c), GuideVertex(pos: q[3], color: c)]
        }
        func polyline(_ pts: [SIMD2<Double>], closed: Bool, _ t: Double, _ c: SIMD4<Float>) {
            guard pts.count >= 2 else { return }
            for k in 0..<(pts.count - 1) { line(pts[k], pts[k + 1], t, c) }
            if closed { line(pts[pts.count - 1], pts[0], t, c) }
        }
        // 点（四角。選んだ点は大きく）
        func dot(_ p: SIMD2<Double>, selected: Bool) {
            let r = selected ? 7.0 : 4.0
            let c = px(p)
            for (size, col) in [(r + 1.5, black), (r, yellow)] {
                let q = [c + SIMD2(-size, -size), c + SIMD2(size, -size), c + SIMD2(size, size), c + SIMD2(-size, size)].map(clip)
                out += [GuideVertex(pos: q[0], color: col), GuideVertex(pos: q[1], color: col), GuideVertex(pos: q[2], color: col),
                        GuideVertex(pos: q[0], color: col), GuideVertex(pos: q[2], color: col), GuideVertex(pos: q[3], color: col)]
            }
        }
        switch guide.target {
        case .mask(let id):
            guard let m = map.masks.first(where: { $0.id == id }), m.output == output else { return [] }
            let pts = m.points.map { SIMD2($0[0], $0[1]) }
            polyline(pts, closed: true, 2, yellow)
            for (k, p) in pts.enumerated() { dot(p, selected: guide.selected.contains(k)) }
        case .slice(let id):
            guard let s = map.slices.first(where: { $0.id == id }), s.output == output, s.corners.count == 4 else { return [] }
            let mesh = s.mesh.flatMap { $0.isValid ? $0 : nil }
            let steps = mesh.map { max($0.cols, $0.rows) * meshSubdiv } ?? 1
            // スライスの中の線を、出力の画面へ写した折れ線
            func mapped(_ uv: [(Double, Double)]) -> [SIMD2<Double>] { uv.compactMap { s.outputPoint(u: $0.0, v: $0.1) } }
            func edgeLine(from a: (Double, Double), to b: (Double, Double), n: Int) -> [SIMD2<Double>] {
                mapped((0...n).map { k in
                    let t = Double(k) / Double(n)
                    return (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
                })
            }
            // メッシュの線
            if let mesh {
                for i in 1..<mesh.cols {
                    let u = Double(i) / Double(mesh.cols)
                    polyline(edgeLine(from: (u, 0), to: (u, 1), n: mesh.rows * meshSubdiv), closed: false, 1, faint)
                }
                for j in 1..<mesh.rows {
                    let v = Double(j) / Double(mesh.rows)
                    polyline(edgeLine(from: (0, v), to: (1, v), n: mesh.cols * meshSubdiv), closed: false, 1, faint)
                }
            }
            // 輪郭
            let outline = edgeLine(from: (0, 0), to: (1, 0), n: steps) + edgeLine(from: (1, 0), to: (1, 1), n: steps).dropFirst()
                + edgeLine(from: (1, 1), to: (0, 1), n: steps).dropFirst() + edgeLine(from: (0, 1), to: (0, 0), n: steps).dropFirst()
            polyline(Array(outline), closed: true, 2, yellow)
            // 点
            switch guide.mode {
            case .corners:
                for (k, c) in s.corners.enumerated() where c.count >= 2 {
                    dot(SIMD2(c[0], c[1]), selected: guide.selected.contains(k))
                }
            case .mesh:
                if let mesh {
                    for j in 0...mesh.rows {
                        for i in 0...mesh.cols {
                            let p = mesh.point(col: i, row: j)
                            let h = s.homography * SIMD3(Float(p.x), Float(p.y), 1)
                            guard h.z > 1e-6 else { continue }
                            dot(SIMD2(Double(h.x / h.z), Double(h.y / h.z)), selected: guide.selected.contains(mesh.index(col: i, row: j)))
                        }
                    }
                }
            case .crop:
                let n = s.crop.count
                guard n >= 2 else { break }
                // 切り抜きの辺（スライスの中でまっすぐ → メッシュで曲がる）
                var poly: [SIMD2<Double>] = []
                for k in 0..<n {
                    let a = s.crop[k], b = s.crop[(k + 1) % n]
                    poly += edgeLine(from: (a[0], a[1]), to: (b[0], b[1]), n: mesh == nil ? 1 : 16).dropLast()
                }
                polyline(poly, closed: true, 2, yellow)
                for (k, c) in s.crop.enumerated() {
                    if let p = s.outputPoint(u: c[0], v: c[1]) { dot(p, selected: guide.selected.contains(k)) }
                }
            }
        }
        return out
    }
}

/// 元の絵がレイヤーのスライス用に、そのレイヤーだけを合成した絵を作る（描画スレッドだけが触る）
final class SliceLayerSources {
    /// レイヤーの番号 → 合成
    private var compositors: [Int: Compositor] = [:]
    var storageMode: MTLStorageMode = .private

    /// map の中でレイヤーを元にしているスライスの絵（UUID → 絵）。layerIndex で UUID から今の番号を引く
    func textures(for map: OutputMap, groups: [LayerGroup], layerIndex: (UUID) -> Int?,
                  width: Int, height: Int, cb: MTLCommandBuffer) -> [UUID: MTLTexture] {
        let ids = Set(map.slices.compactMap { $0.enabled ? $0.source.layerID : nil })
        var out: [UUID: MTLTexture] = [:]
        var used = Set<Int>()
        for id in ids {
            guard let r = layerIndex(id), let g = groups.first(where: { $0.key == r && !$0.isAdjustment }) else { continue }
            used.insert(r)
            let comp: Compositor
            if let c = compositors[r] { comp = c } else {
                comp = Compositor()
                comp.storageMode = storageMode
                compositors[r] = comp
            }
            // このレイヤーだけを、通常の重ね方で（コンポジションの変形は無し）
            var one = g
            one.blend = .normal
            one.draws = g.draws.map { d in
                LayerDraw(texture: d.texture, opacity: d.opacity, blend: .normal, transform: d.transform,
                          layerTransform: d.layerTransform, compTransform: ClipTransform(), holder: d.holder,
                          effects: d.effects, effectKey: d.effectKey, premul: d.premul)
            }
            if let t = comp.composite([one], effects: EffectStack(), width: width, height: height, cb: cb) {
                out[id] = t
            }
        }
        compositors = compositors.filter { used.contains($0.key) }
        return out
    }
}

/// 出力 n の見た目（実際に出しているのと同じ）
struct OutputPreview: NSViewRepresentable {
    let output: Int
    func makeNSView(context: Context) -> MetalLayerView { MetalLayerView(frame: .zero, kind: .output, output: output) }
    func updateNSView(_ v: MetalLayerView, context: Context) { v.setOutput(output) }
}
