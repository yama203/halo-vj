import AppKit
import CoreText
import Metal
import QuartzCore
import simd

// 追加のエフェクト：
//   光のにじみ（ブルーム）・万華鏡・色ずれ・モザイク／網点・輪郭ネオン・ズームぼかし（光・形）
//   ピクセルソート・データモッシュ風・文字モザイク・ディザ・ガラス片（グリッチ・デジタル）

private let moreFXSource = """
#include <metal_stdlib>
using namespace metal;

struct VO { float4 pos [[position]]; float2 uv; };
vertex VO mf_full(uint vid [[vertex_id]]) {
    float2 c = float2(float(vid & 1), float(vid >> 1));
    VO o; o.pos = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0); o.uv = c; return o;
}
static float h1(float x) { return fract(sin(x * 12.9898) * 43758.5453); }
static float h2(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float2 h22(float2 p) {
    return fract(sin(float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)))) * 43758.5453);
}
static float vn(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    return mix(mix(h2(i), h2(i + float2(1, 0)), w.x), mix(h2(i + float2(0, 1)), h2(i + float2(1, 1)), w.x), w.y);
}
static float lum(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
static float3 hue(float h) { float3 k = abs(fract(float3(h) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0); return saturate(k - 1.0); }
static float3 pal(constant float4* p, int n, float x) {
    n = max(n, 1);
    if (n == 1) return p[0].rgb;
    float t = saturate(x) * float(n - 1);
    int i = min(int(floor(t)), n - 2);
    return mix(p[i].rgb, p[i + 1].rgb, t - float(i));
}

// a〜d = 値 / size = 絵の大きさ / time / mixAmt = 不透明度 / color・pal = 色
struct MU { float4 a, b, c, d; float4 color; float4 pal[8]; float2 size; float time; float mixAmt; int palCount; };

static float4 finish(float4 orig, float4 col, float m) { return mix(orig, col, saturate(m)); }

// ===== 光のにじみ：明るい所だけ取り出して小さくする =====
// a.x = しきい値, a.y = やわらかさ
fragment float4 mf_bright(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = t.sample(s, in.uv);
    float l = lum(c.rgb);
    float k = smoothstep(u.a.x, u.a.x + max(u.a.y, 0.02), l);
    return float4(c.rgb * k, 1.0);
}
// ぼかし（片方向。b.xy = 1 画素の向き, b.z = 広がり）
fragment float4 mf_blur(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 d = u.b.xy * u.b.z;
    float4 acc = 0.0; float wsum = 0.0;
    for (int i = -8; i <= 8; i++) {
        float w = exp(-float(i * i) / 18.0);
        acc += t.sample(s, in.uv + d * float(i)) * w;
        wsum += w;
    }
    return acc / wsum;
}
// 重ねる：a.z = 強さ, c.xyz = 色み（1,1,1 で元の色）, a.w = 元の絵の明るさ
fragment float4 mf_bloomOut(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]],
                            texture2d<float> b1 [[texture(1)]], texture2d<float> b2 [[texture(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 o = t.sample(s, in.uv);
    float3 g = (b1.sample(s, in.uv).rgb * 0.6 + b2.sample(s, in.uv).rgb * 0.9) * u.a.z * u.c.xyz;
    float3 c = o.rgb * u.a.w + g;
    float a = max(o.a, saturate(lum(g)));
    return finish(o, float4(c, a), u.mixAmt);
}

// ===== 万華鏡 =====
// a = 枚数, 回転(ラジアン), ズーム, 鏡にする / b = 中心x, 中心y, 取る所のずれ, 取る所の回転(ラジアン)
fragment float4 mf_kaleido(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::mirrored_repeat);
    float A = u.size.x / max(u.size.y, 1.0);
    float2 c = float2(u.b.x, u.b.y);
    float2 p = (in.uv - c) * float2(A, 1.0);
    float r = length(p) / max(u.a.z, 0.05);
    float ang = atan2(p.y, p.x) + u.a.y;
    float n = max(floor(u.a.x + 0.5), 1.0);
    float seg = 6.2831853 / n;
    float k = floor(ang / seg);
    float f = ang - k * seg;
    if (u.a.w > 0.5 && fmod(abs(k), 2.0) > 0.5) f = seg - f;
    f += u.b.w;
    float2 q = float2(cos(f), sin(f)) * r + float2(u.b.z, 0.0);
    float2 uv = q / float2(A, 1.0) + 0.5;
    float4 orig = t.sample(s, in.uv);
    return finish(orig, t.sample(s, uv), u.mixAmt);
}

// ===== 色ずれ =====
// a = ずれ(px 1080p), 角度(ラジアン), 形(0 横 1 放射 2 揺れ), 揺れ / b.x = 揺れる速さ
fragment float4 mf_rgb(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float k = u.size.y / 1080.0;
    float2 px = 1.0 / u.size;
    int m = int(u.a.z + 0.5);
    float2 d;
    if (m == 1) {
        d = (in.uv - 0.5) * 2.0 * u.a.x * k * px * 6.0;
    } else {
        d = float2(cos(u.a.y), sin(u.a.y)) * u.a.x * k * px;
    }
    if (m == 2 || u.a.w > 0.0) {
        float T = u.time * max(u.b.x, 0.0);
        float j = (vn(float2(T * 3.0, in.uv.y * 8.0)) - 0.5) * 2.0;
        float band = step(0.7, vn(float2(floor(in.uv.y * 30.0), floor(T * 8.0))));
        d *= 1.0 + u.a.w * (j * 2.0 + band * 3.0);
    }
    float4 o = t.sample(s, in.uv);
    float4 r = t.sample(s, in.uv + d), b = t.sample(s, in.uv - d);
    float4 c = float4(r.r, o.g, b.b, max(max(r.a, o.a), b.a));
    return finish(o, c, u.mixAmt);
}

// ===== モザイク・網点 =====
// a = 形(0 四角 1 丸い点 2 網点 3 横線), 大きさ(px 1080p), 角度(ラジアン), 点の大きさ / b.x = 背景を透明に
fragment float4 mf_pixel(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float k = u.size.y / 1080.0;
    float cell = max(u.a.y * k, 1.0);
    int m = int(u.a.x + 0.5);
    float2 px = in.uv * u.size;
    float4 o = t.sample(s, in.uv);
    float ca = cos(u.a.z), sa = sin(u.a.z);
    float2x2 R = float2x2(float2(ca, sa), float2(-sa, ca));
    float2x2 Ri = float2x2(float2(ca, -sa), float2(sa, ca));
    float2 q = R * px;
    float2 cid = floor(q / cell);
    float2 cc = (cid + 0.5) * cell;
    float2 cuv = (Ri * cc) / u.size;
    float4 c = t.sample(s, cuv);
    float4 res;
    float aa = 1.2;
    if (m == 0) {
        res = c;
    } else if (m == 1) {
        float d = length(q - cc);
        float rad = cell * 0.5 * clamp(u.a.w, 0.05, 1.5);
        float on = 1.0 - smoothstep(rad - aa, rad + aa, d);
        res = float4(c.rgb * on, mix(on * c.a, c.a, 0.0));
        if (u.b.x < 0.5) res = float4(c.rgb * on, c.a);
    } else if (m == 2) {
        // 網点：明るいほど大きい黒い点…ではなく、色の明るさに合わせて点の大きさを変える
        float d = length(q - cc);
        float l = lum(c.rgb);
        float rad = cell * 0.62 * sqrt(saturate(l)) * clamp(u.a.w * 1.4, 0.1, 2.0);
        float on = 1.0 - smoothstep(rad - aa, rad + aa, d);
        float3 col = c.rgb / max(l, 0.05) * 0.9;
        res = float4(saturate(col) * on, u.b.x > 0.5 ? on * c.a : c.a);
    } else {
        float f = fract(q.y / cell);
        float l = lum(c.rgb);
        float w = saturate(l) * clamp(u.a.w * 1.2, 0.1, 1.5);
        float on = 1.0 - smoothstep(w * 0.5 - aa / cell, w * 0.5 + aa / cell, abs(f - 0.5));
        res = float4(c.rgb * on, u.b.x > 0.5 ? on * c.a : c.a);
    }
    return finish(o, res, u.mixAmt);
}

// ===== 輪郭ネオン =====
// a = 強さ, 太さ(px 1080p), 色の付け方(0 元の色 1 色 2 虹), 元の絵 / b.x = 光の広がり, b.y = しきい値
static float edgeAt(texture2d<float> t, sampler s, float2 uv, float2 d) {
    float tl = lum(t.sample(s, uv + float2(-d.x, -d.y)).rgb), tc = lum(t.sample(s, uv + float2(0, -d.y)).rgb);
    float tr = lum(t.sample(s, uv + float2(d.x, -d.y)).rgb), ml = lum(t.sample(s, uv + float2(-d.x, 0)).rgb);
    float mr = lum(t.sample(s, uv + float2(d.x, 0)).rgb), bl = lum(t.sample(s, uv + float2(-d.x, d.y)).rgb);
    float bc = lum(t.sample(s, uv + float2(0, d.y)).rgb), br = lum(t.sample(s, uv + float2(d.x, d.y)).rgb);
    float gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
    float gy = (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr);
    return length(float2(gx, gy));
}
fragment float4 mf_edge(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float k = u.size.y / 1080.0;
    float2 px = 1.0 / u.size;
    float w = max(u.a.y * k, 0.5);
    float e = edgeAt(t, s, in.uv, px * w);
    // 光の広がり：太く取った輪郭を薄く足す
    float g = 0.0;
    if (u.b.x > 0.001) {
        float2 d2 = px * w * (2.0 + u.b.x * 6.0);
        g = edgeAt(t, s, in.uv, d2) * u.b.x * 0.6;
    }
    float th = u.b.y;
    float v = saturate((e - th) * u.a.x * 2.0) + saturate((g - th) * u.a.x);
    float4 o = t.sample(s, in.uv);
    int cm = int(u.a.z + 0.5);
    float3 col = cm == 0 ? saturate(o.rgb / max(lum(o.rgb), 0.15) * 0.8)
               : (cm == 1 ? u.color.rgb : hue(in.uv.x * 0.6 + in.uv.y * 0.4 + u.time * 0.1));
    float3 c = o.rgb * u.a.w + col * v;
    return finish(o, float4(c, max(o.a * u.a.w, saturate(v))), u.mixAmt);
}

// ===== ズームぼかし =====
// a = 強さ, 中心x, 中心y, 回るぼかし / b.x = なめらかさ（数）
fragment float4 mf_zoom(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 c = float2(u.a.y, u.a.z);
    float2 d = in.uv - c;
    int n = int(clamp(u.b.x, 8.0, 48.0));
    float4 acc = 0.0; float ws = 0.0;
    float j = h2(in.pos.xy) / float(n);
    for (int i = 0; i < n; i++) {
        float f = (float(i) / float(n) + j);
        float sc = 1.0 - u.a.x * 0.5 * f;
        float an = u.a.w * 0.3 * f;
        float2 r = float2(d.x * cos(an) - d.y * sin(an), d.x * sin(an) + d.y * cos(an));
        float w = 1.0 - f * 0.5;
        acc += t.sample(s, c + r * sc) * w;
        ws += w;
    }
    float4 o = t.sample(s, in.uv);
    return finish(o, acc / ws, u.mixAmt);
}

// ===== ピクセルソート：明るさがしきい値の間で続いている所（帯）ごとに、明るさの順に並べ直す =====
// a = 下のしきい値, 上のしきい値, 向き(0 横 1 縦), 逆 / b.x = 帯のいちばん長いところ(この大きさでの px)
fragment float4 mf_sortInit(VO in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return t.sample(s, in.uv);
}
fragment float4 mf_sortSpan(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    int2 p = int2(in.pos.xy);
    int2 sz = int2(t.get_width(), t.get_height());
    int2 dir = u.a.z > 0.5 ? int2(0, 1) : int2(1, 0);
    float4 me = t.read(uint2(p));
    float lo = u.a.x, hi = u.a.y;
    float lm = lum(me.rgb);
    if (lm < lo || lm > hi) return me;
    int L = max(int(u.b.x), 2);
    // 帯の端を探す（長いときは飛ばし飛ばし）
    int st = max(1, L / 96);
    int back = 0, fwd = 0;
    for (int i = st; i <= L; i += st) {
        int2 q = p - dir * i;
        if (q.x < 0 || q.y < 0) break;
        float l = lum(t.read(uint2(q)).rgb);
        if (l < lo || l > hi) break;
        back = i;
    }
    for (int i = st; i <= L; i += st) {
        int2 q = p + dir * i;
        if (q.x >= sz.x || q.y >= sz.y) break;
        float l = lum(t.read(uint2(q)).rgb);
        if (l < lo || l > hi) break;
        fwd = i;
    }
    int n = back + fwd + 1;
    if (n < 3) return me;
    // 帯の中の明るさの分かれ方（16 に分けて、色も足しておく）
    float cnt[16]; float3 cs[16];
    for (int b = 0; b < 16; b++) { cnt[b] = 0.0; cs[b] = 0.0; }
    int step = max(1, n / 64);
    float total = 0.0;
    for (int k = 0; k < n; k += step) {
        int2 q = clamp(p + dir * (k - back), int2(0), sz - 1);
        float4 c = t.read(uint2(q));
        int bi = clamp(int((lum(c.rgb) - lo) / max(hi - lo, 1e-4) * 16.0), 0, 15);
        cnt[bi] += 1.0; cs[bi] += c.rgb; total += 1.0;
    }
    // 帯の中の自分の場所 → その場所に来る明るさの段
    float tt = (float(back) + 0.5) / float(n);
    if (u.a.w > 0.5) tt = 1.0 - tt;
    float acc = 0.0;
    for (int b = 0; b < 16; b++) {
        acc += cnt[b];
        if (acc >= tt * total && cnt[b] > 0.0) return float4(cs[b] / cnt[b], me.a);
    }
    return me;
}
fragment float4 mf_sortOut(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]],
                           texture2d<float> sorted [[texture(1)]]) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    constexpr sampler sl(filter::linear, address::clamp_to_edge);
    return finish(t.sample(sl, in.uv), sorted.sample(s, in.uv), u.mixAmt);
}

// ===== データモッシュ風 =====
// 動き：前のコマと今のコマの、かたまりごとのずれ（小さくした絵で探す）。a.x = かたまりの大きさ(px)
fragment float4 mf_flow(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> cur [[texture(0)]],
                        texture2d<float> prev [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 px = 1.0 / u.size;
    float B = max(u.a.x, 4.0);
    float2 base = in.uv;
    float best = 1e9; float2 bd = 0.0;
    const int R = 4;
    for (int y = -R; y <= R; y++) {
        for (int x = -R; x <= R; x++) {
            float2 d = float2(x, y) * px * B * 0.5;
            float sad = 0.0;
            for (int j = 0; j < 3; j++) {
                for (int i = 0; i < 3; i++) {
                    float2 o = (float2(i, j) - 1.0) * px * B * 0.33;
                    sad += abs(lum(cur.sample(s, base + o).rgb) - lum(prev.sample(s, base + o + d).rgb));
                }
            }
            sad += length(float2(x, y)) * 0.002;
            if (sad < best) { best = sad; bd = d; }
        }
    }
    return float4(-bd, 0.0, 1.0);
}
// 引きずる：held を動きの向きに運び、今の絵を refresh だけ混ぜる。
// a = かたまり(px), 動きの強さ, 今の絵を混ぜる量(0〜1), 色にじみ / b.x = 拍でリセット中(1)
fragment float4 mf_mosh(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> cur [[texture(0)]],
                        texture2d<float> held [[texture(1)]], texture2d<float> flow [[texture(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    float B = max(u.a.x, 4.0);
    float2 cellUV = (floor(in.pos.xy / B) + 0.5) * B / u.size;
    float2 f = flow.sample(sn, cellUV).xy * u.a.y;
    float4 h = held.sample(s, in.uv - f);
    // 色にじみ：動きの分だけ色の向きをずらす
    float4 hr = held.sample(s, in.uv - f * (1.0 + u.a.w));
    h.r = hr.r;
    float4 c = cur.sample(s, in.uv);
    float m = saturate(u.a.z + u.b.x);
    // 覚えている絵が壊れていたら（作ったばかりなど）、今の絵にする
    if (any(isnan(h)) || any(isinf(h)) || m >= 0.999) return c;
    return mix(h, c, m);
}
fragment float4 mf_moshOut(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]],
                           texture2d<float> held [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return finish(t.sample(s, in.uv), held.sample(s, in.uv), u.mixAmt);
}

// ===== 文字モザイク =====
// a = 大きさ(px 1080p), 文字の数, 色の付け方(0 元の色 1 色 2 緑の画面), コントラスト / b.x = 背景の明るさ, b.y = 並びの番号
fragment float4 mf_ascii(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]],
                         texture2d<float> atlas [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float k = u.size.y / 1080.0;
    float ch = max(u.a.x * k, 4.0);
    float cw = ch * 0.62;
    float2 px = in.uv * u.size;
    float2 cid = floor(px / float2(cw, ch));
    float2 cuv = (cid + 0.5) * float2(cw, ch) / u.size;
    float4 c = (t.sample(s, cuv) + t.sample(s, cuv + float2(cw, 0) * 0.25 / u.size) + t.sample(s, cuv - float2(cw, 0) * 0.25 / u.size)
                + t.sample(s, cuv + float2(0, ch) * 0.25 / u.size)) * 0.25;
    float l = saturate((lum(c.rgb) - 0.5) * u.a.w + 0.5) * c.a;
    int n = max(int(u.a.y + 0.5), 2);
    int gi = min(int(l * float(n)), n - 1);
    float2 f = fract(px / float2(cw, ch));
    // 字の絵：横に 16 字、縦に並びの数だけ
    float2 auv = float2((float(gi) + f.x) / 16.0, (u.b.y + f.y) / 4.0);
    float g = atlas.sample(s, auv).r;
    int cm = int(u.a.z + 0.5);
    float3 col = cm == 0 ? saturate(c.rgb / max(lum(c.rgb), 0.2)) : (cm == 1 ? u.color.rgb : float3(0.25, 1.0, 0.45));
    float4 o = t.sample(s, in.uv);
    float3 bg = (cm == 2 ? float3(0.0, 0.06, 0.02) : float3(0.0)) * 1.0 + col * u.b.x * 0.15;
    float3 rgb = mix(bg, col, g);
    float a = max(g, u.b.x > 0.001 || cm == 2 ? 1.0 : 0.0) * max(c.a, cm == 2 ? 1.0 : 0.0);
    return finish(o, float4(rgb * max(a, g), max(a, g)), u.mixAmt);
}

// ===== ディザ =====
// a = 色数, 色の組(0 白黒 1 ゲーム機の緑 2 4 色の昔のパソコン 3 元の色を減らす 4 パレット), 点の大きさ(px), 並び(0 規則 1 ざらざら)
// b.x = コントラスト
constant float bayer8[64] = {
    0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
    3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25, 15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21 };
fragment float4 mf_dither(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float k = u.size.y / 1080.0;
    float ps = max(floor(u.a.z * k + 0.5), 1.0);
    float2 cell = floor(in.pos.xy / ps);
    float2 cuv = (cell + 0.5) * ps / u.size;
    float4 c = t.sample(s, cuv);
    float3 rgb = saturate((c.rgb - 0.5) * u.b.x + 0.5);
    int2 bi = int2(fmod(cell, 8.0));
    float th = u.a.w > 0.5 ? h2(cell + floor(u.time * 12.0)) : (bayer8[bi.y * 8 + bi.x] + 0.5) / 64.0;
    int n = max(int(u.a.x + 0.5), 2);
    int set = int(u.a.y + 0.5);
    float3 outc;
    if (set == 3) {
        outc = floor(rgb * float(n - 1) + th) / float(n - 1);
    } else {
        float l = lum(rgb);
        float q = saturate(floor(l * float(n - 1) + th) / float(n - 1));
        if (set == 0) outc = float3(q);
        else if (set == 1) outc = mix(float3(0.06, 0.22, 0.06), float3(0.61, 0.74, 0.06), q);
        else if (set == 2) {
            // 黒・水色・桃色・白
            int i = min(int(q * 3.0 + 0.5), 3);
            outc = i == 0 ? float3(0.0) : (i == 1 ? float3(0.33, 1.0, 1.0) : (i == 2 ? float3(1.0, 0.33, 1.0) : float3(1.0)));
        } else outc = pal(u.pal, u.palCount, q);
    }
    float4 o = t.sample(s, in.uv);
    return finish(o, float4(outc * c.a, c.a), u.mixAmt);
}

// ===== ガラス片 =====
// a = 片の数, ずれ, 動く速さ, 縁の線 / b = 屈折, 色ずれ, 縁の明るさ
fragment float4 mf_glass(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::mirrored_repeat);
    float A = u.size.x / max(u.size.y, 1.0);
    float n = max(u.a.x, 1.0);
    float sc = sqrt(n);
    float2 p = in.uv * float2(A, 1.0) * sc;
    float2 ip = floor(p), fp = fract(p);
    float d1 = 9.0, d2 = 9.0; float2 bestId = 0.0; float2 bestOff = 0.0;
    float T = u.time * u.a.z;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 g = float2(x, y);
            float2 o = h22(ip + g);
            o = 0.5 + 0.4 * sin(T + 6.2831 * o);
            float2 r = g + o - fp;
            float d = dot(r, r);
            if (d < d1) { d2 = d1; d1 = d; bestId = ip + g; bestOff = r; }
            else if (d < d2) { d2 = d; }
        }
    }
    float2 rnd = h22(bestId * 1.7 + 3.1) - 0.5;
    float2 shift = rnd * u.a.y * 0.15 + bestOff / sc / float2(A, 1.0) * u.b.x * 0.3;
    float2 uv = in.uv + shift;
    float2 cs = float2(u.b.y * 0.006, 0.0);
    float4 c = float4(t.sample(s, uv + cs).r, t.sample(s, uv).g, t.sample(s, uv - cs).b, t.sample(s, uv).a);
    float edge = sqrt(d2) - sqrt(d1);
    float line = 1.0 - smoothstep(0.0, 0.03 + u.a.w * 0.06, edge);
    c.rgb = mix(c.rgb, float3(u.b.z), line * u.a.w);
    float4 o = t.sample(s, in.uv);
    return finish(o, c, u.mixAmt);
}
"""

