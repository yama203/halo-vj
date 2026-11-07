import Metal
import QuartzCore
import simd

// 動き続ける（前のコマを覚えている）ジェネレーター・エフェクト：
//   粘菌（フィジャルム）・パーティクル・ライフ・ホタルの同期・ストレンジ・アトラクター（このファイル）
//   時間のずらし・流体（Flow.swift）
// どれも GPU の上に状態を持ち、コマごとに進める。状態はクリップ（エフェクト）ごとに EffectProcessor が持つ。
// 止めていた・巻き戻した（時刻が飛んだ・戻った）ときは、その場から続ける。

/// 1 つ分の状態（種類ごとの中身と、前に進めた時刻）
final class LifeSlot {
    let sim: AnyObject
    var last = -1.0
    var lastUsed = 0.0
    init(_ sim: AnyObject) { self.sim = sim }
}

/// EffectProcessor が持つ、状態の置き場所
final class LifeStore {
    private var slots: [String: LifeSlot] = [:]

    /// key の状態と、進める秒数。はじめて作ったときは warm 秒（経過時間ぶん、上限あり）進めて、すぐそれらしく見せる
    func state<T: AnyObject>(_ key: String, now: Double, origin: Double, warm: Double,
                             valid: (T) -> Bool = { _ in true }, make: () -> T?) -> (T, Double)? {
        let wall = CACurrentMediaTime()
        if let s = slots[key], let t = s.sim as? T, valid(t) {
            var dt = s.last < 0 ? 0 : now - s.last
            if dt < 0 || dt > 0.5 { dt = 0 }
            s.last = now; s.lastUsed = wall
            return (t, dt)
        }
        slots = slots.filter { wall - $0.value.lastUsed < 30 }
        guard let t = make() else { return nil }
        let s = LifeSlot(t)
        s.last = now; s.lastUsed = wall
        slots[key] = s
        return (t, min(max(now - origin, warm * 0.4), warm))
    }

    func peek<T: AnyObject>(_ key: String) -> T? { slots[key]?.sim as? T }
}

