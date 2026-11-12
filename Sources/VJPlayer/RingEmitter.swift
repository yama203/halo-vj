import Metal
import simd

// ジェネレーター「輪から湧く粒」（ringEmitter）。
// 粒は円の縁で生まれ、しばらく縁にとどまってから、カールノイズ（渦を巻く流れ）に乗って外へ流れ出し、寿命で消える。
// 消えた粒はすぐ縁のどこかで生まれ直すので、数は一定のまま、ずっと出続ける。
// 前のコマを覚えて動かす（状態は EffectProcessor の LifeStore が持つ）。描くのは LifeRenderer.drawDots（光る点の加算）。
// 座標は高さを 1 とする（横は 0〜縦横比）。粒どうしの力は無いので、1 粒 1 スレッドで、その場で書き換える。

private let ringShaderSource = """
#include <metal_stdlib>
using namespace metal;

static float rhash(uint x) {
    x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16;
    return float(x) / 4294967295.0;
}
static float3 rgrad(int3 c) {
    // z は 64 で一周する（時間の向き。長く動かしても数が大きくならない）
    uint h = uint(c.x) * 73856093u ^ uint(c.y) * 19349663u ^ uint(c.z & 63) * 83492791u;
    float a = rhash(h) * 6.2831853, z = rhash(h ^ 0x9e3779b9u) * 2.0 - 1.0;
    float s = sqrt(max(1.0 - z * z, 0.0));
    return float3(s * cos(a), s * sin(a), z);
}
// 3D の勾配ノイズの値と傾き（x = 値, yzw = 傾き）
static float4 rnoised(float3 x) {
    float3 fi = floor(x);
    int3 i = int3(fi);
    float3 f = x - fi;
    float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float3 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float3 ga = rgrad(i), gb = rgrad(i + int3(1, 0, 0)), gc = rgrad(i + int3(0, 1, 0)), gd = rgrad(i + int3(1, 1, 0));
    float3 ge = rgrad(i + int3(0, 0, 1)), gf = rgrad(i + int3(1, 0, 1)), gg = rgrad(i + int3(0, 1, 1)), gh = rgrad(i + int3(1, 1, 1));
    float va = dot(ga, f), vb = dot(gb, f - float3(1, 0, 0)), vc = dot(gc, f - float3(0, 1, 0)), vd = dot(gd, f - float3(1, 1, 0));
    float ve = dot(ge, f - float3(0, 0, 1)), vf = dot(gf, f - float3(1, 0, 1)), vg = dot(gg, f - float3(0, 1, 1)), vh = dot(gh, f - float3(1, 1, 1));
    float v = va + u.x * (vb - va) + u.y * (vc - va) + u.z * (ve - va) + u.x * u.y * (va - vb - vc + vd)
            + u.y * u.z * (va - vc - ve + vg) + u.z * u.x * (va - vb - ve + vf) + u.x * u.y * u.z * (-va + vb + vc - vd + ve - vf - vg + vh);
    float3 d = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.z * (ge - ga) + u.x * u.y * (ga - gb - gc + gd)
             + u.y * u.z * (ga - gc - ge + gg) + u.z * u.x * (ga - gb - ge + gf) + u.x * u.y * u.z * (-ga + gb + gc - gd + ge - gf - gg + gh)
             + du * (float3(vb - va, vc - va, ve - va) + u.yzx * float3(va - vb - vc + vd, va - vc - ve + vg, va - vb - ve + vf)
                     + u.zxy * float3(va - vb - ve + vf, va - vb - vc + vd, va - vc - ve + vg)
                     + u.yzx * u.zxy * (-va + vb + vc - vd + ve - vf - vg + vh));
    return float4(v, d);
}
static float3 rpal(constant float4* pal, int count, float x) {
    int n = max(count, 1);
    if (n == 1) return pal[0].rgb;
    float t = saturate(x) * float(n - 1);
    int i = min(int(floor(t)), n - 2);
    return mix(pal[i].rgb, pal[i + 1].rgb, t - float(i));
}
static float3 rhue(float h) {
    float3 k = abs(fract(float3(h) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return saturate(k - 1.0);
}

struct LifeU {
    float4 a, b, c, d, e, f;
    float4 color;
    float4 pal[8];
    int palCount;
};
struct PInst { float4 pos; float4 col; };
// p = x, y, 年齢（秒）, 寿命（秒）  q = 速さ x, y, 種（0〜1）, 生まれた角度
struct RP { float4 p; float4 q; };

// a = 数, 横の長さ, 1 歩の秒, 高さ px
// b = 中心 x, 中心 y, 半径, 縁の太さ
// c = 出る向き（0 外・1 内・2 両方）, 出る勢い, 縁にとどまる, 乱れの強さ
// d = 渦の大きさ, ノイズの時刻, 寿命, 1 歩で残る速さ（空気抵抗）
// e = 出る範囲の真ん中（ラジアン）, 出る範囲の幅（ラジアン）, 粒の大きさ px, 明るさ
// f = 色の付け方, 歩の番号, 0, 0
kernel void ring_step(device RP* st [[buffer(0)]], constant LifeU& u [[buffer(1)]], device PInst* inst [[buffer(2)]],
                      uint i [[thread_position_in_grid]]) {
    if (int(i) >= int(u.a.x)) return;
    RP me = st[i];
    float h = u.a.z;
    float2 c = u.b.xy;
    float R = u.b.z;
    int dirMode = int(u.c.x + 0.5);
    float age = me.p.z + h, life = me.p.w;
    float2 p = me.p.xy, v = me.q.xy;
    float seed = me.q.z, born = me.q.w;
    // 寿命が来た・遠くへ行きすぎた：縁のどこかで生まれ直す
    if (age >= life || length(p - c) > 4.0 || !all(isfinite(p))) {
        uint s = i * 747796405u + uint(u.f.y) * 2891336453u + 1u;
        float r0 = rhash(s), r3 = rhash(s ^ 0x1b56c4e9u);
        float ang = u.e.x + (r0 - 0.5) * u.e.y;
        // 角度は上から時計回り（画面の y は下向き）
        float2 dir = float2(sin(ang), -cos(ang));
        seed = rhash(s ^ 0x2545f491u);
        // 縁の太さの中の、粒ごとに決まった半径に生まれる（縁にとどまる間も、この半径へ引き戻す）
        p = c + dir * (R + (seed - 0.5) * 2.0 * u.b.w);
        float sgn = dirMode == 1 ? -1.0 : (dirMode == 2 ? (fract(seed * 7.13) < 0.5 ? -1.0 : 1.0) : 1.0);
        v = dir * sgn * u.c.y * (0.5 + r3);
        born = ang;
        // 寿命は粒ごとに ±40%。生まれた歩のうち、少しずらした所から始める
        life = u.d.z * (0.6 + 0.8 * rhash(s ^ 0x7f4a7c15u));
        age = h * rhash(s ^ 0x3c6ef372u);
    }
    float t01 = saturate(age / max(life, 1e-3));
    if (h > 0.0) {
        float2 rel = p - c;
        float rr = max(length(rel), 1e-4);
        float2 nr = rel / rr;
        // 流れ：ポテンシャルのノイズの curl（2 段）。渦の大きさがノイズの波長。
        // 時刻（z）は 64 で一周するので、z に掛けるのは整数だけ（折り返しで跳ばない）
        float sc = max(u.d.x, 0.005);
        float4 n1 = rnoised(float3(p / sc, u.d.y));
        float4 n2 = rnoised(float3(p / sc * 2.03 + float2(17.1, 3.7), u.d.y * 2.0 + 9.0));
        float2 g = n1.yz + 0.5 * n2.yz;
        float2 flow = float2(g.y, -g.x) * u.c.w;
        // 縁にとどまる：生まれてから「はがれる年齢」までは縁に張りつき、縁に沿ってゆっくり流れる。
        // はがれる年齢は、縁にとどまる × 粒ごとのばらつき × 縁に沿って場所ごとに変わる値（ところどころ早くはがれる）
        float ga = rnoised(float3(nr * 1.9 + float2(5.3, 1.1), u.d.y + 11.0)).x;
        float gate = smoothstep(-0.22, 0.08, ga);
        float sd2 = fract(seed * 13.37);
        float detach = min(u.c.z * 1.6, 1.2) * (0.3 + 0.7 * sd2) * mix(0.08, 1.0, gate);
        float hold = u.c.z <= 0.0 ? 0.0 : 1.0 - smoothstep(detach * 0.8, detach + 0.04, t01);
        // とどまる間は、縁に垂直な動きを消し、縁に沿う流れも弱める
        float2 vr = nr * dot(v, nr), fr = nr * dot(flow, nr);
        float2 vel = (v - vr * hold) + (flow - fr * hold) * (1.0 - 0.8 * hold);
        // 外へ（内へ）流れていく弱い向き（全体として縁から離れていく）
        float sgnOut = dirMode == 1 ? -1.0 : (dirMode == 2 ? (fract(seed * 7.13) < 0.5 ? -1.0 : 1.0) : 1.0);
        vel += nr * sgnOut * u.c.y * 0.6 * (1.0 - hold);
        p += vel * h;
        // 縁へ引き戻す（粒ごとに決まった半径へ。縁の太さの中でばらつく）
        float rb = R + (seed - 0.5) * 2.0 * u.b.w;
        float2 rel2 = p - c;
        float r2 = max(length(rel2), 1e-4);
        p = c + rel2 / r2 * mix(r2, rb, 1.0 - exp(-hold * 30.0 * h));
        // 空気抵抗は、はがれてから効く（はがれたとき、生まれたときの勢いで飛び出す）
        v *= mix(u.d.w, 1.0, hold);
    }
    st[i] = RP{ float4(p, age, life), float4(v, seed, born) };
    // 描く：生まれてすぐふわっと出て、寿命の終わりに薄く・小さくなって消える
    float fin = smoothstep(0.0, 0.04, t01);
    float fout = 1.0 - smoothstep(0.45, 1.0, t01);
    float a = fin * fout;
    int mode = int(u.f.x + 0.5);
    float3 col = u.color.rgb;
    if (mode == 1) col = rpal(u.pal, u.palCount, t01);
    else if (mode == 2) col = rhue(fract(born / 6.2831853));
    float H = u.a.w;
    float rad = u.e.z * (0.65 + 0.7 * seed) * mix(1.0, 0.45, smoothstep(0.4, 1.0, t01));
    // 1 px より小さい粒は 1 px で描いて、そのぶん暗く（明るさの合計を保つ）
    float drawn = max(rad, 0.75);
    float b = u.e.w * a * min((rad * rad) / (drawn * drawn), 1.0);
    inst[i] = PInst{ float4(p * H, drawn, 0.55), float4(col * b, b) };
}
"""

