import Metal
import QuartzCore
import simd

// 群れ（ボイド）のジェネレーター。魚 1 匹ずつの場所と速さを GPU の上に持ち、コマごとに動かして描く。
// 1 匹ずつは「まわりの魚に寄る・向きをそろえる・近すぎたら離れる」だけ。それに、群れが向かう先（ゆっくり回る点）、
// 見えない天敵（向かう先を少し遅れて追う。近いと逃げる）、渦（向かう先のまわりを回る）、ゆらぎを足す。
// 場所は画面の高さを 1 とした単位（横は 0〜幅/高さ、縦は 0 = 上、奥行きは -厚み/2〜+厚み/2）。
// 厚みが 0 なら平ら（奥行きは見せかけで、1 匹ずつ決まった遠さで小さく暗く）。厚みがあれば箱の中を 3D で泳ぎ、
// 回るカメラから遠近をつけて描く（こちらを向いた魚は短く見え、横腹が光を返す向きで光る）。

private let schoolShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct SchoolU {
    float4 a;     // 数, 横の長さ（幅/高さ）, 1 歩の秒, 群れの時刻
    float4 b;     // まとまる, そろえる, 間をあける, 見る広さ
    float4 c;     // 動き回る, 逃げる, ゆらぎ, いちばん速い速さ
    float4 d;     // 端（0 = 戻る, 1 = 抜ける）, 大きさ（高さに対して）, 形, きらめき
    float4 e;     // 奥行き, 出力の高さ（px）, 間をあける距離, 羽ばたきの時刻
    float4 goal;  // 向かう先 xy, 天敵 xy
    float4 color;
    float4 f;     // 厚み, 渦, 3D か, 0
    float4 cam0;  // 横の回転 cos, sin, 縦の回転 cos, sin
    float4 cam1;  // 画角で決まる距離, カメラの距離, 0, 0
    float4 goal2; // 向かう先 z, 天敵 z
};

struct Fish { float4 p; float4 v; };