private let lifeShaderSource = """
#include <metal_stdlib>
using namespace metal;

static float lhash(uint x) {
    x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16;
    return float(x) / 4294967295.0;
}
static float3 lpal(constant float4* pal, int count, float x) {
    int n = max(count, 1);
    if (n == 1) return pal[0].rgb;
    float t = saturate(x) * float(n - 1);
    int i = min(int(floor(t)), n - 2);
    return mix(pal[i].rgb, pal[i + 1].rgb, t - float(i));
}
static float3 lhue(float h) {
    float3 k = abs(fract(float3(h) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return saturate(k - 1.0);
}

struct LifeU {
    float4 a, b, c, d, e, f;
    float4 color;
    float4 pal[8];
    int palCount;
};

struct VO { float4 pos [[position]]; float2 uv; float2 local; float4 col; };

// ---- 画面いっぱいの四角 ----
vertex VO life_full(uint vid [[vertex_id]]) {
    float2 c = float2(float(vid & 1), float(vid >> 1));
    VO o;
    o.pos = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0);
    o.uv = c; o.local = 0.0; o.col = 0.0;
    return o;
}
// 前の絵を薄める（色の掛け算だけ。ブレンドで dst × (1 − k)）
fragment float4 life_fade(VO in [[stage_in]], constant float& k [[buffer(0)]]) { return float4(0.0, 0.0, 0.0, k); }
// 絵を写す
fragment float4 life_copy(VO in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = t.sample(s, in.uv);
    float a = saturate(c.a);
    return float4(min(c.rgb, float3(a)), a);
}

// ---- 光る粒（パーティクル・ライフ・ホタル）。pos = 場所（px）, 半径（px）, 芯の硬さ ----
struct PInst { float4 pos; float4 col; };
vertex VO life_dot_v(uint vid [[vertex_id]], uint iid [[instance_id]], device const PInst* inst [[buffer(0)]],
                     constant float2& size [[buffer(1)]]) {
    PInst p = inst[iid];
    float2 c = float2(float(vid & 1), float(vid >> 1)) * 2.0 - 1.0;
    float2 px = p.pos.xy + c * max(p.pos.z, 0.75);
    VO o;
    o.pos = float4(px.x / size.x * 2.0 - 1.0, 1.0 - px.y / size.y * 2.0, 0.0, 1.0);
    o.uv = float2(p.pos.w, 0.0); o.local = c; o.col = p.col;
    if (p.col.a <= 0.0) o.pos = float4(-2.0, -2.0, 0.0, 1.0);
    return o;
}
fragment float4 life_dot_f(VO in [[stage_in]]) {
    float d = length(in.local);
    if (d > 1.0) discard_fragment();
    float hard = in.uv.x;
    float soft = exp(-d * d * 4.5) * (1.0 - d);
    float core = 1.0 - smoothstep(0.35, 0.6, d);
    float k = mix(soft, core, hard);
    return in.col * k;
}

// ============ 粘菌 ============
// a = 数, 格子の幅, 高さ, 1 歩の長さ（マス） / b = センサーの角度, 距離（マス）, 曲がる角度, ゆらぎ
// c = 残る割合, にじみ, 置く量, 歩の番号 / d = えさの種類, 強さ, 時刻, 0
static float phySense(device const float* trail, float2 p, float ang, float sd, int W, int H) {
    float2 q = p + float2(cos(ang), sin(ang)) * sd;
    int x = int(floor(q.x)) % W; if (x < 0) x += W;
    int y = int(floor(q.y)) % H; if (y < 0) y += H;
    return trail[y * W + x];
}
static float phyAt(device const float* trail, int x, int y, int W, int H) {
    return trail[clamp(y, 0, H - 1) * W + clamp(x, 0, W - 1)];
}
kernel void phy_move(device float4* ag [[buffer(0)]], device float* trail [[buffer(1)]], constant LifeU& u [[buffer(2)]],
                     uint i [[thread_position_in_grid]]) {
    if (int(i) >= int(u.a.x)) return;
    int W = int(u.a.y), H = int(u.a.z);
    float4 s = ag[i];
    float2 p = s.xy;
    float ang = s.z;
    float sa = u.b.x, sd = u.b.y, ta = u.b.z;
    float F = phySense(trail, p, ang, sd, W, H), L = phySense(trail, p, ang - sa, sd, W, H), R = phySense(trail, p, ang + sa, sd, W, H);
    uint seed = i * 9781u + uint(u.c.w) * 6271u;
    float r = lhash(seed);
    if (F > L && F > R) {
    } else if (F < L && F < R) {
        ang += (r < 0.5 ? -ta : ta);
    } else if (L > R) {
        ang -= ta * (0.5 + r);
    } else if (R > L) {
        ang += ta * (0.5 + r);
    }
    ang += (lhash(seed ^ 0x5bd1e995u) - 0.5) * u.b.w * 1.5;
    p += float2(cos(ang), sin(ang)) * u.a.w;
    p.x -= float(W) * floor(p.x / float(W));
    p.y -= float(H) * floor(p.y / float(H));
    ag[i] = float4(p, fmod(ang, 6.2831853), s.w);
    int x = min(int(p.x), W - 1), y = min(int(p.y), H - 1);
    trail[y * W + x] += u.c.z;
}

kernel void phy_diffuse(device const float* src [[buffer(0)]], device float* dst [[buffer(1)]],
                        constant LifeU& u [[buffer(2)]], uint2 g [[thread_position_in_grid]]) {
    int W = int(u.a.y), H = int(u.a.z);
    if (int(g.x) >= W || int(g.y) >= H) return;
    int x = int(g.x), y = int(g.y);
    float sum = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        int yy = (y + dy + H) % H;
        for (int dx = -1; dx <= 1; dx++) sum += src[yy * W + (x + dx + W) % W];
    }
    float c = src[y * W + x];
    float v = mix(c, sum / 9.0, u.c.y) * u.c.x;
    // えさ：決まった所に、においを足し続ける（粘菌がそこへ集まって網をつなぐ）
    int food = int(u.d.x + 0.5);
    if (food > 0 && u.d.y > 0.0) {
        float2 q = float2(float(x) / float(H), float(y) / float(H));
        float A = float(W) / float(H), t = u.d.z;
        float f = 0.0;
        if (food == 1) {
            for (int k = 0; k < 5; k++) {
                float fk = float(k);
                float2 c0 = float2(A * (0.5 + 0.38 * sin(t * (0.11 + 0.03 * fk) + fk * 2.1)),
                                   0.5 + 0.36 * cos(t * (0.13 + 0.02 * fk) + fk * 1.3));
                f += exp(-dot(q - c0, q - c0) / 0.0012);
            }
        } else {
            float rr = length(q - float2(A * 0.5, 0.5));
            float ring = 0.3 + 0.05 * sin(t * 0.7);
            f = exp(-pow((rr - ring) / 0.012, 2.0));
        }
        v += f * u.d.y * u.c.z * 0.6;
    }
    dst[y * W + x] = v;
}

fragment float4 phy_draw(VO in [[stage_in]], device const float* trail [[buffer(0)]], constant LifeU& u [[buffer(1)]]) {
    int W = int(u.a.y), H = int(u.a.z);
    float2 q = in.uv * float2(W, H) - 0.5;
    int2 i0 = int2(floor(q));
    float2 f = q - float2(i0);
    float t = mix(mix(phyAt(trail, i0.x, i0.y, W, H), phyAt(trail, i0.x + 1, i0.y, W, H), f.x),
                  mix(phyAt(trail, i0.x, i0.y + 1, W, H), phyAt(trail, i0.x + 1, i0.y + 1, W, H), f.x), f.y);
    float v = 1.0 - exp(-t * u.e.x);
    // ごく薄いにじみは切って、網のすき間は透明に
    v = saturate((v - 0.012) / 0.988);
    int mode = int(u.e.y + 0.5);
    float3 col = mode == 1 ? lpal(u.pal, u.palCount, v) : u.color.rgb;
    float a = saturate(v);
    return float4(col * a, a);
}

// ============ パーティクル・ライフ ============
// a = 数, 横の長さ, 1 歩の秒, 届く広さ / b = 力, 止まる速さ（1 歩で残る速さ）, 近すぎの境, 種類の数
// c = 粒の大きさ（高さに対して）, 高さ px, 色の付け方, 光のにじみ / d = 好き嫌いの混ぜ具合（次の表へ）, 明るさ
struct PL { float4 p; float4 v; };
kernel void pl_step(device const PL* src [[buffer(0)]], device PL* dst [[buffer(1)]], constant LifeU& u [[buffer(2)]],
                    constant float* mat [[buffer(3)]], device PInst* inst [[buffer(4)]],
                    uint i [[thread_position_in_grid]], uint li [[thread_position_in_threadgroup]]) {
    int n = int(u.a.x);
    bool live = int(i) < n;
    PL me = live ? src[i] : PL{ float4(0.0), float4(0.0) };
    float A = u.a.y, dt = u.a.z, rmax = u.a.w, beta = u.b.z;
    int ns = int(u.b.w);
    int si = int(me.p.z);
    float2 p = me.p.xy, f = 0.0;
    threadgroup float4 tp[256];
    for (int base = 0; base < n; base += 256) {
        int j = base + int(li);
        tp[li] = j < n ? src[j].p : float4(1e5, 1e5, 0, 0);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        int m = min(256, n - base);
        for (int k = 0; k < m; k++) {
            float2 d = tp[k].xy - p;
            d.x -= A * round(d.x / A); d.y -= round(d.y);
            float r = length(d) / rmax;
            if (r > 0.0 && r < 1.0) {
                int sj = int(tp[k].z);
                float a = mix(mat[si * 8 + sj], mat[64 + si * 8 + sj], u.d.x);
                float F = r < beta ? r / beta - 1.0 : a * (1.0 - abs(2.0 * r - 1.0 - beta) / (1.0 - beta));
                f += d / (r * rmax) * F;
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (!live) return;
    float2 v = me.v.xy * u.b.y + f * rmax * u.b.x * 10.0 * dt;
    p += v * dt;
    p.x -= A * floor(p.x / A); p.y -= floor(p.y);
    dst[i] = PL{ float4(p, me.p.z, 0.0), float4(v, 0.0, 0.0) };
    float H = u.c.y;
    float hue = float(si) / float(max(ns, 1));
    float3 col = int(u.c.z + 0.5) == 1 ? lpal(u.pal, u.palCount, ns > 1 ? float(si) / float(ns - 1) : 0.0) : lhue(hue);
    float rad = u.c.x * H * (1.0 + u.c.w * 2.5);
    float b = u.d.y * (1.0 - 0.55 * u.c.w);
    inst[i] = PInst{ float4(p * H, rad, 1.0 - u.c.w), float4(col * b, b) };
}

// ============ ホタルの同期（蔵本モデル） ============
// a = 数, 横の長さ, 1 歩の秒, 見える広さ / b = そろう強さ, 拍への引き, 拍の位相（ラジアン）, 光の長さ
// c = 大きさ（高さに対して）, 高さ px, 光のにじみ, ふらふら / d = 時刻, 明るさ, 色のばらつき, 拍に合わせるか
// e = 平均の速さ（回/秒）, ばらつき
struct FF { float4 p; float4 q; };   // p = x, y, 位相, 自分の速さ（ばらつき -1〜1）  q = 色のばらつき, 大きさ, ふらつきの種, 0
kernel void ff_step(device const FF* src [[buffer(0)]], device FF* dst [[buffer(1)]], constant LifeU& u [[buffer(2)]],
                    device PInst* inst [[buffer(3)]],
                    uint i [[thread_position_in_grid]], uint li [[thread_position_in_threadgroup]]) {
    int n = int(u.a.x);
    bool live = int(i) < n;
    FF me = live ? src[i] : FF{ float4(0.0), float4(0.0) };
    float A = u.a.y, dt = u.a.z, R = u.a.w;
    float th = me.p.z;
    float sum = 0.0, cnt = 0.0;
    threadgroup float4 tp[256];
    for (int base = 0; base < n; base += 256) {
        int j = base + int(li);
        tp[li] = j < n ? src[j].p : float4(1e5, 1e5, 0, 0);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        int m = min(256, n - base);
        for (int k = 0; k < m; k++) {
            float2 d = tp[k].xy - me.p.xy;
            if (dot(d, d) < R * R) { sum += sin(tp[k].z - th); cnt += 1.0; }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (!live) return;
    float w = 6.2831853 * u.e.x * (1.0 + u.e.y * 0.5 * me.p.w);
    float dth = w + (cnt > 0.0 ? u.b.x * 4.0 * sum / cnt : 0.0);
    if (u.d.w > 0.5) dth += u.b.y * 6.0 * sin(u.b.z - th);
    th = fmod(th + dth * dt, 6.2831853);
    if (th < 0.0) th += 6.2831853;
    // ふらふら：1 匹ずつ別のゆっくりした動き
    float2 p = me.p.xy;
    float T = u.d.x, ph = me.q.z * 6.2831853;
    float2 vel = float2(sin(T * (0.31 + me.q.z * 0.3) + ph) + 0.5 * sin(T * 0.83 + ph * 2.0),
                        cos(T * (0.27 + me.q.x * 0.3) + ph * 1.3) + 0.5 * cos(T * 0.71 + ph)) * u.c.w * 0.06;
    p += vel * dt;
    p.x -= A * floor(p.x / A); p.y -= floor(p.y);
    dst[i] = FF{ float4(p, th, me.p.w), me.q };
    // 光る：位相が 0 を過ぎた所でぱっと光り、光の長さで消える
    float ph01 = th / 6.2831853;
    float pulse = exp(-ph01 / max(u.b.w * 0.45, 0.005));
    float H = u.c.y;
    float3 col = u.color.rgb;
    if (u.d.z > 0.0) {
        float3 alt = lhue(fract(0.17 + me.q.x * 0.5));
        col = mix(col, alt, u.d.z * me.q.x);
    }
    float glow = u.c.z;
    float b = u.d.y * (0.1 + 1.6 * pulse);
    float rad = u.c.x * H * me.q.y * (1.0 + glow * 4.0 * pulse);
    inst[i] = PInst{ float4(p * H, rad, 1.0 - glow), float4(col * b, b) };
}

// ============ ストレンジ・アトラクター ============
// a = 種類, 係数 a, b, c / b = d, 1 本あたりの歩数, 幅, 高さ / c = 大きさ, 回転（ラジアン）, コマの番号, 点の本数
// d = 濃さ, 残る割合, 色の付け方, 1 コマの点の数
static float3 attrStep(float3 p, int kind, float4 k) {
    if (kind == 0) return float3(sin(k.x * p.y) + k.z * cos(k.x * p.x), sin(k.y * p.x) + k.w * cos(k.y * p.y), 0.0);
    if (kind == 1) return float3(sin(k.x * p.y) - cos(k.y * p.x), sin(k.z * p.x) - cos(k.w * p.y), 0.0);
    if (kind == 2) {
        // トーマス：ゆっくり流れる 3D の流れ（係数 a で形が変わる）
        float bb = 0.19 + 0.02 * k.x;
        float3 d = float3(sin(p.y) - bb * p.x, sin(p.z) - bb * p.y, sin(p.x) - bb * p.z);
        return p + d * 0.06;
    }
    // アイザワ
    float a = 0.95 + 0.03 * k.x, b = 0.7 + 0.03 * k.y, c = 0.6 + 0.03 * k.z, dd = 3.5 + 0.1 * k.w;
    float3 d = float3((p.z - b) * p.x - dd * p.y, dd * p.x + (p.z - b) * p.y,
                      c + a * p.z - p.z * p.z * p.z / 3.0 - (p.x * p.x + p.y * p.y) * (1.0 + 0.25 * p.z) + 0.1 * p.z * p.x * p.x * p.x);
    return p + d * 0.012;
}
kernel void at_iter(device float4* walk [[buffer(0)]], device atomic_uint* cnt [[buffer(1)]], constant LifeU& u [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    int kind = int(u.a.x + 0.5);
    float4 k = float4(u.a.y, u.a.z, u.a.w, u.b.x);
    int steps = int(u.b.y);
    int W = int(u.b.z), H = int(u.b.w);
    float3 p = walk[i].xyz;
    if (!all(isfinite(p)) || length(p) > 50.0) p = float3(lhash(i * 7u) - 0.5, lhash(i * 13u) - 0.5, lhash(i * 17u) - 0.5) * 0.4;
    // 係数が動くと、点が全部同じ所に集まってしまうことがある（周期の決まった動きに吸い込まれる）。
    // 集まると二度と分かれず、点しか見えなくなるので、コマごとに 1% ほどを、ほかの点のすぐそば（わずかにずらす）へ移す。
    // 形の上の点から始めるので余計な線は出ず、わずかなずれがすぐ広がって、また筋に戻る
    uint fr = uint(u.c.z);
    if (lhash(i * 2654435761u ^ (fr * 2246822519u + 7u)) < 0.012) {
        uint j = uint(lhash(i * 3266489917u + fr * 668265263u) * float(u.c.w)) % uint(max(u.c.w, 1.0));
        float3 q = walk[j].xyz;
        if (all(isfinite(q)) && length(q) < 50.0) p = q;
        p += (float3(lhash(i * 31u + fr), lhash(i * 37u + fr * 3u), lhash(i * 41u + fr * 5u)) - 0.5) * 2e-3;
    }
    float scale = u.c.x;
    float cr = cos(u.c.y), sr = sin(u.c.y);
    bool is3D = kind >= 2;
    float ext = kind == 0 ? 1.0 + max(abs(k.z), abs(k.w)) : (kind == 1 ? 2.0 : (kind == 2 ? 4.2 : 1.6));
    float zoom = float(H) * 0.47 * scale / ext;
    for (int s = 0; s < steps; s++) {
        float3 np = attrStep(p, kind, k);
        float3 d = np - p;
        p = np;
        float3 q = p;
        if (kind == 3) q.z -= 0.6;
        float2 xy;
        if (is3D) {
            float x = q.x * cr + q.y * sr, y = -q.x * sr + q.y * cr;
            // 少し上から見る
            xy = float2(x, q.z * 0.94 - y * 0.34);
        } else {
            xy = float2(q.x * cr - q.y * sr, q.x * sr + q.y * cr);
        }
        float2 px = float2(W, H) * 0.5 + float2(xy.x, -xy.y) * zoom;
        int x = int(px.x), y = int(px.y);
        if (x < 0 || y < 0 || x >= W || y >= H) continue;
        uint idx = uint(y * W + x) * 4u;
        atomic_fetch_add_explicit(&cnt[idx], 16u, memory_order_relaxed);
        float2 dd = is3D ? float2(d.x * cr + d.y * sr, d.z) : d.xy;
        float3 c = lhue(atan2(dd.y, dd.x) / 6.2831853 + 0.5);
        atomic_fetch_add_explicit(&cnt[idx + 1], uint(c.r * 16.0), memory_order_relaxed);
        atomic_fetch_add_explicit(&cnt[idx + 2], uint(c.g * 16.0), memory_order_relaxed);
        atomic_fetch_add_explicit(&cnt[idx + 3], uint(c.b * 16.0), memory_order_relaxed);
    }
    walk[i] = float4(p, 0.0);
}
kernel void at_resolve(device atomic_uint* cnt [[buffer(0)]], device float4* acc [[buffer(1)]], constant LifeU& u [[buffer(2)]],
                       uint i [[thread_position_in_grid]]) {
    int W = int(u.b.z), H = int(u.b.w);
    if (int(i) >= W * H) return;
    uint b = i * 4u;
    float4 c = float4(atomic_exchange_explicit(&cnt[b], 0u, memory_order_relaxed),
                      atomic_exchange_explicit(&cnt[b + 1], 0u, memory_order_relaxed),
                      atomic_exchange_explicit(&cnt[b + 2], 0u, memory_order_relaxed),
                      atomic_exchange_explicit(&cnt[b + 3], 0u, memory_order_relaxed)) / 16.0;
    acc[i] = acc[i] * u.d.y + c;
}
fragment float4 at_draw(VO in [[stage_in]], device const float4* acc [[buffer(0)]], constant LifeU& u [[buffer(1)]]) {
    int W = int(u.b.z), H = int(u.b.w);
    int2 q = clamp(int2(in.uv * float2(W, H)), int2(0), int2(W - 1, H - 1));
    float4 c = acc[q.y * W + q.x];
    // 1 マスあたりの平均の点の数で割って、濃さで合わせる（点の数・大きさが変わっても同じくらいの明るさ）
    float v = 1.0 - exp(-c.x * u.d.x);
    v = pow(v, 0.7);
    int mode = int(u.d.z + 0.5);
    float3 col = u.color.rgb;
    if (mode == 1) col = lpal(u.pal, u.palCount, v);
    else if (mode == 2) col = c.x > 0.0 ? saturate(c.yzw / c.x * 1.25) : float3(0.0);
    return float4(col * v, v);
}
"""