final class RingEmitterRenderer {
    static let shared = RingEmitterRenderer()
    let step: MTLComputePipelineState

    private init() {
        let dev = MetalContext.shared.device
        let lib: MTLLibrary
        do { lib = try dev.makeLibrary(source: ringShaderSource, options: nil) } catch {
            fatalError("輪から湧く粒のシェーダーを作れません: \(error)")
        }
        step = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "ring_step")!)
    }
}

final class RingEmitterSim {
    static let maxCount = 120_000
    /// 粒の状態（1 粒 32 バイト：場所・年齢・寿命 / 速さ・種・生まれた角度）
    let state: MTLBuffer
    let inst: MTLBuffer
    var canvas: MTLTexture?
    /// 動かした時間（秒。速さを掛けたもの）
    var time = 0.0
    /// ノイズの時刻（渦の変わる速さを掛けたもの。周期で折り返す）
    var noiseTime = 0.0
    var stepIndex: UInt32 = 0
    var drawn = false
    var warmed = false

    init?() {
        let r = LifeRenderer.shared
        var rng = SplitMix(seed: 0x21_76E0)
        var st = [SIMD4<Float>]()
        st.reserveCapacity(Self.maxCount * 2)
        // はじめは縁の上に、年齢をばらして並べる（すぐ空回しして、流れの途中の絵にする）
        for _ in 0..<Self.maxCount {
            let a = Float(rng.next() * 2 * .pi)
            let life = Float(4 * (0.6 + 0.8 * rng.next()))
            st.append(SIMD4(0.889 + sin(a) * 0.42, 0.5 - cos(a) * 0.42, Float(rng.next()) * life, life))
            st.append(SIMD4(0, 0, Float(rng.next()), a))
        }
        guard let s = r.shared(st, st.count * 16), let ib = r.buffer(Self.maxCount * 32) else { return nil }
        state = s; inst = ib
    }