kernel void school_step(device const Fish* src [[buffer(0)]], device Fish* dst [[buffer(1)]],
                        device const float4* traits [[buffer(2)]], constant SchoolU& u [[buffer(3)]],
                        uint i [[thread_position_in_grid]], uint li [[thread_position_in_threadgroup]]) {
    int n = int(u.a.x);
    bool live = int(i) < n;
    Fish me = live ? src[i] : Fish{ float4(0.0), float4(0.0) };
    float3 p = me.p.xyz, v = me.v.xyz;
    float A = u.a.y, dt = u.a.z, T = u.a.w;
    float D = u.f.x;
    bool flat = D <= 0.0;
    bool wrap = u.d.x > 0.5;
    float R = u.b.w, R2 = R * R, Rs = u.e.z, Rs2 = Rs * Rs;
    float3 sumV = 0.0, sumD = 0.0, sep = 0.0;
    float cnt = 0.0;
    threadgroup float4 tp[256];
    threadgroup float4 tv[256];
    float sp0 = length(v);
    float3 fw = sp0 > 1e-6 ? v / sp0 : float3(1, 0, 0);
    for (int base = 0; base < n; base += 256) {
        int j = base + int(li);
        tp[li] = j < n ? src[j].p : float4(1e5, 1e5, 1e5, 0);
        tv[li] = j < n ? src[j].v : float4(0.0);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        int m = min(256, n - base);
        for (int k = 0; k < m; k++) {
            float3 d = tp[k].xyz - p;
            if (wrap) { d.x -= A * round(d.x / A); d.y -= round(d.y); }
            float d2 = dot(d, d);
            if (d2 < R2 && d2 > 1e-12) {
                // 真後ろは見えにくい
                float w = dot(fw, d) * rsqrt(d2) < -0.6 ? 0.25 : 1.0;
                sumV += tv[k].xyz * w; sumD += d * w; cnt += w;
                if (d2 < Rs2) {
                    float dl = sqrt(d2);
                    sep -= d / dl * (1.0 - dl / Rs);
                }
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (!live) return;

    float4 tr = traits[i];
    float maxS = u.c.w * (0.85 + 0.3 * tr.y);
    float3 acc = 0.0;
    if (cnt > 0.0) {
        acc += (sumV / cnt - v) * (u.b.y * 3.0);
        acc += (sumD / cnt) * (u.b.x * 9.0 * (1.0 - 0.7 * u.f.y));
    }
    acc += sep * (u.b.z * 14.0 * maxS);
    float3 goal = float3(u.goal.xy, u.goal2.x), pred = float3(u.goal.zw, u.goal2.y);
    // 向かう先
    float3 g = goal - p;
    if (wrap) { g.x -= A * round(g.x / A); g.y -= round(g.y); }
    float gl = length(g);
    // 渦を巻くときは真ん中へは寄らない（輪になって回る）
    if (gl > 1e-5) acc += (g / gl * maxS - v) * (u.c.x * 0.9 * (1.0 - u.f.y));
    // 渦：向かう先のまわりを回る（3D では縦の軸のまわり、平らなら画面の上で）
    float mill = u.f.y;
    if (mill > 0.0) {
        float3 r = -g;
        if (flat) r.z = 0.0; else r.y = 0.0;
        float rl = length(r);
        if (rl > 1e-4) {
            float3 tang = flat ? float3(-r.y, r.x, 0.0) / rl : float3(-r.z, 0.0, r.x) / rl;
            // 竜巻：1 匹ずつ決まった高さを回り、上ほど輪が大きい（平らなら、輪の大きさがばらつく）
            float hgt = tr.x - 0.5;
            float ring = flat ? 0.1 + 0.16 * tr.x : 0.06 + 0.26 * (0.5 - hgt);
            acc += (tang * maxS - v) * (mill * 2.0) - r / rl * (rl - ring) * (mill * 14.0 * maxS);
            if (!flat) acc.y += ((goal.y + hgt * 0.7) - p.y) * (mill * 5.0 * maxS);
        }
    }
    // 天敵から逃げる（逃げるときは速くなる）
    float3 q = p - pred;
    if (wrap) { q.x -= A * round(q.x / A); q.y -= round(q.y); }
    float ql = length(q), Rp = 0.2;
    float fear = 0.0;
    if (u.c.y > 0.0 && ql < Rp && ql > 1e-5) {
        fear = u.c.y * (1.0 - ql / Rp);
        acc += q / ql * fear * 18.0 * maxS;
    }
    // ゆらぎ（1 匹ずつ別のゆっくりした揺れ）
    float ph = tr.z * 6.2831853, f1 = 0.6 + tr.w * 0.9, f2 = 0.5 + tr.y * 1.1;
    acc += float3(sin(T * f1 * 1.7 + ph) + 0.5 * sin(T * f2 * 3.1 + ph * 2.0),
                  cos(T * f2 * 1.9 + ph * 1.3) + 0.5 * cos(T * f1 * 2.7 + ph),
                  sin(T * f2 * 1.3 + ph * 0.7) + 0.5 * cos(T * f1 * 2.3 + ph * 1.7)) * (u.c.z * 2.5 * maxS);
    // 画面の端：戻ってくる（奥行きはいつも戻る）
    float turn = 6.0 * maxS;
    if (!wrap) {
        float mg = 0.12;
        acc.x += turn * (smoothstep(mg, 0.0, p.x) - smoothstep(A - mg, A, p.x));
        acc.y += turn * (smoothstep(mg, 0.0, p.y) - smoothstep(1.0 - mg, 1.0, p.y));
    }
    if (flat) { acc.z = 0.0; v.z = 0.0; }
    else {
        float h = D * 0.5, mz = min(0.12, D * 0.35);
        acc.z += turn * (smoothstep(-h + mz, -h, p.z) - smoothstep(h - mz, h, p.z));
    }
    v += acc * dt;
    float top = maxS * (1.0 + 0.8 * fear), low = maxS * 0.45;
    float s = length(v);
    if (s > top) v *= top / s;
    else if (s < low) v = (s > 1e-6 ? v / s : float3(1, 0, 0)) * low;
    p += v * dt;
    if (wrap) { p.x -= A * floor(p.x / A); p.y -= floor(p.y); }
    else { p.xy = clamp(p.xy, float2(-0.05), float2(A + 0.05, 1.05)); }
    p.z = flat ? 0.0 : clamp(p.z, -D * 0.5 - 0.05, D * 0.5 + 0.05);
    dst[i] = Fish{ float4(p, 0.0), float4(v, 0.0) };
}

struct FishOut {
    float4 pos [[position]];
    float2 q;       // 魚の中の場所（-1〜1、前が +x）
    float2 ext;     // 半分の長さ・半分の幅（px）
    float bright;
    float flap;
};

// カメラから見た場所（カメラは +z の向きを見る）
static float3 toCam(float3 w, constant SchoolU& u) {
    float cy = u.cam0.x, sy = u.cam0.y, cp = u.cam0.z, sp = u.cam0.w;
    float3 r = float3(cy * w.x + sy * w.z, w.y, -sy * w.x + cy * w.z);
    return float3(r.x, cp * r.y - sp * r.z, sp * r.y + cp * r.z);
}

vertex FishOut school_v(uint vid [[vertex_id]], uint iid [[instance_id]],
                        device const Fish* st [[buffer(0)]], device const float4* traits [[buffer(1)]],
                        constant SchoolU& u [[buffer(2)]]) {
    Fish s = st[iid];
    float4 tr = traits[iid];
    float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 c = corners[vid];
    float A = u.a.y, H = u.e.y;
    float3 v3 = s.v.xyz;
    float spd = length(v3);
    float3 f3 = spd > 1e-6 ? v3 / spd : float3(1, 0, 0);
    bool is3D = u.f.z > 0.5;
    int shape = int(u.d.z + 0.5);
    float FishOutDepth = 0.5;
    // 半分の長さ・幅（高さに対して。遠近をつける前）
    float hl = u.d.y * 0.5 * (0.9 + 0.2 * tr.w), hw;
    if (shape == 0) hw = hl * 0.36;
    else if (shape == 1) { hl *= 0.55; hw = hl * 1.9; }
    else if (shape == 2) { hl *= 0.5; hw = hl; }
    else { hl *= 0.6 + 1.4 * clamp(spd / max(u.c.w, 1e-5), 0.0, 2.0); hw = u.d.y * 0.06; }

    float2 S, f2;
    float b = 1.0;
    FishOut o;
    if (!is3D) {
        float depth = tr.x * u.e.x;
        float k = mix(1.0, 0.38, depth);
        hl *= k; hw *= k;
        S = s.p.xy;
        f2 = length(v3.xy) > 1e-6 ? normalize(v3.xy) : float2(1, 0);
        // きらめき：向きで明るさが変わる（群れがそろって向きを変えると、まとめて光る）
        float ang = atan2(f2.y, f2.x);
        float sh = pow(0.5 + 0.5 * cos(2.0 * ang + 0.7), 5.0);
        b = mix(1.0, 0.5 + 0.9 * sh, u.d.w) * mix(1.0, 0.45, depth);
    } else {
        float3 w = s.p.xyz - float3(A * 0.5, 0.5, 0.0);
        float3 pc = toCam(w, u);
        float zc = u.cam1.y + pc.z;
        if (zc < 0.03) {
            // カメラの後ろ：描かない
            o.pos = float4(0, 0, -2, 1);
            o.q = 0; o.ext = 1; o.bright = 0; o.flap = 0;
            return o;
        }
        float k = u.cam1.x / zc;
        S = float2(A * 0.5, 0.5) + pc.xy * k;
        // 前の向きを画面に映す（こちらを向いた魚は短く見える）
        float3 fc = toCam(f3, u);
        float3 pf = pc + fc * hl;
        float2 Sf = float2(A * 0.5, 0.5) + pf.xy * (u.cam1.x / max(u.cam1.y + pf.z, 0.03));
        float2 fs = Sf - S;
        float fl = length(fs);
        f2 = fl > 1e-7 ? fs / fl : float2(1, 0);
        hw *= k;
        hl = max(fl, hw * 0.9);
        // 横腹が上からの光をカメラへ返す向きで光る
        float3 up = float3(0, -1, 0);
        float3 side = cross(f3, up);
        side = length(side) > 1e-4 ? normalize(side) : float3(1, 0, 0);
        float3 nc = toCam(side, u), lc = toCam(float3(0.25, 1.0, 0.15), u);
        float3 view = -normalize(pc + float3(0, 0, u.cam1.y));
        float sh = pow(abs(dot(reflect(normalize(lc), nc), view)), 6.0);
        b = mix(1.0, 0.65 + 1.1 * sh, u.d.w);
        // 遠くを暗く
        float Rw = 0.5 * length(float3(A, 1.0, u.f.x));
        float far = clamp((zc - (u.cam1.y - Rw)) / (2.0 * Rw), 0.0, 1.0);
        b *= mix(1.0, 0.35, u.e.x * far);
        FishOutDepth = clamp(zc / (u.cam1.y + 4.0), 0.0, 1.0);
    }
    b *= 0.9 + 0.2 * tr.y;
    float2 side2 = float2(-f2.y, f2.x);
    // ふちをなめらかにするため 1.5px 広げる
    float2 extPx = float2(hl, hw) * H;
    float2 grow = (extPx + 1.5) / max(extPx, 1e-4);
    float2 P = S + f2 * (c.x * hl * grow.x) + side2 * (c.y * hw * grow.y);
    o.pos = float4(P.x / A * 2.0 - 1.0, 1.0 - P.y * 2.0, FishOutDepth, 1);
    o.q = c * grow;
    o.ext = extPx;
    o.bright = b;
    o.flap = sin(u.e.w * (9.0 + 4.0 * tr.w) + tr.z * 6.2831853);
    return o;
}

static float segDist(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

fragment float4 school_f(FishOut in [[stage_in]], constant SchoolU& u [[buffer(0)]]) {
    int shape = int(u.d.z + 0.5);
    // px の単位で形を測る
    float2 p = in.q * in.ext;
    float L = in.ext.x, W = in.ext.y;
    float d;
    if (shape == 0) {
        // 魚：細長い体（前が丸く後ろが細い）と、二つに分かれた尾びれ
        float2 bp = p - float2(L * 0.12, 0.0);
        float taper = bp.x < 0.0 ? mix(1.0, 0.45, clamp(-bp.x / (L * 0.62), 0.0, 1.0)) : 1.0;
        float2 r = float2(L * 0.68, W * 0.78 * taper);
        float body = (length(bp / r) - 1.0) * min(r.x, r.y);
        float tx = -(p.x + L * 0.5) / (L * 0.5);   // 尾の付け根 0 → 先 1
        float tail = max(abs(p.y) - W * (0.12 + 0.85 * clamp(tx, 0.0, 1.0)), max(-tx, tx - 1.0) * L * 0.5);
        tail = max(tail, -(abs(p.y) - W * 0.9 * pow(clamp(tx, 0.0, 1.0), 2.5) + W * 0.1));
        d = min(body, tail);
    } else if (shape == 1) {
        // 鳥：羽ばたく「く」の字
        float fl = in.flap;
        float2 tip = float2(-L * (0.2 + 0.35 * fl), W * (0.75 + 0.2 * fl));
        float2 nose = float2(L * 0.7, 0.0);
        float2 q = float2(p.x, abs(p.y));
        float th = max(W * 0.11, 0.6);
        d = segDist(q, nose, tip) - th * mix(1.4, 0.5, clamp(q.y / W, 0.0, 1.0));
    } else if (shape == 2) {
        d = length(p) - min(L, W) * 0.8;
    } else {
        d = segDist(p, float2(-L * 0.9, 0.0), float2(L * 0.9, 0.0)) - W * 0.8;
    }
    // ごく小さいときも消えないように、ふちを 1px でぼかす（3D では奥の魚を隠すので、薄いふちは描かない）
    float a = clamp(0.5 - d, 0.0, 1.0);
    if (a <= (u.f.z > 0.5 ? 0.3 : 0.0)) discard_fragment();
    float3 col = u.color.rgb * min(in.bright, 1.6);
    return float4(col * a, a);
}
"""

/// 群れ 1 つ分（エフェクトごと）の、魚の場所と速さ
final class SchoolSim {
    static let maxCount = 4000
    /// 2 つを交互に（1 匹に float4 が 2 つ：場所 xyz・速さ xyz）
    let state: [MTLBuffer]
    /// 1 匹ずつ決まった値：遠さ（平らのとき）・乱数 3 つ
    let traits: MTLBuffer
    var cur = 0
    var last = -1.0
    /// 群れの時刻（速さをかけて進む）
    var time = 0.0
    var flapTime = 0.0
    var lastUsed = CACurrentMediaTime()
    /// 3D で前後を決めるための奥行きの絵
    var depth: MTLTexture?

    init?(device: MTLDevice, aspect: Double) {
        let n = Self.maxCount
        var rng = SplitMix(seed: 0x5EED_F15)
        var st = [SIMD4<Float>](), tr = [SIMD4<Float>]()
        st.reserveCapacity(n * 2); tr.reserveCapacity(n)
        // いくつかの小さな群れから始める（すぐ群れらしく見えるように）
        let groups = (0..<5).map { _ in
            (c: SIMD2(Float(rng.next() * aspect * 0.7 + aspect * 0.15), Float(rng.next() * 0.6 + 0.2)),
             a: Float(rng.next() * 2 * .pi))
        }
        for i in 0..<n {
            let g = groups[i % groups.count]
            let r = Float(sqrt(rng.next())) * 0.12, t = Float(rng.next() * 2 * .pi)
            let p = g.c + SIMD2(cos(t), sin(t)) * r
            let a = g.a + Float(rng.next() - 0.5) * 0.8
            // 奥行きは -0.5〜0.5 の割合で持っておき、厚みに合わせて端で戻る
            let z = Float(rng.next() - 0.5) * 0.3
            st.append(SIMD4(p.x, p.y, z, 0))
            st.append(SIMD4(cos(a) * 0.15, sin(a) * 0.15, 0, 0))
            tr.append(SIMD4(Float(rng.next()), Float(rng.next()), Float(rng.next()), Float(rng.next())))
        }
        guard let a = device.makeBuffer(bytes: st, length: n * 32, options: .storageModeShared),
              let b = device.makeBuffer(bytes: st, length: n * 32, options: .storageModeShared),
              let t = device.makeBuffer(bytes: tr, length: n * 16, options: .storageModeShared) else { return nil }
        state = [a, b]
        traits = t
    }

    /// 今の場所と速さ（テスト用。GPU の処理が終わってから読む）
    func fish(_ n: Int) -> [(p: SIMD3<Float>, v: SIMD3<Float>)] {
        let p = state[cur].contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxCount * 2)
        return (0..<min(n, Self.maxCount)).map { i in
            let a = p[i * 2], b = p[i * 2 + 1]
            return (SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z))
        }
    }
}

/// 決まった順に乱数を出す（群れの始まりを毎回同じにする）
struct SplitMix {
    private var s: UInt64
    init(seed: UInt64) { s = seed }
    mutating func next() -> Double {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

struct SchoolUniforms {
    var a: SIMD4<Float>, b: SIMD4<Float>, c: SIMD4<Float>, d: SIMD4<Float>, e: SIMD4<Float>
    var goal: SIMD4<Float>, color: SIMD4<Float>
    var f: SIMD4<Float> = .zero, cam0: SIMD4<Float> = .zero, cam1: SIMD4<Float> = .zero, goal2: SIMD4<Float> = .zero
}

/// 群れを動かして描く
final class SchoolRenderer {
    static let shared = SchoolRenderer()
    let step: MTLComputePipelineState
    let draw: MTLRenderPipelineState
    let depthOn: MTLDepthStencilState
    let depthOff: MTLDepthStencilState

    private init() {
        let device = MetalContext.shared.device
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: schoolShaderSource, options: nil) } catch {
            fatalError("群れのシェーダーを作れません: \(error)")
        }
        step = try! device.makeComputePipelineState(function: lib.makeFunction(name: "school_step")!)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "school_v")
        d.fragmentFunction = lib.makeFunction(name: "school_f")
        d.depthAttachmentPixelFormat = .depth32Float
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = .bgra8Unorm
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one
        ca.sourceAlphaBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        draw = try! device.makeRenderPipelineState(descriptor: d)
        let on = MTLDepthStencilDescriptor()
        on.depthCompareFunction = .less
        on.isDepthWriteEnabled = true
        depthOn = device.makeDepthStencilState(descriptor: on)!
        let off = MTLDepthStencilDescriptor()
        off.depthCompareFunction = .always
        off.isDepthWriteEnabled = false
        depthOff = device.makeDepthStencilState(descriptor: off)!
    }

    /// 群れが向かう先（ゆっくり回る。3D では奥行きも行き来する）
    static func goal(_ t: Double, aspect A: Double, thickness D: Double) -> SIMD3<Double> {
        SIMD3(A * (0.5 + 0.3 * sin(0.23 * t + 0.4) + 0.08 * sin(0.61 * t + 2.0)),
              0.5 + 0.26 * sin(0.31 * t + 1.7) + 0.08 * sin(0.83 * t),
              D * (0.3 * sin(0.19 * t + 0.9) + 0.08 * sin(0.53 * t + 2.4)))
    }

    /// 群れを dt 秒動かして（大きく飛んだら何歩かに分けて）、dst に描く
    func render(_ e: Effect, sim: SchoolSim, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack,
                cb: MTLCommandBuffer) {
        func v(_ j: Int) -> Double { e.value(j, at: now, beat: stack.beat, origin: stack.origin) }
        let A = Double(dst.width) / Double(max(dst.height, 1))
        let n = Int(min(max(v(0).rounded(), 1), Double(SchoolSim.maxCount)))
        let speed = max(v(3), 0)
        let sizeH = v(1) / 1080
        let percept = max(v(7), 0.005)
        let D = max(v(14), 0) * 1.2
        let is3D = D > 0.001
        var u = SchoolUniforms(
            a: SIMD4(Float(n), Float(A), 0, 0),
            b: SIMD4(Float(v(4)), Float(v(5)), Float(v(6)), Float(percept)),
            c: SIMD4(Float(v(8)), Float(v(9)), Float(v(10)), Float(0.2 * speed)),
            d: SIMD4(Float(v(13).rounded()), Float(sizeH), Float(v(2).rounded()), Float(v(11))),
            e: SIMD4(Float(v(12)), Float(dst.height), Float(max(sizeH * 1.1, percept * 0.25)), 0),
            goal: .zero, color: e.color.simd)
        u.f = SIMD4(Float(is3D ? D : 0), Float(v(15)), is3D ? 1 : 0, 0)

        if dt > 0, speed > 0 {
            let steps = max(1, Int((dt / (1.0 / 60)).rounded(.up)))
            let h = dt / Double(steps)
            if let enc = cb.makeComputeCommandEncoder() {
                enc.setComputePipelineState(step)
                for _ in 0..<steps {
                    sim.time += h * speed
                    let T = sim.time
                    // 渦を巻くときは、真ん中のあたりで回る
                    let mid = SIMD3(A * 0.5, 0.5, 0), keep = 1 - 0.85 * min(max(v(15), 0), 1)
                    let g = mid + (Self.goal(T, aspect: A, thickness: D) - mid) * keep
                    // 天敵：向かう先を少し遅れて追いながら、群れの中を出入りする
                    let pr = mid + (Self.goal(T - 3, aspect: A, thickness: D) - mid) * keep
                        + SIMD3(0.24 * cos(0.9 * T), 0.2 * sin(1.13 * T + 0.5), D * 0.3 * sin(0.7 * T))
                    u.a.z = Float(h)
                    u.a.w = Float(T.truncatingRemainder(dividingBy: 10000))
                    u.goal = SIMD4(Float(g.x), Float(g.y), Float(pr.x), Float(pr.y))
                    u.goal2 = SIMD4(Float(g.z), Float(pr.z), 0, 0)
                    enc.setBuffer(sim.state[sim.cur], offset: 0, index: 0)
                    enc.setBuffer(sim.state[1 - sim.cur], offset: 0, index: 1)
                    enc.setBuffer(sim.traits, offset: 0, index: 2)
                    enc.setBytes(&u, length: MemoryLayout<SchoolUniforms>.stride, index: 3)
                    let groups = (n + 255) / 256
                    enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                                             threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                    sim.cur = 1 - sim.cur
                }
                enc.endEncoding()
            }
        }
        if dt > 0 { sim.flapTime = (sim.flapTime + dt * max(speed, 0.3)).truncatingRemainder(dividingBy: 10000) }
        u.e.w = Float(sim.flapTime)

        // カメラ：箱の真ん中を見ながら、横に回る（回る速さ × 経過秒 + 向き）。視点の高さで上から・下から見る
        let el = max(now - stack.origin, 0)
        let yaw = (v(17) + v(16) * el).truncatingRemainder(dividingBy: 360) * .pi / 180
        let pitch = v(18) * .pi / 180
        let fov = min(max(v(20), 10), 150) * .pi / 180
        let dist0 = 0.5 / tan(fov / 2)
        u.cam0 = SIMD4(Float(cos(yaw)), Float(sin(yaw)), Float(cos(pitch)), Float(sin(pitch)))
        u.cam1 = SIMD4(Float(dist0), Float(dist0 * max(v(19), 0.05)), 0, 0)

        if sim.depth?.width != dst.width || sim.depth?.height != dst.height {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: dst.width,
                                                              height: dst.height, mipmapped: false)
            td.usage = [.renderTarget]
            td.storageMode = .private
            sim.depth = MetalContext.shared.device.makeTexture(descriptor: td)
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = sim.depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1
        rpd.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(draw)
        enc.setDepthStencilState(is3D ? depthOn : depthOff)
        enc.setVertexBuffer(sim.state[sim.cur], offset: 0, index: 0)
        enc.setVertexBuffer(sim.traits, offset: 0, index: 1)
        enc.setVertexBytes(&u, length: MemoryLayout<SchoolUniforms>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<SchoolUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
        enc.endEncoding()
    }
}