/// 粘菌・パーティクル・ライフ・ホタル・アトラクターのシェーダー
final class LifeRenderer {
    static let shared = LifeRenderer()
    let device = MetalContext.shared.device
    let phyMove, phyDiffuse, plStep, ffStep, atIter, atResolve: MTLComputePipelineState
    let phyDraw, atDraw, dots, fade, copy: MTLRenderPipelineState

    private init() {
        let dev = MetalContext.shared.device
        let lib: MTLLibrary
        do { lib = try dev.makeLibrary(source: lifeShaderSource, options: nil) } catch {
            fatalError("動き続けるジェネレーターのシェーダーを作れません: \(error)")
        }
        func k(_ n: String) -> MTLComputePipelineState { try! dev.makeComputePipelineState(function: lib.makeFunction(name: n)!) }
        phyMove = k("phy_move"); phyDiffuse = k("phy_diffuse"); plStep = k("pl_step"); ffStep = k("ff_step")
        atIter = k("at_iter"); atResolve = k("at_resolve")
        func r(_ v: String, _ f: String, format: MTLPixelFormat = .bgra8Unorm,
               blend: (MTLBlendFactor, MTLBlendFactor)? = nil) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = format
            if let (s, t) = blend {
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add; ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = s; ca.sourceAlphaBlendFactor = s
                ca.destinationRGBBlendFactor = t; ca.destinationAlphaBlendFactor = t
            }
            return try! dev.makeRenderPipelineState(descriptor: d)
        }
        phyDraw = r("life_full", "phy_draw")
        atDraw = r("life_full", "at_draw")
        dots = r("life_dot_v", "life_dot_f", format: .rgba16Float, blend: (.one, .one))
        fade = r("life_full", "life_fade", format: .rgba16Float, blend: (.zero, .oneMinusSourceAlpha))
        copy = r("life_full", "life_copy")
    }

    func buffer(_ length: Int) -> MTLBuffer? { device.makeBuffer(length: max(length, 16), options: .storageModePrivate) }
    func shared(_ bytes: UnsafeRawPointer, _ length: Int) -> MTLBuffer? {
        device.makeBuffer(bytes: bytes, length: length, options: .storageModeShared)
    }
    func canvas(_ w: Int, _ h: Int) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        return device.makeTexture(descriptor: td)
    }

    /// 1 次元の仕事を 256 ずつに分けて流す
    static func dispatch(_ enc: MTLComputeCommandEncoder, _ n: Int) {
        enc.dispatchThreadgroups(MTLSize(width: max((n + 255) / 256, 1), height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// 画面いっぱいに描く（clear で始める）
    func fullPass(into dst: MTLTexture, cb: MTLCommandBuffer, _ body: (MTLRenderCommandEncoder) -> Void) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        body(enc)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    /// 光る粒を、残像のキャンバスに重ねて（前の絵は fadeK だけ薄める）、dst へ写す
    func drawDots(_ inst: MTLBuffer, count: Int, canvas: MTLTexture, fadeK: Float, update: Bool = true, clear: Bool = false,
                  into dst: MTLTexture, cb: MTLCommandBuffer) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = canvas
        rpd.colorAttachments[0].loadAction = clear || fadeK >= 0.999 ? .clear : .load
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        if update, let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            var k = fadeK
            enc.setRenderPipelineState(fade)
            enc.setFragmentBytes(&k, length: 4, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            var size = SIMD2(Float(canvas.width), Float(canvas.height))
            enc.setRenderPipelineState(dots)
            enc.setVertexBuffer(inst, offset: 0, index: 0)
            enc.setVertexBytes(&size, length: 8, index: 1)
            if count > 0 { enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count) }
            enc.endEncoding()
        }
        fullPass(into: dst, cb: cb) { enc in
            enc.setRenderPipelineState(copy)
            enc.setFragmentTexture(canvas, index: 0)
        }
    }
}