struct MoreFXUniforms {
    var a = SIMD4<Float>.zero, b = SIMD4<Float>.zero, c = SIMD4<Float>.zero, d = SIMD4<Float>.zero
    var color = SIMD4<Float>(1, 1, 1, 1)
    var pal: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
              SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var size = SIMD2<Float>.zero
    var time: Float = 0
    var mixAmt: Float = 1
    var palCount: Int32 = 1

    mutating func setColors(_ e: Effect) {
        color = e.color.simd
        let p = (e.palette.isEmpty ? [RGB.black, RGB.white] : Array(e.palette.prefix(8))).map(\.simd)
        func at(_ i: Int) -> SIMD4<Float> { i < p.count ? p[i] : p[p.count - 1] }
        pal = (at(0), at(1), at(2), at(3), at(4), at(5), at(6), at(7))
        palCount = Int32(p.count)
    }
}

/// 追加のエフェクトを描く（1 回描くもの・何回か重ねて描くもの）
final class MoreFXRenderer {
    static let shared = MoreFXRenderer()
    let device = MetalContext.shared.device
    private var pipes: [String: MTLRenderPipelineState] = [:]
    private var temps: [String: MTLTexture] = [:]
    /// 文字モザイクの字の絵（横に 16 字 × 縦に 4 組）
    private(set) lazy var asciiAtlas: MTLTexture? = Self.makeAtlas(device: device)
    static let asciiSets = [" .:-=+*#%@", " ░▒▓█", " 01", " ･ｰｼﾂﾐﾊｦﾀﾈﾎﾗﾘﾑﾒﾜ"]