    /// テスト用：今の粒の場所（高さ 1 の座標。GPU が終わってから読む）
    func positions(_ n: Int) -> [SIMD2<Float>] {
        let p = state.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxCount * 2)
        return (0..<min(n, Self.maxCount)).map { SIMD2(p[$0 * 2].x, p[$0 * 2].y) }
    }

    func render(_ e: Effect, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        let r = LifeRenderer.shared
        func v(_ j: Int) -> Double { e.value(j, at: now, beat: stack.beat, origin: stack.origin) }
        let A = Double(dst.width) / Double(max(dst.height, 1))
        let n = Int(min(max(v(0).rounded(), 1), Double(Self.maxCount)))
        let speed = max(v(20), 0)
        var u = LifeUniforms()
        u.setColors(e)
        let life = max(v(11), 0.05)
        u.a = SIMD4(Float(n), Float(A), 0, Float(dst.height))
        u.b = SIMD4(Float(v(3) * A), Float(v(4)), Float(max(v(1), 0.001)), Float(max(v(2), 0)))
        u.c = SIMD4(Float(v(5).rounded()), Float(max(v(6), 0)), Float(min(max(v(7), 0), 1)), Float(max(v(8), 0)))
        u.e = SIMD4(0, Float(min(max(v(13), 0), 360) * .pi / 180), Float(v(16) * Double(dst.height) / 1080), Float(max(v(17), 0)))
        u.f = SIMD4(Float(v(19).rounded()), 0, 0, 0)
        if canvas?.width != dst.width || canvas?.height != dst.height { canvas = r.canvas(dst.width, dst.height); drawn = false }
        guard let canvas else { return }
        // 初めの 1 回：寿命ぶんほど空回しして、出続けている途中の絵から始める
        var warm = 0.0
        if !warmed { warm = min(life * 1.3, 10); warmed = true }
        let run = dt * speed
        // 1 歩は 1/60 秒まで（空回しは 1/30 秒ずつ）
        let warmSteps = Int((warm * 30).rounded(.up))
        let steps = run > 0 ? min(max(1, Int((run * 60).rounded(.up))), 240) : 0
        let h = run > 0 ? run / Double(steps) : 0
        let drag = min(max(v(12), 0), 1)
        let evolve = max(v(10), 0)
        let center = v(14), spin = v(15)
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(RingEmitterRenderer.shared.step)
            enc.setBuffer(state, offset: 0, index: 0)
            enc.setBuffer(inst, offset: 0, index: 2)
            // 動かさない時も、描く粒は作る（歩数 0 のときは 1 回、時間 0 で）
            let total = warmSteps + max(steps, 1)
            for s in 0..<total {
                let hh = s < warmSteps ? 1.0 / 30 : (steps == 0 ? 0 : h)
                time += hh
                noiseTime += hh * evolve * 0.6
                // ノイズは z が 64 で一周するので、そこで折り返しても跳ばない
                noiseTime = noiseTime.truncatingRemainder(dividingBy: 64)
                stepIndex &+= 1
                let ang = (center + spin * time).truncatingRemainder(dividingBy: 360) * .pi / 180
                u.a.z = Float(hh)
                u.d = SIMD4(Float(max(v(9), 0.005)), Float(noiseTime), Float(life), Float(exp(-drag * 3 * hh)))
                u.e.x = Float(ang)
                u.f.y = Float(stepIndex % 16_000_000)
                enc.setBytes(&u, length: MemoryLayout<LifeUniforms>.stride, index: 1)
                LifeRenderer.dispatch(enc, n)
            }
            enc.endEncoding()
        }
        // 残像：前の絵を薄めて重ねる（0 なら毎コマ消す）
        let trailK = min(max(v(18), 0), 0.98)
        let fadeK = Float(trailK <= 0.001 ? 1 : 1 - pow(trailK, max(dt, 1.0 / 60) * 60 * 0.25))
        // 止まっている間は描き足さない（同じ絵のまま。重ねて明るくならないように）
        let first = !drawn
        let update = steps > 0 || first
        drawn = true
        r.drawDots(inst, count: n, canvas: canvas, fadeK: fadeK, update: update, clear: first, into: dst, cb: cb)
    }
}