struct LifeUniforms {
    var a = SIMD4<Float>.zero, b = SIMD4<Float>.zero, c = SIMD4<Float>.zero
    var d = SIMD4<Float>.zero, e = SIMD4<Float>.zero, f = SIMD4<Float>.zero
    var color = SIMD4<Float>(1, 1, 1, 1)
    var pal: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
              SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var palCount: Int32 = 1

    mutating func setColors(_ e: Effect) {
        color = e.color.simd
        let p = (e.palette.isEmpty ? [RGB.black, RGB.white] : Array(e.palette.prefix(8))).map(\.simd)
        func at(_ i: Int) -> SIMD4<Float> { i < p.count ? p[i] : p[p.count - 1] }
        pal = (at(0), at(1), at(2), at(3), at(4), at(5), at(6), at(7))
        palCount = Int32(p.count)
    }
}

// MARK: - 粘菌

final class PhysarumSim {
    static let maxAgents = 1_000_000
    let agents: MTLBuffer
    var trail: [MTLBuffer]
    let W: Int, H: Int
    var cur = 0
    var step: UInt32 = 0
    var time = 0.0
    var count = 0
    let start: Int

    /// 格子の大きさ：高さ 720 まで（それより大きい出力は、なめらかに広げて描く）
    static func gridSize(width: Int, height: Int) -> (Int, Int) {
        // 小さな出力（プレビュー・サムネイル）でも、高さ 360 の格子で動かす（網が細かくなりすぎて消えないように）
        let h = min(max(height, 360), 720)
        return (max(Int((Double(width) / Double(max(height, 1)) * Double(h)).rounded()), 8), h)
    }