    private init() {
        let lib = try! device.makeLibrary(source: moreFXSource, options: nil)
        func r(_ f: String, _ fmt: MTLPixelFormat = .bgra8Unorm) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "mf_full")
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = fmt
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        for f in ["mf_bloomOut", "mf_kaleido", "mf_rgb", "mf_pixel", "mf_edge", "mf_zoom", "mf_sortOut", "mf_moshOut",
                  "mf_ascii", "mf_dither", "mf_glass"] { pipes[f] = r(f) }
        for f in ["mf_bright", "mf_blur", "mf_sortInit", "mf_sortSpan", "mf_flow", "mf_mosh"] { pipes[f + "16"] = r(f, .rgba16Float) }
    }

    func pipe(_ name: String) -> MTLRenderPipelineState { pipes[name]! }

    /// 作業用の絵（名前と大きさごとに 1 枚）
    func temp(_ name: String, _ w: Int, _ h: Int) -> MTLTexture? {
        let key = "\(name)-\(w)x\(h)"
        if let t = temps[key] { return t }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(w, 1), height: max(h, 1), mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        let t = device.makeTexture(descriptor: td)
        // 大きさが変わったら前のものは捨てる
        temps = temps.filter { !$0.key.hasPrefix(name + "-") }
        temps[key] = t
        return t
    }

    func pass(_ dst: MTLTexture, _ pipe: MTLRenderPipelineState, cb: MTLCommandBuffer, _ setup: (MTLRenderCommandEncoder) -> Void) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        e.setRenderPipelineState(pipe)
        setup(e)
        e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        e.endEncoding()
    }

    func uniforms(_ e: Effect, dst: MTLTexture, now: Double, stack: EffectStack, mixAmt: Float) -> MoreFXUniforms {
        var u = MoreFXUniforms()
        u.size = SIMD2(Float(dst.width), Float(dst.height))
        u.time = Float(max(now - stack.origin, 0).truncatingRemainder(dividingBy: 10000))
        u.mixAmt = mixAmt
        u.setColors(e)
        return u
    }

    /// 1 回描くもの
    func render(_ e: Effect, input: MTLTexture, into dst: MTLTexture, now: Double, stack: EffectStack, mixAmt: Float, cb: MTLCommandBuffer) {
        func v(_ i: Int) -> Float { i < e.kind.params.count ? Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) : 0 }
        var u = uniforms(e, dst: dst, now: now, stack: stack, mixAmt: mixAmt)
        let deg = Float.pi / 180
        let t = u.time
        var name = ""
        var extra: MTLTexture?
        switch e.kind {
        case .kaleidoscope:
            name = "mf_kaleido"
            u.a = SIMD4(v(0), (v(2) + v(1) * t) * deg, v(5), v(7))
            u.b = SIMD4(v(3), v(4), v(6), (v(8) + v(9) * t) * deg)
        case .rgbSplit:
            name = "mf_rgb"
            u.a = SIMD4(v(0), v(1) * deg, v(2).rounded(), v(3))
            u.b = SIMD4(v(4), 0, 0, 0)
        case .pixelate:
            name = "mf_pixel"
            u.a = SIMD4(v(0).rounded(), v(1), v(2) * deg, v(3))
            u.b = SIMD4(v(4), 0, 0, 0)
        case .edgeNeon:
            name = "mf_edge"
            u.a = SIMD4(v(0), v(1), v(2).rounded(), v(3))
            u.b = SIMD4(v(4), v(5), 0, 0)
        case .zoomBlur:
            name = "mf_zoom"
            u.a = SIMD4(v(0), v(1), v(2), v(3))
            u.b = SIMD4(v(4), 0, 0, 0)
        case .ascii:
            name = "mf_ascii"
            let set = Int(v(1).rounded())
            let n = Self.asciiSets[min(max(set, 0), Self.asciiSets.count - 1)].count
            u.a = SIMD4(v(0), Float(n), v(2).rounded(), v(3))
            u.b = SIMD4(v(4), Float(min(max(set, 0), 3)), 0, 0)
            extra = asciiAtlas
        case .dither:
            name = "mf_dither"
            u.a = SIMD4(v(0).rounded(), v(1).rounded(), v(2), v(3).rounded())
            u.b = SIMD4(v(4), 0, 0, 0)
        case .voronoiGlass:
            name = "mf_glass"
            u.a = SIMD4(v(0), v(1), v(2), v(3))
            u.b = SIMD4(v(4), v(5), v(6), 0)
        default: return
        }
        pass(dst, pipe(name), cb: cb) { enc in
            enc.setFragmentBytes(&u, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
            enc.setFragmentTexture(input, index: 0)
            if let extra { enc.setFragmentTexture(extra, index: 1) }
        }
    }

    /// 光のにじみ：明るい所を 1/4 と 1/8 に縮めて、縦横にぼかして重ねる
    func bloom(_ e: Effect, input: MTLTexture, into dst: MTLTexture, now: Double, stack: EffectStack, mixAmt: Float, cb: MTLCommandBuffer) {
        func v(_ i: Int) -> Float { Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) }
        var u = uniforms(e, dst: dst, now: now, stack: stack, mixAmt: mixAmt)
        let W = input.width, H = input.height
        guard let q1 = temp("bloomA", W / 4, H / 4), let q1b = temp("bloomB", W / 4, H / 4),
              let q2 = temp("bloomC", W / 8, H / 8), let q2b = temp("bloomD", W / 8, H / 8) else { return }
        u.a = SIMD4(v(0), v(1), v(2), v(4))
        let tint = v(3)
        let c = e.color.simd
        u.c = SIMD4(1 + (c.x - 1) * tint, 1 + (c.y - 1) * tint, 1 + (c.z - 1) * tint, 0)
        let spread = max(v(5), 0.05)
        pass(q1, pipe("mf_bright16"), cb: cb) { enc in
            enc.setFragmentBytes(&u, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
            enc.setFragmentTexture(input, index: 0)
        }
        func blur(_ src: MTLTexture, _ tmp: MTLTexture, _ out: MTLTexture, _ amount: Float) {
            var h = u; h.b = SIMD4(1 / Float(src.width), 0, amount, 0)
            pass(tmp, pipe("mf_blur16"), cb: cb) { enc in
                enc.setFragmentBytes(&h, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
                enc.setFragmentTexture(src, index: 0)
            }
            var vv = u; vv.b = SIMD4(0, 1 / Float(src.height), amount, 0)
            pass(out, pipe("mf_blur16"), cb: cb) { enc in
                enc.setFragmentBytes(&vv, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
                enc.setFragmentTexture(tmp, index: 0)
            }
        }
        blur(q1, q1b, q1, 1 + spread * 2)
        // 1/8：1/4 の結果をさらに広く
        pass(q2, pipe("mf_blur16"), cb: cb) { enc in
            var z = u; z.b = SIMD4(0, 0, 0, 0)
            enc.setFragmentBytes(&z, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
            enc.setFragmentTexture(q1, index: 0)
        }
        blur(q2, q2b, q2, 1 + spread * 4)
        pass(dst, pipe("mf_bloomOut"), cb: cb) { enc in
            enc.setFragmentBytes(&u, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
            enc.setFragmentTexture(input, index: 0)
            enc.setFragmentTexture(q1, index: 1)
            enc.setFragmentTexture(q2, index: 2)
        }
    }

    /// ピクセルソート：（小さくした絵で）帯ごとに明るさの順に並べ直す
    func pixelSort(_ e: Effect, input: MTLTexture, into dst: MTLTexture, now: Double, stack: EffectStack, mixAmt: Float, cb: MTLCommandBuffer) {
        func v(_ i: Int) -> Float { Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) }
        var u = uniforms(e, dst: dst, now: now, stack: stack, mixAmt: mixAmt)
        let div = [1, 2, 4][min(max(Int(v(5).rounded()), 0), 2)]
        let W = max(input.width / div, 1), H = max(input.height / div, 1)
        guard let a = temp("sortA", W, H), let b = temp("sortB", W, H) else { return }
        u.a = SIMD4(min(v(0), v(1)), max(v(0), v(1)), v(3).rounded(), v(4))
        // 流れる長さは 1080p での px。小さくした分だけ短く
        u.b = SIMD4(v(2) * Float(input.height) / 1080 / Float(div), 0, 0, 0)
        pass(a, pipe("mf_sortInit16"), cb: cb) { enc in enc.setFragmentTexture(input, index: 0) }
        pass(b, pipe("mf_sortSpan16"), cb: cb) { enc in
            enc.setFragmentBytes(&u, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
            enc.setFragmentTexture(a, index: 0)
        }
        pass(dst, pipe("mf_sortOut"), cb: cb) { enc in
            enc.setFragmentBytes(&u, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
            enc.setFragmentTexture(input, index: 0)
            enc.setFragmentTexture(b, index: 1)
        }
    }

    /// 字の絵を作る（白い字・黒い地。横 16 字 × 縦 4 組）
    static func makeAtlas(device: MTLDevice) -> MTLTexture? {
        let cw = 40, ch = 64
        let W = cw * 16, H = ch * 4
        var px = [UInt8](repeating: 0, count: W * H)
        guard let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        for (row, set) in asciiSets.enumerated() {
            for (i, chr) in set.enumerated() where i < 16 {
                let font = NSFont.monospacedSystemFont(ofSize: CGFloat(ch) * 0.78, weight: .bold)
                let s = NSAttributedString(string: String(chr), attributes: [.font: font, .foregroundColor: NSColor.white])
                let line = CTLineCreateWithAttributedString(s)
                // 大きさは、書く位置を 0 にしてから測る（前の字の位置が混ざらないように）
                ctx.textPosition = .zero
                let bounds = CTLineGetImageBounds(line, ctx)
                let x = CGFloat(i * cw) + (CGFloat(cw) - bounds.width) / 2 - bounds.minX
                // 上の段が 0 になるように（CG は下が原点）
                let y = CGFloat(H - (row + 1) * ch) + (CGFloat(ch) - bounds.height) / 2 - bounds.minY
                ctx.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, ctx)
            }
        }
        // 上下を返す（CG の並びは上の行から）→ 絵の 1 行目が上
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: td) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: px, bytesPerRow: W)
        return t
    }
}

/// データモッシュ風：前のコマの動きで、覚えている絵を運び続ける（今の絵は少しずつしか混ぜない）
final class MoshSim {
    private var held: [MTLTexture] = []
    private var prev: MTLTexture?
    private var flow: MTLTexture?
    private var cur = 0
    private var fresh = true
    private var lastBeat = -1.0

    func render(_ e: Effect, input: MTLTexture, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack,
                mixAmt: Float, cb: MTLCommandBuffer) {
        let r = MoreFXRenderer.shared
        func v(_ i: Int) -> Float { Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) }
        let W = input.width, H = input.height
        if held.count != 2 || held[0].width != W || held[0].height != H {
            held = (0..<2).compactMap { _ in
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: W, height: H, mipmapped: false)
                td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
                return r.device.makeTexture(descriptor: td)
            }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: W / 4, height: H / 4, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
            prev = r.device.makeTexture(descriptor: td)
            flow = nil
            fresh = true
        }
        guard held.count == 2, let prev else { return }
        if fresh {
            for t in held + [prev] {
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = t
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                rpd.colorAttachments[0].storeAction = .store
                cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
            }
        }
        let block = max(v(0), 4)
        let fw = max(Int(Float(W) / block), 1), fh = max(Int(Float(H) / block), 1)
        if flow == nil || flow!.width != fw || flow!.height != fh {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: fw, height: fh, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
            flow = r.device.makeTexture(descriptor: td)
        }
        guard let flow else { return }
        var u = r.uniforms(e, dst: dst, now: now, stack: stack, mixAmt: mixAmt)
        // 拍でリセット：拍の頭で今の絵に戻す
        var reset: Float = fresh ? 1 : 0
        if v(4) > 0.5 {
            let b = floor(stack.beat.beat(at: now) / max(Double(v(5)), 1))
            if b != lastBeat { if lastBeat >= 0 { reset = 1 }; lastBeat = b }
        }
        if dt > 0 || fresh {
            u.size = SIMD2(Float(W), Float(H))
            u.a = SIMD4(block, 0, 0, 0)
            r.pass(flow, r.pipe("mf_flow16"), cb: cb) { enc in
                var fu = u; fu.size = SIMD2(Float(W), Float(H))
                enc.setFragmentBytes(&fu, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
                enc.setFragmentTexture(input, index: 0)
                enc.setFragmentTexture(fresh ? input : prev, index: 1)
            }
            let next = 1 - cur
            u.a = SIMD4(block, v(1), pow(max(v(2), 0), 1.5), v(3))
            u.b = SIMD4(reset, 0, 0, 0)
            r.pass(held[next], r.pipe("mf_mosh16"), cb: cb) { enc in
                enc.setFragmentBytes(&u, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
                enc.setFragmentTexture(input, index: 0)
                enc.setFragmentTexture(held[cur], index: 1)
                enc.setFragmentTexture(flow, index: 2)
            }
            cur = next
            // 今の絵を、次のコマの「前の絵」として小さく覚える
            r.pass(prev, r.pipe("mf_sortInit16"), cb: cb) { enc in enc.setFragmentTexture(input, index: 0) }
            fresh = false
        }
        var o = u; o.mixAmt = mixAmt
        r.pass(dst, r.pipe("mf_moshOut"), cb: cb) { enc in
            enc.setFragmentBytes(&o, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
            enc.setFragmentTexture(input, index: 0)
            enc.setFragmentTexture(held[cur], index: 1)
        }
    }
}

extension EffectProcessor {
    /// 追加のジェネレーター（MoreGenerators.swift）
    func drawMoreGenerator(_ e: Effect, key: String, into dst: MTLTexture, stack: EffectStack, now: Double, cb: MTLCommandBuffer) {
        MoreGenerators.draw(e, key: key, life: life, into: dst, stack: stack, now: now, cb: cb)
    }
}