    init?(width: Int, height: Int, start: Int) {
        let r = LifeRenderer.shared
        (W, H) = Self.gridSize(width: width, height: height)
        self.start = start
        var rng = SplitMix(seed: 0x5117_3E0D)
        var st = [SIMD4<Float>](repeating: .zero, count: Self.maxAgents)
        let cx = Float(W) / 2, cy = Float(H) / 2
        for i in 0..<Self.maxAgents {
            let a = Float(rng.next() * 2 * .pi)
            switch start {
            case 1:
                // 円：輪の上から、真ん中を向いて
                let rr = Float(H) * 0.38 * Float(0.92 + rng.next() * 0.08)
                st[i] = SIMD4(cx + cos(a) * rr, cy + sin(a) * rr, a + .pi, 0)
            case 2:
                // 真ん中から：外へ向かって
                let rr = Float(sqrt(rng.next())) * Float(H) * 0.06
                st[i] = SIMD4(cx + cos(a) * rr, cy + sin(a) * rr, a, 0)
            default:
                st[i] = SIMD4(Float(rng.next()) * Float(W), Float(rng.next()) * Float(H), Float(rng.next() * 2 * .pi), 0)
            }
        }
        guard let ag = r.shared(st, st.count * 16),
              let t0 = r.device.makeBuffer(length: W * H * 4, options: .storageModeShared),
              let t1 = r.device.makeBuffer(length: W * H * 4, options: .storageModeShared) else { return nil }
        memset(t0.contents(), 0, W * H * 4); memset(t1.contents(), 0, W * H * 4)
        agents = ag; trail = [t0, t1]
    }

    func render(_ e: Effect, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        let r = LifeRenderer.shared
        func v(_ j: Int) -> Double { e.value(j, at: now, beat: stack.beat, origin: stack.origin) }
        // 数は 720p の格子での数。格子が小さい（プレビュー）ときは、同じ混み具合になるように減らす
        let area = Double(W * H) / (1280 * 720)
        let n = Int(min(max((v(0) * min(area, 1)).rounded(), 200), Double(Self.maxAgents)))
        count = n
        let speed = max(v(1), 0)
        let scale = Double(H) / 1080
        var u = LifeUniforms()
        u.setColors(e)
        // 跡の残る長さ：1 歩ごとに残る割合
        let keep = 0.80 + 0.195 * pow(min(max(v(5), 0), 1), 0.6)
        // 置く量は、粒の数とマスの数で合わせる（数を変えても明るさがだいたい同じ）
        let deposit = Double(W * H) / Double(n) * 0.35
        u.a = SIMD4(Float(n), Float(W), Float(H), Float(max(speed, 0.0001) * 1.6 * scale * 1080 / 720))
        u.b = SIMD4(Float(v(2) * .pi / 180), Float(v(3) * scale), Float(v(4) * .pi / 180), Float(v(11)))
        u.c = SIMD4(Float(keep), Float(v(6)), Float(deposit), 0)
        u.d = SIMD4(Float(v(9).rounded()), Float(v(10)), 0, 0)
        if dt > 0, speed > 0 {
            let steps = min(max(1, Int((dt * 60 * speed).rounded(.up))), 240)
            let enc = cb.makeComputeCommandEncoder()
            for _ in 0..<steps {
                step &+= 1
                time += 1.0 / 60
                u.c.w = Float(step % 100_000)
                u.d.z = Float(time.truncatingRemainder(dividingBy: 10000))
                enc?.setComputePipelineState(r.phyMove)
                enc?.setBuffer(agents, offset: 0, index: 0)
                enc?.setBuffer(trail[cur], offset: 0, index: 1)
                enc?.setBytes(&u, length: MemoryLayout<LifeUniforms>.stride, index: 2)
                LifeRenderer.dispatch(enc!, n)
                enc?.setComputePipelineState(r.phyDiffuse)
                enc?.setBuffer(trail[cur], offset: 0, index: 0)
                enc?.setBuffer(trail[1 - cur], offset: 0, index: 1)
                enc?.setBytes(&u, length: MemoryLayout<LifeUniforms>.stride, index: 2)
                enc?.dispatchThreads(MTLSize(width: W, height: H, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                cur = 1 - cur
            }
            enc?.endEncoding()
        }
        // 明るさ：跡の濃さ（置く量 × 残る長さで決まる）に合わせる
        u.e = SIMD4(Float(max(v(7), 0) * 0.9 * (1 - keep) / max(deposit, 1e-4)), Float(v(8).rounded()), 0, 0)
        r.fullPass(into: dst, cb: cb) { enc in
            enc.setRenderPipelineState(r.phyDraw)
            enc.setFragmentBuffer(trail[cur], offset: 0, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<LifeUniforms>.stride, index: 1)
        }
    }
}

// MARK: - パーティクル・ライフ

final class ParticleLifeSim {
    static let maxCount = 6000
    var state: [MTLBuffer]
    let inst: MTLBuffer
    var canvas: MTLTexture?
    var cur = 0
    var time = 0.0
    var drawn = false

    init?() {
        let r = LifeRenderer.shared
        var rng = SplitMix(seed: 0x11FE)
        var st = [SIMD4<Float>]()
        st.reserveCapacity(Self.maxCount * 2)
        for i in 0..<Self.maxCount {
            st.append(SIMD4(Float(rng.next() * 1.8), Float(rng.next()), Float(i % 8), 0))
            st.append(.zero)
        }
        guard let a = r.shared(st, st.count * 16), let b = r.shared(st, st.count * 16),
              let ib = r.buffer(Self.maxCount * 32) else { return nil }
        state = [a, b]; inst = ib
    }

    /// 好き嫌いの表（たねごとに決まる。-1〜1。8 × 8）
    static func matrix(seed: Int) -> [Float] {
        var rng = SplitMix(seed: UInt64(bitPattern: Int64(seed &* 7919 &+ 12345)))
        return (0..<64).map { _ in Float(rng.next() * 2 - 1) }
    }

    func render(_ e: Effect, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        let r = LifeRenderer.shared
        func v(_ j: Int) -> Double { e.value(j, at: now, beat: stack.beat, origin: stack.origin) }
        let A = Double(dst.width) / Double(max(dst.height, 1))
        let n = Int(min(max(v(0).rounded(), 2), Double(Self.maxCount)))
        let ns = Int(min(max(v(1).rounded(), 1), 8))
        // 拍ごとに好き嫌いを入れ替える：次の表へ、1 拍かけてなめらかに
        let every = [0.0, 1, 2, 4, 8, 16, 32][min(max(Int(v(10).rounded()), 0), 6)]
        var seed = Int(v(2).rounded()), blend: Float = 0
        if every > 0 {
            let beats = stack.beat.beat(at: now)
            let k = floor(beats / every)
            seed += Int(k)
            let into = beats - k * every
            // 切り替わる前の 1 拍で、次の表へ寄せていく
            let lead = min(1.0, every)
            if into > every - lead { blend = Float(smoothstepD((into - (every - lead)) / lead)) }
        }
        let m = Self.matrix(seed: seed) + Self.matrix(seed: seed + 1)
        let speed = max(v(6), 0)
        var u = LifeUniforms()
        u.setColors(e)
        let fr = min(max(v(5), 0), 1)
        u.a = SIMD4(Float(n), Float(A), 0, Float(max(v(3), 0.01)))
        u.b = SIMD4(Float(max(v(4), 0)), 0, 0.3, Float(ns))
        u.c = SIMD4(Float(v(7) / 1080), Float(dst.height), Float(v(9).rounded()), Float(v(8)))
        u.d = SIMD4(blend, Float(max(v(11), 0)), 0, 0)
        if canvas?.width != dst.width || canvas?.height != dst.height { canvas = r.canvas(dst.width, dst.height); drawn = false }
        guard let canvas else { return }
        let steps = dt > 0 && speed > 0 ? min(max(1, Int((dt * 60).rounded(.up))), 240) : 0
        let h = dt > 0 ? dt * speed / Double(max(steps, 1)) : 0
        // 摩擦：半分になるまでの秒（ブレーキ 0 → 1 秒、1 → 0.02 秒）
        let half = 1.0 * pow(0.02, fr)
        u.b.y = Float(pow(0.5, h / half))
        u.a.z = Float(h)
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(r.plStep)
            // 動かさない時も、描く粒は作る（歩数 0 のときは 1 回、時間 0 で）
            for _ in 0..<max(steps, 1) {
                if steps == 0 { u.a.z = 0 }
                enc.setBuffer(state[cur], offset: 0, index: 0)
                enc.setBuffer(state[1 - cur], offset: 0, index: 1)
                enc.setBytes(&u, length: MemoryLayout<LifeUniforms>.stride, index: 2)
                m.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 3) }
                enc.setBuffer(inst, offset: 0, index: 4)
                LifeRenderer.dispatch(enc, n)
                cur = 1 - cur
            }
            enc.endEncoding()
        }
        // 残像：前の絵を薄めて重ねる（0 なら毎コマ消す）
        let trailK = min(max(v(12), 0), 0.98)
        let fadeK = Float(trailK <= 0.001 ? 1 : 1 - pow(trailK, max(dt, 1.0 / 60) * 60 * 0.25))
        // 止まっている間は描き足さない（同じ絵のまま。重ねて明るくならないように）
        let first = !drawn
        let update = steps > 0 || first
        drawn = true
        time += dt
        r.drawDots(inst, count: n, canvas: canvas, fadeK: fadeK, update: update, clear: first, into: dst, cb: cb)
    }
}

private func smoothstepD(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }

// MARK: - ホタルの同期

final class FireflySim {
    static let maxCount = 4000
    var state: [MTLBuffer]
    let inst: MTLBuffer
    var canvas: MTLTexture?
    var cur = 0
    var time = 0.0

    init?(aspect: Double) {
        let r = LifeRenderer.shared
        var rng = SplitMix(seed: 0xF1EF)
        var st = [SIMD4<Float>]()
        st.reserveCapacity(Self.maxCount * 2)
        for _ in 0..<Self.maxCount {
            st.append(SIMD4(Float(rng.next() * aspect), Float(rng.next()), Float(rng.next() * 2 * .pi), Float(rng.next() * 2 - 1)))
            st.append(SIMD4(Float(rng.next()), Float(0.6 + rng.next() * 0.8), Float(rng.next()), 0))
        }
        guard let a = r.shared(st, st.count * 16), let b = r.shared(st, st.count * 16),
              let ib = r.buffer(Self.maxCount * 32) else { return nil }
        state = [a, b]; inst = ib
    }

    /// 今の位相（テスト用。GPU が終わってから読む）
    func phases(_ n: Int) -> [Float] {
        let p = state[cur].contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxCount * 2)
        return (0..<min(n, Self.maxCount)).map { p[$0 * 2].z }
    }

    func render(_ e: Effect, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        let r = LifeRenderer.shared
        func v(_ j: Int) -> Double { e.value(j, at: now, beat: stack.beat, origin: stack.origin) }
        let A = Double(dst.width) / Double(max(dst.height, 1))
        let n = Int(min(max(v(0).rounded(), 1), Double(Self.maxCount)))
        var u = LifeUniforms()
        u.setColors(e)
        // 拍に合わせる：1 回光るのに何拍か（0 = 合わせない）
        let per = [0.0, 0.5, 1, 2, 4][min(max(Int(v(9).rounded()), 0), 4)]
        let bpm = stack.beat.bpm > 0 ? stack.beat.bpm : 120
        let freq = per > 0 ? bpm / 60 / per : max(v(3), 0.01)
        let R = v(2) >= 0.999 ? 10.0 : max(v(2), 0.01)
        u.a = SIMD4(Float(n), Float(A), 0, Float(R))
        u.b = SIMD4(Float(max(v(1), 0)), Float(max(v(10), 0)), 0, Float(max(v(5), 0.01)))
        u.c = SIMD4(Float(v(6) / 1080), Float(dst.height), Float(min(max(v(7), 0), 1)), Float(max(v(8), 0)))
        u.d = SIMD4(0, Float(max(v(11), 0)), Float(min(max(v(12), 0), 1)), per > 0 ? 1 : 0)
        u.e = SIMD4(Float(freq), Float(min(max(v(4), 0), 1)), 0, 0)
        if canvas?.width != dst.width || canvas?.height != dst.height { canvas = r.canvas(dst.width, dst.height) }
        guard let canvas else { return }
        let steps = dt > 0 ? min(max(1, Int((dt * 120).rounded(.up))), 1200) : 0
        let h = dt / Double(max(steps, 1))
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(r.ffStep)
            for s in 0..<max(steps, 1) {
                let t = steps == 0 ? now : now - dt + h * Double(s + 1)
                time += steps == 0 ? 0 : h
                u.a.z = Float(steps == 0 ? 0 : h)
                u.d.x = Float(time.truncatingRemainder(dividingBy: 10000))
                // 拍の位相：拍の頭（per 拍ごと）で光るように
                if per > 0 {
                    let beats = stack.beat.beat(at: t) / per
                    u.b.z = Float((beats - floor(beats)) * 2 * .pi)
                }
                enc.setBuffer(state[cur], offset: 0, index: 0)
                enc.setBuffer(state[1 - cur], offset: 0, index: 1)
                enc.setBytes(&u, length: MemoryLayout<LifeUniforms>.stride, index: 2)
                enc.setBuffer(inst, offset: 0, index: 3)
                LifeRenderer.dispatch(enc, n)
                cur = 1 - cur
            }
            enc.endEncoding()
        }
        r.drawDots(inst, count: n, canvas: canvas, fadeK: 1, into: dst, cb: cb)
    }
}

// MARK: - ストレンジ・アトラクター

final class AttractorSim {
    static let walkers = 65536
    let walk: MTLBuffer
    var counts: MTLBuffer?
    var acc: MTLBuffer?
    var W = 0, H = 0
    var time = 0.0
    var kind = -1
    var frame: UInt32 = 0

    /// テスト用：点の場所がいくつに分かれているか（同じ所に重なった点は 1 つと数える）
    func distinctWalkers() -> Int {
        let p = walk.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.walkers)
        var set = Set<SIMD2<Int32>>()
        for i in 0..<Self.walkers {
            let q = p[i]
            set.insert(SIMD2(Int32(clamping: Int((q.x * 1e4).rounded())), Int32(clamping: Int((q.y * 1e4).rounded()))))
        }
        return set.count
    }

    init?() {
        let r = LifeRenderer.shared
        var rng = SplitMix(seed: 0xA77)
        let st = (0..<Self.walkers).map { _ in
            SIMD4(Float(rng.next() - 0.5) * 0.4, Float(rng.next() - 0.5) * 0.4, Float(rng.next() - 0.5) * 0.4, 0)
        }
        guard let w = r.shared(st, st.count * 16) else { return nil }
        walk = w
    }

    func render(_ e: Effect, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        let r = LifeRenderer.shared
        func v(_ j: Int) -> Double { e.value(j, at: now, beat: stack.beat, origin: stack.origin) }
        if W != dst.width || H != dst.height || counts == nil {
            W = dst.width; H = dst.height
            counts = r.device.makeBuffer(length: W * H * 16, options: .storageModePrivate)
            acc = r.device.makeBuffer(length: W * H * 16, options: .storageModePrivate)
            if let b = cb.makeBlitCommandEncoder() {
                if let c = counts { b.fill(buffer: c, range: 0..<c.length, value: 0) }
                if let a = acc { b.fill(buffer: a, range: 0..<a.length, value: 0) }
                b.endEncoding()
            }
        }
        guard let counts, let acc else { return }
        let k = Int(v(0).rounded())
        // 種類を変えたら、前の形の残りを消す
        if k != kind, kind >= 0, let b = cb.makeBlitCommandEncoder() {
            b.fill(buffer: acc, range: 0..<acc.length, value: 0)
            b.endEncoding()
        }
        kind = k
        time += dt
        // 変身：係数をゆっくり揺らす（変身の速さ × 秒）
        let ms = max(v(5), 0), ma = max(v(6), 0)
        let T = time * ms
        let wob = [sin(T * 0.71 + 0.3), sin(T * 0.53 + 1.9), sin(T * 0.37 + 4.1), sin(T * 0.61 + 2.7)].map { $0 * ma * 0.35 }
        let el = max(now - stack.origin, 0)
        let rot = (v(10) * el).truncatingRemainder(dividingBy: 360) * .pi / 180
        // 1 コマの点の数（百万）。1 本あたりの歩数に直す
        let total = max(v(12), 0.05) * 1_000_000
        let steps = min(max(Int(total / Double(Self.walkers)), 2), 256)
        // 残る割合：1/60 秒あたり
        let keep = min(max(v(8), 0), 0.995)
        let frameKeep = dt > 0 ? pow(keep, dt * 60) : (time > 0 ? 1 : keep)
        var u = LifeUniforms()
        u.setColors(e)
        u.a = SIMD4(Float(k), Float(v(1) + wob[0]), Float(v(2) + wob[1]), Float(v(3) + wob[2]))
        u.b = SIMD4(Float(v(4) + wob[3]), Float(steps), Float(W), Float(H))
        frame &+= 1
        u.c = SIMD4(Float(max(v(9), 0.05)), Float(rot), Float(frame % 1_000_000), Float(Self.walkers))
        // 濃さ：1 マスあたりの平均の点の数（残る分も入れて）で割る
        let perCell = Double(Self.walkers * steps) / Double(W * H) / max(1 - keep, 0.005)
        u.d = SIMD4(Float(max(v(7), 0) * 0.18 / max(perCell, 1e-4)), Float(frameKeep), Float(v(11).rounded()), 0)
        let iterate = dt > 0 || time <= 0 || acc.length == 0
        if let enc = cb.makeComputeCommandEncoder() {
            if iterate {
                enc.setComputePipelineState(r.atIter)
                enc.setBuffer(walk, offset: 0, index: 0)
                enc.setBuffer(counts, offset: 0, index: 1)
                enc.setBytes(&u, length: MemoryLayout<LifeUniforms>.stride, index: 2)
                LifeRenderer.dispatch(enc, Self.walkers)
            }
            enc.setComputePipelineState(r.atResolve)
            enc.setBuffer(counts, offset: 0, index: 0)
            enc.setBuffer(acc, offset: 0, index: 1)
            enc.setBytes(&u, length: MemoryLayout<LifeUniforms>.stride, index: 2)
            LifeRenderer.dispatch(enc, W * H)
            enc.endEncoding()
        }
        r.fullPass(into: dst, cb: cb) { enc in
            enc.setRenderPipelineState(r.atDraw)
            enc.setFragmentBuffer(acc, offset: 0, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<LifeUniforms>.stride, index: 1)
        }
    }
}

extension EffectKind {
    /// 前のコマを覚えて動き続けるもの（プレビュー用の書き出しで、コマを進めて描く）
    var isStateful: Bool { [.school, .physarum, .particleLife, .fireflies, .attractor, .timeWarp, .fluid,
                               .glitchBox, .vhs, .videoFeedback, .rasterScan, .crt].contains(self) }
}
