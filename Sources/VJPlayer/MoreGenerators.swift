import AppKit
import CoreText
import Metal
import QuartzCore
import simd

// 追加のジェネレーター：
//   時刻だけで描くもの：レーザーショー・シンセウェイブの地形・メタボール・星空ワープ・フラクタル
//   前のコマを覚えるもの：反応拡散・ロゴを粒に・水面の波紋・稲妻・育つ線

private let moreGenSource = """
#include <metal_stdlib>
using namespace metal;

struct VO { float4 pos [[position]]; float2 uv; };
vertex VO mg_full(uint vid [[vertex_id]]) {
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
static float fbm(float2 p) { float s = 0.0, a = 0.5; for (int i = 0; i < 5; i++) { s += a * vn(p); p *= 2.03; a *= 0.5; } return s; }
static float3 hue(float h) { float3 k = abs(fract(float3(h) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0); return saturate(k - 1.0); }
static float lum(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

struct MU { float4 a, b, c, d; float4 color; float4 pal[8]; float2 size; float time; float mixAmt; int palCount; };
static float3 pal(constant MU& u, float x) {
    int n = max(u.palCount, 1);
    if (n == 1) return u.pal[0].rgb;
    float t = saturate(x) * float(n - 1);
    int i = min(int(floor(t)), n - 2);
    return mix(u.pal[i].rgb, u.pal[i + 1].rgb, t - float(i));
}
static float3 palWrap(constant MU& u, float x) {
    int n = max(u.palCount, 1);
    if (n == 1) return u.pal[0].rgb;
    float t = fract(x) * float(n);
    int i = int(floor(t)) % n;
    return mix(u.pal[i].rgb, u.pal[(i + 1) % n].rgb, fract(t));
}

// ===== レーザーショー =====
// a = 本数, 扇の広がり(rad), 振れる速さ, 回り(rad) / b = 出る所, 太さ(px 1080p), もや, 明るさ / c = 色の付け方, 長さ, 点滅(0〜1)
fragment float4 mg_laser(VO in [[stage_in]], constant MU& u [[buffer(0)]]) {
    float A = u.size.x / max(u.size.y, 1.0);
    float2 p = float2(in.uv.x * A, in.uv.y);
    int n = clamp(int(u.a.x + 0.5), 1, 32);
    int om = int(u.b.x + 0.5);
    float w = max(u.b.y, 0.3) / 1080.0;
    float T = u.time;
    float3 acc = 0.0;
    int origins = om == 3 ? 2 : 1;
    for (int o = 0; o < origins; o++) {
        float2 org; float base;
        if (om == 0) { org = float2(A * 0.5, 1.03); base = -1.5708; }
        else if (om == 1) { org = float2(A * 0.5, -0.03); base = 1.5708; }
        else if (om == 2) { org = float2(A * 0.5, 0.5); base = -1.5708; }
        else { org = o == 0 ? float2(-0.03, 0.55) : float2(A + 0.03, 0.55); base = o == 0 ? -0.2 : 3.3416; }
        for (int i = 0; i < n; i++) {
            float f = n > 1 ? float(i) / float(n - 1) - 0.5 : 0.0;
            float sw = sin(T * u.a.z * 2.1 + float(i) * 0.9 + float(o) * 1.7) * 0.18;
            float spread = u.a.y * (0.75 + 0.25 * cos(T * u.a.z * 0.8));
            float ang = base + f * spread + sw * u.a.y + u.a.w;
            if (om == 2) ang = base + float(i) / float(n) * 6.2831853 + u.a.w + sw;
            float2 d = float2(cos(ang), sin(ang));
            float2 r = p - org;
            float along = dot(r, d);
            float len = u.c.y * 1.2;
            if (along < 0.0 || along > len) continue;
            float dist = abs(r.x * d.y - r.y * d.x);
            float fade = (1.0 - along / len) * 0.8 + 0.2;
            float core = exp(-pow(dist / w, 2.0));
            float glow = exp(-dist / (w * 10.0)) * 0.35 + u.b.z * exp(-dist / (w * 45.0)) * 0.25;
            float v = (core + glow) * fade;
            int cm = int(u.c.x + 0.5);
            float3 col = cm == 0 ? u.color.rgb : (cm == 1 ? hue(float(i) / float(n) + T * 0.05) : pal(u, float(i) / max(float(n - 1), 1.0)));
            acc += col * v * mix(1.0, 0.8 + 0.2 * core, 0.5) + float3(core * 0.6);
        }
    }
    // もや：空気に当たった光がぼんやり
    acc *= u.b.w * u.c.z;
    float a = saturate(lum(acc) * 1.2);
    return float4(acc, a);
}

// ===== シンセウェイブの地形 =====
// a = 進んだ距離, 山の高さ, 格子の細かさ, 線の太さ(px) / b = 太陽, 視点の高さ, 霧, うねり / c.x = 色の付け方
static float terrain(float2 xz, float amp, float wob, float T) {
    float side = smoothstep(1.2, 5.0, abs(xz.x));
    float m = fbm(xz * 0.12) * 1.6 + fbm(xz * 0.35) * 0.4;
    return amp * m * m * side * 3.0 * (1.0 + wob * 0.35 * sin(T * 1.3 + xz.y * 0.05));
}
fragment float4 mg_synth(VO in [[stage_in]], constant MU& u [[buffer(0)]]) {
    float A = u.size.x / max(u.size.y, 1.0);
    float2 sp = float2((in.uv.x - 0.5) * A, 0.5 - in.uv.y);
    float camH = 0.4 + u.b.y * 1.5;
    float3 ro = float3(0.0, camH, u.a.x);
    float3 rd = normalize(float3(sp.x, sp.y - 0.12, 1.1));
    bool one = u.c.x > 0.5;
    float3 lineC = one ? u.color.rgb : pal(u, 0.0);
    float3 lineC2 = one ? u.color.rgb : pal(u, 0.34);
    float3 sunA = one ? u.color.rgb : pal(u, 1.0), sunB = one ? u.color.rgb * 0.6 : pal(u, 0.67);
    // 空
    float3 sky = mix(float3(0.02, 0.0, 0.06), lineC2 * 0.35, saturate(1.0 - sp.y * 2.2));
    float3 col = sky;
    if (u.b.x > 0.5) {
        float2 sc = float2(0.0, 0.12);
        float r = length(sp - sc);
        float R = 0.26;
        if (sp.y > 0.0 && r < R) {
            float t = (sp.y - sc.y + R) / (2.0 * R);
            float3 s = mix(sunB, sunA, saturate(t));
            // 下の方ほど太い横のすき間
            float bands = step(0.0, sin((sp.y) * 90.0 + u.time * 2.0) + (t - 0.45) * 6.0);
            col = mix(col, s * 1.3, bands * smoothstep(R, R - 0.004, r));
        }
        col += sunA * 0.25 * exp(-r * 4.0) * step(0.0, sp.y);
    }
    // 地面・山を探す
    float t = 0.05;
    bool hit = false;
    float3 pos = 0.0;
    for (int i = 0; i < 64; i++) {
        pos = ro + rd * t;
        float h = terrain(pos.xz, u.a.y, u.b.w, u.time);
        float dh = pos.y - h;
        if (dh < 0.002 * t) { hit = true; break; }
        t += max(dh * 0.55, 0.03 + t * 0.012);
        if (t > 60.0) break;
    }
    if (hit) {
        float g = max(u.a.z, 1.0) / 10.0;
        float2 q = pos.xz * g;
        float2 fw = fwidth(q);
        float2 gl = abs(fract(q - 0.5) - 0.5) / max(fw, 1e-4);
        float lw = u.a.w * 0.6;
        float line = 1.0 - smoothstep(lw, lw + 1.0, min(gl.x, gl.y));
        float h = terrain(pos.xz, u.a.y, u.b.w, u.time);
        float3 fill = float3(0.03, 0.0, 0.08);
        float3 lc = mix(lineC, lineC2, saturate(h * 0.6));
        float3 c = mix(fill, lc * 1.4, line);
        float fog = 1.0 - exp(-t * (0.02 + u.b.z * 0.08));
        col = mix(c, sky, fog);
    }
    return float4(col, 1.0);
}

// ===== メタボール =====
// a = 数, 大きさ, 進んだ量, くっつき / b = 縁の光, 色の付け方, 中の明るさ, ぼかし
fragment float4 mg_meta(VO in [[stage_in]], constant MU& u [[buffer(0)]]) {
    float A = u.size.x / max(u.size.y, 1.0);
    float2 p = float2(in.uv.x * A, in.uv.y);
    int n = clamp(int(u.a.x + 0.5), 1, 16);
    float T = u.a.z;
    float field = 0.0; float wsum = 0.0; float idx = 0.0;
    for (int i = 0; i < n; i++) {
        float fi = float(i);
        float2 c = float2(A * (0.5 + 0.38 * sin(T * (0.31 + 0.07 * fi) + fi * 1.7)),
                          0.5 + 0.36 * cos(T * (0.27 + 0.05 * fi) + fi * 2.3));
        float r = u.a.y * (0.75 + 0.5 * h1(fi * 3.1));
        float2 d = p - c;
        float f = r * r / max(dot(d, d), 1e-5);
        field += f;
        wsum += f; idx += f * fi;
    }
    field *= u.a.w;
    float soft = 0.04 + u.b.w * 0.4;
    float inside = smoothstep(1.0 - soft, 1.0 + soft, field);
    float rim = exp(-pow((field - 1.0) / (0.15 + soft), 2.0)) * u.b.x;
    float ix = idx / max(wsum, 1e-5) / max(float(n - 1), 1.0);
    int cm = int(u.b.y + 0.5);
    float3 col = cm == 0 ? u.color.rgb : (cm == 1 ? pal(u, ix) : hue(ix + u.a.z * 0.02));
    float core = saturate((field - 1.0) * 0.5);
    float3 c = col * (u.b.z + (1.0 - u.b.z) * (1.0 - core)) * inside + col * rim * 1.5 + float3(rim * 0.3);
    float a = saturate(max(inside, rim));
    return float4(c, a);
}

// ===== 星空ワープ =====
// a = 星の数, 進んだ量, 筋の長さ, 回り(rad) / b = 中心x, 中心y, 色の付け方, 星の大きさ / c.x = 奥の暗さ
fragment float4 mg_stars(VO in [[stage_in]], constant MU& u [[buffer(0)]]) {
    float A = u.size.x / max(u.size.y, 1.0);
    float2 p = (in.uv - float2(u.b.x, u.b.y)) * float2(A, 1.0);
    float r = max(length(p), 1e-4);
    float ang = atan2(p.y, p.x) + u.a.w;
    float3 acc = 0.0;
    float K = floor(40.0 * u.a.x) + 6.0;
    for (int layer = 0; layer < 3; layer++) {
        float fl = float(layer);
        float lr = log(r) * 3.0 - u.a.y * (1.0 + fl * 0.35) * 3.0 + fl * 7.13;
        float2 g = float2((ang / 6.2831853 + 0.5) * K * (1.0 + fl * 0.5), lr);
        float2 id = floor(g), f = fract(g);
        float2 sp = h22(id + fl * 11.0);
        float present = step(0.35, h2(id * 1.3 + fl));
        // 筋：流れる向き（y）にのばす
        float2 d = f - sp;
        float st = 1.0 + u.a.z * 6.0 * saturate(r * 2.0);
        d.y /= st;
        d.x *= (1.0 + fl * 0.5);
        float size = 0.035 * u.b.w * (0.4 + r * 1.6);
        float s = exp(-dot(d, d) / max(size * size, 1e-6)) * present;
        float bright = (0.4 + 0.6 * h2(id + 3.7)) * mix(1.0, saturate(r * 2.2), u.c.x);
        int cm = int(u.b.z + 0.5);
        float3 col = cm == 0 ? float3(1.0) : (cm == 1 ? hue(h2(id + 9.1)) : (cm == 2 ? pal(u, h2(id + 5.3)) : u.color.rgb));
        acc += col * s * bright;
    }
    return float4(acc, saturate(lum(acc) * 1.5));
}

// ===== フラクタル =====
// a = 種類, 深さ(0〜), 回り(rad), 回数 / b = 色の回り, 色の流れ(進んだ量), ジュリアの c.x, c.y / c = 色の付け方, 潜る所 x, y
fragment float4 mg_fractal(VO in [[stage_in]], constant MU& u [[buffer(0)]]) {
    float A = u.size.x / max(u.size.y, 1.0);
    float2 p = (in.uv - 0.5) * float2(A, 1.0);
    float ca = cos(u.a.z), sa = sin(u.a.z);
    p = float2(p.x * ca - p.y * sa, p.x * sa + p.y * ca);
    int kind = int(u.a.x + 0.5);
    float scale = 2.6 * exp(-u.a.y);
    float2 center = float2(u.c.y, u.c.z);
    float2 z, c;
    if (kind == 1) { z = p * scale * 0.9; c = float2(u.b.z, u.b.w); }
    else { z = float2(0.0); c = center + p * scale; }
    int maxI = clamp(int(u.a.w), 16, 1024);
    int i = 0;
    float m2 = 0.0;
    for (i = 0; i < maxI; i++) {
        if (kind == 2) z = abs(z);
        z = float2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        m2 = dot(z, z);
        if (m2 > 256.0) break;
    }
    if (i >= maxI) return float4(0.0, 0.0, 0.0, 1.0);
    float mu = float(i) + 1.0 - log2(log2(max(m2, 1.0001)) * 0.5);
    float x = mu / 40.0 * u.b.x + u.b.y;
    float3 col = u.c.x > 0.5 ? hue(x) : palWrap(u, x);
    return float4(col, 1.0);
}

// ===== 水面の波紋（滴は CPU が覚える） =====
// a = 波の速さ, 波の細かさ, 消えていく速さ, 光 / b = 色の付け方, 水の濃さ, 滴の数, 今の時刻
struct Drop { float4 v; };   // x, y, 落ちた時刻, 強さ
static float waveH(float2 p, constant Drop* drops, constant MU& u) {
    float h = 0.0;
    int n = int(u.b.z);
    for (int i = 0; i < n; i++) {
        float age = u.b.w - drops[i].v.z;
        if (age < 0.0) continue;
        float r = length(p - drops[i].v.xy);
        float front = age * u.a.x;
        float x = r - front;
        float env = exp(-age * u.a.z) * smoothstep(0.0, -0.03, x) * exp(x * 6.0);
        h += drops[i].v.w * sin(x * u.a.y * 6.2831) * env / (1.0 + r * 3.0);
    }
    return h;
}
fragment float4 mg_ripple(VO in [[stage_in]], constant MU& u [[buffer(0)]], constant Drop* drops [[buffer(1)]]) {
    float A = u.size.x / max(u.size.y, 1.0);
    float2 p = float2(in.uv.x * A, in.uv.y);
    float e = 1.5 / u.size.y;
    float h = waveH(p, drops, u);
    float hx = waveH(p + float2(e, 0), drops, u), hy = waveH(p + float2(0, e), drops, u);
    float3 nrm = normalize(float3(-(hx - h) / e * 0.004, -(hy - h) / e * 0.004, 1.0));
    float3 L = normalize(float3(-0.4, -0.5, 0.75));
    float spec = pow(saturate(dot(reflect(-L, nrm), float3(0, 0, 1))), 40.0) * u.a.w;
    float diff = saturate(dot(nrm, L));
    bool usePal = u.b.x > 0.5;
    float3 base = usePal ? pal(u, saturate(0.5 + h * 2.0)) : u.color.rgb;
    float3 c = base * (0.35 + 0.65 * diff) * u.b.y + float3(spec) + base * abs(h) * 1.5;
    float a = saturate(u.b.y + spec + abs(h) * 2.0);
    return float4(c, a);
}

// ===== 線を光らせて描く（稲妻・育つ線）：線分ごとに四角を描いて、真ん中からの近さで光らせる =====
struct Seg { float4 ab; float4 col; float4 info; };   // ab = 始まり xy・終わり xy（0〜1）, col = 色と明るさ, info.x = 太さ(px), info.y = 光の広がり(px)
struct SVO { float4 pos [[position]]; float2 p; float2 a; float2 b; float4 col; float w; float g; };
vertex SVO mg_seg_v(uint vid [[vertex_id]], uint iid [[instance_id]], constant Seg* segs [[buffer(0)]], constant float2& size [[buffer(1)]]) {
    Seg s = segs[iid];
    float2 a = s.ab.xy * size, b = s.ab.zw * size;
    float R = s.info.x + s.info.y * 3.0 + 2.0;
    float2 d = b - a;
    float L = max(length(d), 1e-3);
    float2 t = d / L, n = float2(-t.y, t.x);
    float2 c = float2(float(vid & 1), float(vid >> 1));
    float2 q = mix(a - t * R, b + t * R, c.x) + n * R * (c.y * 2.0 - 1.0);
    SVO o;
    o.pos = float4(q.x / size.x * 2.0 - 1.0, 1.0 - q.y / size.y * 2.0, 0.0, 1.0);
    o.p = q; o.a = a; o.b = b; o.col = s.col; o.w = s.info.x; o.g = s.info.y;
    return o;
}
fragment float4 mg_seg_f(SVO in [[stage_in]]) {
    float2 pa = in.p - in.a, ba = in.b - in.a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    float d = length(pa - ba * h);
    float core = 1.0 - smoothstep(in.w * 0.5, in.w * 0.5 + 1.0, d);
    float glow = in.g > 0.0 ? exp(-d / max(in.g, 0.5)) * 0.6 : 0.0;
    float v = (core + glow) * in.col.a;
    float3 c = in.col.rgb * v + float3(core * in.col.a * 0.5);
    return float4(c, saturate(v));
}
// 覚えた絵をだんだん消す・出す
fragment float4 mg_fade(VO in [[stage_in]], constant float& k [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::nearest);
    return t.sample(s, in.uv) * k;
}
fragment float4 mg_copy(VO in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = t.sample(s, in.uv);
    return float4(c.rgb, saturate(c.a));
}

// ===== 反応拡散（グレイ・スコット）。r = U, g = V =====
// a = F, k, 変わり続ける量, 時刻 / b = 乱す所 x, y, 半径, 量 / c = 消す所 x, y, 半径, 消す(1)
// 流れ（渦）：時間で動くむらの「回転」。模様をこれに乗せて運ぶ（止まらない）
static float2 rdFlow(float2 q, float T) {
    float e = 0.01;
    float2 o = float2(T * 0.11, -T * 0.07);
    float n = vn(q + o) + 0.5 * vn(q * 2.1 - o * 1.3 + 3.1);
    float nx = vn(q + float2(e, 0) + o) + 0.5 * vn((q + float2(e, 0)) * 2.1 - o * 1.3 + 3.1);
    float ny = vn(q + float2(0, e) + o) + 0.5 * vn((q + float2(0, e)) * 2.1 - o * 1.3 + 3.1);
    return float2(ny - n, -(nx - n)) / e;
}
// 流れに乗せて運ぶ（1 コマに 1 回）：流れてくる元の場所から読む。a.x = 運ぶ画素の数, a.w = 時刻
fragment float4 mg_rd_advect(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler sm(filter::linear, address::repeat);
    float2 fsz = float2(t.get_width(), t.get_height());
    float2 uv = in.uv;
    float A0 = fsz.x / fsz.y;
    float2 fl = rdFlow(uv * float2(A0, 1.0) * 1.6, u.a.w);
    return t.sample(sm, uv - fl * u.a.x / fsz);
}
fragment float4 mg_rd_step(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    int2 p = int2(in.pos.xy);
    int2 sz = int2(t.get_width(), t.get_height());
    float2 fsz = float2(sz);
    float2 uv = (float2(p) + 0.5) / fsz;
    float4 c4 = t.read(uint2(p));
    float2 c = c4.rg;
    float age = c4.b, rest = c4.a;
    float2 lap = -c;
    // 3×3：となり 0.2、ななめ 0.05（端はつながる）
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            if (x == 0 && y == 0) continue;
            int2 q = (p + int2(x, y) + sz) % sz;
            float w = (x == 0 || y == 0) ? 0.2 : 0.05;
            lap += t.read(uint2(q)).rg * w;
        }
    }
    float U = c.x, V = c.y;
    // 変わり続ける：場所ごとの育ち方の加減を、ゆっくり流れるむらで変える（落ち着いた形にならない）
    float2 q = uv * float2(float(sz.x) / float(sz.y), 1.0) * 2.2;
    float n1 = vn(q + float2(u.a.w * 0.031, u.a.w * 0.017)) - 0.5;
    float n2 = vn(q * 1.3 + float2(-u.a.w * 0.023, u.a.w * 0.029) + 7.7) - 0.5;
    float F = u.a.x + u.a.z * 0.016 * n1;
    float K = u.a.y + u.a.z * 0.0045 * n2;
    // 年齢：育っている所は年を取り（場所ごとに少しむら）、枯れて空いた所は若返る。
    // 寿命に近づいた所は消える力を強めて枯らす → 空いた所へ、まわりからまた育って入ってくる
    float alive = smoothstep(0.12, 0.25, V);
    float jit = 0.6 + 0.8 * vn(q * 1.7 + float2(u.a.w * 0.05, 3.3));
    if (u.d.y > 0.0) {
        if (rest > 0.0) {
            // 休み：枯れたばかりの所には、しばらく何も育たない（野火のあとの焼け野原）
            rest = max(rest - u.d.x * (2.5 - 1.5 * u.d.y), 0.0);
            V = 0.0; U = 1.0;
        } else {
            age = alive > 0.5 ? age + u.d.x * jit : max(age - u.d.x * 2.0, 0.0);
            // 寿命に近づくと弱って、寿命を過ぎると枯れる
            float dying = smoothstep(0.8, 1.0, age) * u.d.y;
            K += dying * 0.04;
            V *= 1.0 - dying * 0.08;
            if (age >= 1.0 && V < 0.15) { rest = 1.0; age = 0.0; V = 0.0; U = 1.0; }
        }
    } else {
        age = alive > 0.5 ? min(age + u.d.x * jit, 0.6) : max(age - u.d.x * 2.0, 0.0);
        rest = 0.0;
    }
    // 開いている途中の穴の中では、育たない（消える力を強める）
    float holeF = 0.0;
    if (u.c.w > 0.0 && u.c.z > 0.0) {
        float2 hd = (uv - u.c.xy) * float2(float(sz.x) / float(sz.y), 1.0) / u.c.z;
        holeF = smoothstep(1.0, 0.35, dot(hd, hd));
        K += holeF * 0.035;
    }
    float uvv = U * V * V;
    U += 1.0 * lap.x - uvv + F * (1.0 - U);
    V += 0.5 * lap.y + uvv - (F + K) * V;
    float A = float(sz.x) / float(sz.y);
    // 乱す（音のアタック）：丸く V を足す
    {
        float4 s = u.b;
        if (s.w > 0.0) {
            float2 d = (uv - s.xy) * float2(A, 1.0) / max(s.z, 1e-3);
            float r2 = dot(d, d);
            if (r2 < 1.0) { V = max(V, s.w * (1.0 - r2)); U = min(U, 1.0 - 0.5 * s.w * (1.0 - r2)); }
        }
    }
    // ときどき穴を開ける：c = 真ん中 x, y, 今の半径, 1 回で溶かす量。半径はゆっくり広がり、中の模様は少しずつ溶けて消える
    if (holeF > 0.0) {
        float f = holeF * u.c.w;
        U = mix(U, 1.0, f); V *= 1.0 - f; age *= 1.0 - f;
    }
    return float4(saturate(U), saturate(V), saturate(age), saturate(rest));
}
// 種をまく：a.x = まき方（0 真ん中 1 ばらばら 2 帯）, a.y = 乱数
fragment float4 mg_rd_seed(VO in [[stage_in]], constant MU& u [[buffer(0)]]) {
    float2 uv = in.uv;
    int m = int(u.a.x + 0.5);
    float V = 0.0;
    if (m == 0) { float2 d = (uv - 0.5) * float2(u.size.x / u.size.y, 1.0); V = step(length(d), 0.06) * 0.6; }
    else if (m == 1) { float2 g = floor(uv * float2(40.0, 24.0)); V = step(0.93, h2(g + u.a.y)) * 0.6; }
    else { V = step(abs(uv.y - 0.5), 0.02) * 0.6 + step(0.98, h2(floor(uv * 60.0) + u.a.y)) * 0.5; }
    return float4(1.0, V, 0.0, 0.0);
}
// 色を付ける：b.x = 色の付け方, b.y = 明るさ, b.z = 音で光る量（0〜）, b.w = 色のずれ（低音）/ c.x = 枯れる強さ（年を取った所を暗く・色を変える）
fragment float4 mg_rd_draw(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::repeat);
    float2 px = 1.0 / float2(t.get_width(), t.get_height());
    float3 st = t.sample(s, in.uv).rgb;
    float V = st.g, age = st.b;
    float k = smoothstep(0.08, 0.32, V);
    // 縁（V が変わる所）を光らせる。音で強く
    float gx = t.sample(s, in.uv + float2(px.x, 0)).g - t.sample(s, in.uv - float2(px.x, 0)).g;
    float gy = t.sample(s, in.uv + float2(0, px.y)).g - t.sample(s, in.uv - float2(0, px.y)).g;
    float edge = saturate(length(float2(gx, gy)) * 6.0);
    float old = smoothstep(0.45, 1.0, age) * u.c.x;
    float3 col = u.b.x > 0.5 ? pal(u, saturate(mix(V * 2.6, 1.0 - age, u.c.x * 0.7) + u.b.w)) : u.color.rgb;
    float bright = u.b.y * (1.0 + u.b.z) * (1.0 - 0.7 * old);
    float3 c = col * k * bright + col * edge * u.b.z * 1.5;
    float a = saturate(max(k * saturate(u.b.y), edge * u.b.z));
    return float4(c, a);
}

// ===== 粒（ロゴを粒に）：点を丸く光らせる =====
struct PVO { float4 pos [[position]]; float size [[point_size]]; float4 col; };
struct Part { float4 p; float4 col; };   // p = x, y（0〜1）, 大きさ(px), 明るさ
vertex PVO mg_pt_v(uint vid [[vertex_id]], constant Part* ps [[buffer(0)]]) {
    Part q = ps[vid];
    PVO o;
    o.pos = float4(q.p.x * 2.0 - 1.0, 1.0 - q.p.y * 2.0, 0.0, 1.0);
    o.size = max(q.p.z, 1.0);
    o.col = float4(q.col.rgb, q.p.w);
    return o;
}
fragment float4 mg_pt_f(PVO in [[stage_in]], float2 pc [[point_coord]]) {
    float d = length(pc - 0.5) * 2.0;
    float core = 1.0 - smoothstep(0.35, 0.6, d);
    float glow = exp(-d * 3.0) * 0.5;
    float v = (core + glow * in.col.a) * saturate(1.0 - d);
    return float4(in.col.rgb * v, saturate(v));
}
"""

/// 追加のジェネレーターの絵を描く道具
final class MoreGenRenderer {
    static let shared = MoreGenRenderer()
    let device = MetalContext.shared.device
    private var pipes: [String: MTLRenderPipelineState] = [:]

    private init() {
        let lib = try! device.makeLibrary(source: moreGenSource, options: nil)
        func r(_ v: String, _ f: String, _ fmt: MTLPixelFormat = .bgra8Unorm, additive: Bool = false) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = fmt
            if additive {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.rgbBlendOperation = .add; c.alphaBlendOperation = .add
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .one
            }
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        for f in ["mg_laser", "mg_synth", "mg_meta", "mg_stars", "mg_fractal", "mg_ripple", "mg_rd_draw", "mg_copy"] {
            pipes[f] = r("mg_full", f)
        }
        pipes["mg_rd_step16"] = r("mg_full", "mg_rd_step", .rgba16Float)
        pipes["mg_rd_advect16"] = r("mg_full", "mg_rd_advect", .rgba16Float)
        pipes["mg_rd_seed16"] = r("mg_full", "mg_rd_seed", .rgba16Float)
        pipes["mg_fade16"] = r("mg_full", "mg_fade", .rgba16Float)
        pipes["seg16"] = r("mg_seg_v", "mg_seg_f", .rgba16Float, additive: true)
        pipes["seg"] = r("mg_seg_v", "mg_seg_f", additive: true)
        pipes["pt"] = r("mg_pt_v", "mg_pt_f", additive: true)
    }

    func pipe(_ n: String) -> MTLRenderPipelineState { pipes[n]! }

    func texture(_ w: Int, _ h: Int, _ fmt: MTLPixelFormat = .rgba16Float) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: max(w, 1), height: max(h, 1), mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        return device.makeTexture(descriptor: td)
    }

    func clear(_ t: MTLTexture, cb: MTLCommandBuffer) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = t
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
    }

    func full(_ dst: MTLTexture, _ name: String, _ u: inout MoreFXUniforms, cb: MTLCommandBuffer, clear: Bool = false,
              _ setup: ((MTLRenderCommandEncoder) -> Void)? = nil) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = clear ? .clear : .dontCare
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        e.setRenderPipelineState(pipe(name))
        e.setFragmentBytes(&u, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
        setup?(e)
        e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        e.endEncoding()
    }

    /// 線分（Seg）をまとめて、光らせて足す
    struct Seg { var ab: SIMD4<Float>; var col: SIMD4<Float>; var info: SIMD4<Float> }
    func drawSegs(_ segs: [Seg], into dst: MTLTexture, pipe name: String, load: Bool, cb: MTLCommandBuffer) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = load ? .load : .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        if !segs.isEmpty, let buf = device.makeBuffer(bytes: segs, length: MemoryLayout<Seg>.stride * segs.count, options: .storageModeShared) {
            e.setRenderPipelineState(pipe(name))
            var size = SIMD2<Float>(Float(dst.width), Float(dst.height))
            e.setVertexBuffer(buf, offset: 0, index: 0)
            e.setVertexBytes(&size, length: 8, index: 1)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: segs.count)
        }
        e.endEncoding()
    }

    /// 時刻だけで描くもの
    func render(_ e: Effect, into dst: MTLTexture, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        func v(_ i: Int) -> Float { Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) }
        var u = MoreFXRenderer.shared.uniforms(e, dst: dst, now: now, stack: stack, mixAmt: 1)
        let t = u.time
        let deg = Float.pi / 180
        var name = ""
        switch e.kind {
        case .laser:
            name = "mg_laser"
            var blink: Float = 1
            if v(7) > 0.5 {
                let ph = stack.beat.beat(at: now)
                blink = Float(max(0, 1 - (ph - floor(ph)) * 2.2))
            }
            u.a = SIMD4(v(0), v(1) * deg, v(2), v(3) * deg * t)
            u.b = SIMD4(v(4).rounded(), v(5), v(6), v(9))
            u.c = SIMD4(v(8).rounded(), v(10), blink, 0)
        case .synthwave:
            name = "mg_synth"
            u.a = SIMD4(t * v(0) * 2, v(1), v(2), v(3))
            u.b = SIMD4(v(4), v(5), v(6), v(7))
            u.c = SIMD4(v(8).rounded(), 0, 0, 0)
        case .metaballs:
            name = "mg_meta"
            u.a = SIMD4(v(0), v(1), t * v(2), v(3))
            u.b = SIMD4(v(4), v(5).rounded(), v(6), v(7))
        case .starfield:
            name = "mg_stars"
            u.a = SIMD4(v(0), t * v(1) * 0.25, v(2), v(5) * deg * t)
            u.b = SIMD4(v(3), v(4), v(6).rounded(), v(7))
            u.c = SIMD4(v(8), 0, 0, 0)
        case .fractal:
            name = "mg_fractal"
            // 深さは行って帰る（float の細かさの限りまで潜ったら戻る）
            let maxDepth: Float = 8.5
            let ph = t * v(1) * 0.12
            let depth = maxDepth * (0.5 - 0.5 * cos(ph))
            let targets: [SIMD2<Float>] = [SIMD2(-0.743643887, 0.131825904), SIMD2(-0.7453, 0.1127), SIMD2(-0.761574, -0.0847596)]
            var target = targets[min(max(Int(v(9).rounded()), 0), 2)]
            if Int(v(0).rounded()) == 2 { target = SIMD2(-1.7620, -0.0280) }
            if Int(v(0).rounded()) == 1 { target = SIMD2(0, 0) }
            let ja = (v(6) + v(7) * t * 0.05) * 2 * .pi
            u.a = SIMD4(v(0).rounded(), Int(v(0).rounded()) == 1 ? depth * 0.25 : depth, v(2) * deg * t, v(3))
            u.b = SIMD4(v(4), v(5) * t * 0.2, 0.7885 * cos(ja), 0.7885 * sin(ja))
            u.c = SIMD4(v(8).rounded(), target.x, target.y, 0)
        default: return
        }
        full(dst, name, &u, cb: cb)
    }
}

// MARK: - 前のコマを覚えるもの

/// 反応拡散：U・V の 2 つの量を、ずっと育てる
final class ReactionDiffusionSim {
    private var grid: [MTLTexture] = []
    private var cur = 0
    private var time: Float = 0
    private var lastAttack: Float = 0
    private var eraseTimer: Float = 2
    /// 開いている途中の穴（真ん中・広がりきった半径・開き始めた時刻）
    private var hole: (pos: SIMD2<Float>, r: Float, start: Float)?
    /// 音で光る量（急に上がり、ゆっくり下がる）
    private(set) var glow: Float = 0
    private var seededWith: (Int, Int)?

    func render(_ e: Effect, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        let r = MoreGenRenderer.shared
        func v(_ i: Int) -> Float { Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) }
        let scale = max(v(2), 1)
        let W = max(Int(Float(dst.width) / scale), 16), H = max(Int(Float(dst.height) / scale), 16)
        let seed = Int(v(6).rounded())
        if grid.count != 2 || grid[0].width != W || grid[0].height != H || seededWith.map({ $0 != (seed, W) }) ?? true {
            grid = (0..<2).compactMap { _ in r.texture(W, H) }
            guard grid.count == 2 else { return }
            var u = MoreFXUniforms()
            u.size = SIMD2(Float(W), Float(H))
            u.a = SIMD4(Float(seed), Float.random(in: 0...100), 0, 0)
            r.full(grid[0], "mg_rd_seed16", &u, cb: cb)
            cur = 0
            seededWith = (seed, W)
        }
        guard grid.count == 2 else { return }
        let presets: [(Float, Float)] = [(0.0545, 0.062), (0.029, 0.057), (0.035, 0.065), (0.037, 0.06), (0.0367, 0.0649)]
        let (F, K) = presets[min(max(Int(v(0).rounded()), 0), presets.count - 1)]
        let ar = AudioReactive.shared
        let attack = Float(ar.level(.attack, at: now)), low = Float(ar.level(.low, at: now)), lvl = Float(ar.level(.level, at: now))
        let disturb = v(3), drift = v(7)
        // 流れ：1 秒に運ぶ画素の数（模様の大きさの画素で）
        let flow = v(9) * 24
        if dt > 0 {
            time += Float(min(dt, 0.1))
            // 低音で速く育つ
            let steps = min(max(Int((v(1) * (1 + low * disturb * 1.5)).rounded()), 1), 60)
            // アタック：立ち上がった瞬間に、ばらばらの所を大きく乱す（大きいアタックほど大きく・多く）
            var spots: [SIMD4<Float>] = []
            if disturb > 0.01, attack > 0.35, attack > lastAttack + 0.15 {
                let n = attack > 0.75 ? 2 : 1
                for _ in 0..<n {
                    spots.append(SIMD4(Float.random(in: 0.05...0.95), Float.random(in: 0.05...0.95),
                                       0.03 + 0.12 * attack * disturb, min(0.9, 0.5 + 0.5 * attack)))
                }
            }
            lastAttack = attack
            // 変わり続ける：ときどき丸く消して、まわりからまた育たせる
            // ときどき穴を開ける：真ん中から、穴が開く速さの秒数をかけて広げ、中を少しずつ溶かす（ポコっと開かない）
            var erase = SIMD4<Float>.zero
            let openSec = max(v(12), 0.3)
            if drift > 0.01 {
                eraseTimer -= Float(min(dt, 0.1))
                if hole == nil && eraseTimer <= 0 {
                    hole = (SIMD2(Float.random(in: 0.1...0.9), Float.random(in: 0.1...0.9)), 0.08 + 0.12 * drift, time)
                    eraseTimer = Float.random(in: 1.5...4) / max(drift, 0.1) + openSec
                }
            }
            if let h = hole {
                let p = (time - h.start) / openSec
                if p >= 1.15 {
                    hole = nil
                } else {
                    let q = min(max(p, 0), 1)
                    let grow = q * q * (3 - 2 * q)
                    // 1 回で溶かす量：1 秒あたりの量を、この 1 コマの回数で割る
                    let perSec: Float = 6 / openSec
                    erase = SIMD4(h.pos.x, h.pos.y, h.r * max(grow, 0.05), min(perSec * Float(min(dt, 0.1)) / Float(max(steps, 1)), 0.2))
                }
            }
            // 流れに乗せて運ぶ（1 コマに 1 回）
            if flow > 0.01 {
                var au = MoreFXUniforms()
                au.size = SIMD2(Float(W), Float(H))
                au.a = SIMD4(flow * Float(min(dt, 0.1)), 0, 0, time * (0.3 + v(9)))
                let next = 1 - cur
                let src = grid[cur]
                r.full(grid[next], "mg_rd_advect16", &au, cb: cb) { enc in enc.setFragmentTexture(src, index: 0) }
                cur = next
            }
            for i in 0..<steps {
                var u = MoreFXUniforms()
                u.size = SIMD2(Float(W), Float(H))
                u.a = SIMD4(F, K, drift, time * (0.3 + v(9)))
                // 2 つ目の乱す所は、次の回で
                if i < spots.count { u.b = spots[i] }
                u.c = erase
                // 年齢：1 コマに 1 回まとめて進める（細かく足すと、半分の細かさの数では丸められて進まない）。寿命の秒数で 1 になる
                u.d = SIMD4(i == 0 ? Float(min(dt, 0.1)) / max(v(11), 0.5) : 0, v(10), 0, 0)
                let next = 1 - cur
                let src = grid[cur]
                r.full(grid[next], "mg_rd_step16", &u, cb: cb) { enc in enc.setFragmentTexture(src, index: 0) }
                cur = next
            }
        }
        // 音で光る：今の音の大きさで明るく、縁も光る。低音で色が少しずれる
        glow = max(lvl * v(8) * 1.5, glow * Float(pow(0.02, min(max(dt, 0), 0.1))))
        var u = MoreFXRenderer.shared.uniforms(e, dst: dst, now: now, stack: stack, mixAmt: 1)
        u.b = SIMD4(v(4).rounded(), v(5), glow, low * v(8) * 0.3)
        u.c = SIMD4(v(10), 0, 0, 0)
        let g = grid[cur]
        r.full(dst, "mg_rd_draw", &u, cb: cb) { enc in enc.setFragmentTexture(g, index: 0) }
    }
}

/// 水面の波紋：滴を覚えておいて、シェーダーで波を足し合わせる
final class RippleSim {
    private var drops: [SIMD4<Float>] = []
    private var time = 0.0
    private var lastBeat = -1.0
    private var accum = 0.0

    func render(_ e: Effect, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        let r = MoreGenRenderer.shared
        func v(_ i: Int) -> Double { e.value(i, at: now, beat: stack.beat, origin: stack.origin) }
        let A = Float(dst.width) / Float(max(dst.height, 1))
        time += dt
        func drop(_ s: Float = 1) {
            drops.append(SIMD4(Float.random(in: 0.08...0.92) * A, Float.random(in: 0.08...0.92), Float(time), s * Float.random(in: 0.6...1)))
        }
        if drops.isEmpty && time < 0.5 { drop(1.2); drop(0.8) }
        if dt > 0 {
            accum += dt * v(0)
            while accum >= 1 { accum -= 1; drop() }
            if Double.random(in: 0...1) < (accum * 0.1) { drop(0.6) }
            if v(1) > 0.5 {
                let b = floor(stack.beat.beat(at: now))
                if b != lastBeat { if lastBeat >= 0 { drop(1.2) }; lastBeat = b }
            }
            if v(8) > 0.01 {
                let att = AudioReactive.shared.level(.attack, at: now)
                if att > 1 - v(8) * 0.8, Double.random(in: 0...1) < 0.3 { drop(Float(att)) }
            }
        }
        // 消えた滴は捨てる（最大 32 個）
        let life = 6 / max(v(4), 0.2)
        drops.removeAll { Double(Float(time) - $0.z) > life }
        if drops.count > 32 { drops.removeFirst(drops.count - 32) }
        var u = MoreFXRenderer.shared.uniforms(e, dst: dst, now: now, stack: stack, mixAmt: 1)
        u.a = SIMD4(Float(v(2)), Float(v(3)), Float(v(4)), Float(v(5)))
        u.b = SIMD4(Float(v(6).rounded()), Float(v(7)), Float(drops.count), Float(time))
        var buf = drops.isEmpty ? [SIMD4<Float>(0, 0, -100, 0)] : drops
        r.full(dst, "mg_ripple", &u, cb: cb) { enc in
            enc.setFragmentBytes(&buf, length: MemoryLayout<SIMD4<Float>>.stride * buf.count, index: 1)
        }
    }
}

/// 稲妻：拍・音・ときどき、枝分かれする線を作って、光らせて描く（しばらくで消える）
final class LightningSim {
    private struct Bolt { var segs: [(SIMD2<Float>, SIMD2<Float>, Float)]; var born: Double; var color: SIMD3<Float> }
    private var bolts: [Bolt] = []
    private var started = false
    private var time = 0.0
    private var lastBeat = -1.0
    private var accum = 0.0

    private func make(dir: Int, jag: Float, branch: Float, A: Float, color: SIMD3<Float>) -> Bolt {
        var a: SIMD2<Float>, b: SIMD2<Float>
        switch dir {
        case 0: a = SIMD2(Float.random(in: 0.2...0.8), -0.02); b = SIMD2(a.x + Float.random(in: -0.25...0.25), 1.02)
        case 1: a = SIMD2(-0.02, Float.random(in: 0.2...0.8)); b = SIMD2(1.02, a.y + Float.random(in: -0.3...0.3))
        case 2:
            let ang = Float.random(in: 0...(2 * .pi))
            a = SIMD2(0.5, 0.5); b = a + SIMD2(cos(ang) / A, sin(ang)) * 0.75
        default: a = SIMD2(Float.random(in: 0...1), Float.random(in: 0...1)); b = SIMD2(Float.random(in: 0...1), Float.random(in: 0...1))
        }
        var segs: [(SIMD2<Float>, SIMD2<Float>, Float)] = []
        // 中点をずらしながら細かく分ける。ときどき枝を出す
        func split(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ w: Float, _ depth: Int, _ disp: Float) {
            if depth == 0 { segs.append((p, q, w)); return }
            let d = q - p
            let n = SIMD2<Float>(-d.y, d.x)
            let m = (p + q) / 2 + n * Float.random(in: -1...1) * disp
            split(p, m, w, depth - 1, disp * 0.55)
            split(m, q, w, depth - 1, disp * 0.55)
            if depth >= 3, Float.random(in: 0...1) < branch * 0.35 {
                let len = simd_length(d) * Float.random(in: 0.3...0.7)
                let ang = atan2(d.y, d.x) + Float.random(in: -0.9...0.9)
                split(m, m + SIMD2(cos(ang), sin(ang)) * len, w * 0.55, depth - 2, disp * 0.6)
            }
        }
        split(a, b, 1, 7, 0.12 + jag * 0.3)
        return Bolt(segs: segs, born: time, color: color)
    }

    func render(_ e: Effect, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        let r = MoreGenRenderer.shared
        func v(_ i: Int) -> Double { e.value(i, at: now, beat: stack.beat, origin: stack.origin) }
        let A = Float(dst.width) / Float(max(dst.height, 1))
        time += dt
        func color() -> SIMD3<Float> {
            if v(8) > 0.5, !e.palette.isEmpty { let c = e.palette.randomElement()!; return SIMD3(Float(c.r), Float(c.g), Float(c.b)) }
            return SIMD3(Float(e.color.r), Float(e.color.g), Float(e.color.b))
        }
        func strike() { bolts.append(make(dir: Int(v(6).rounded()), jag: Float(v(3)), branch: Float(v(2)), A: A, color: color())) }
        // 置いたばかり：すぐ 1 本走らせる
        if !started { started = true; strike() }
        if dt > 0 {
            accum += dt * v(0) * (v(1) > 0.5 ? 0.3 : 1)
            while accum >= 1 { accum -= 1; strike() }
            if v(1) > 0.5 {
                let b = floor(stack.beat.beat(at: now))
                if b != lastBeat { if lastBeat >= 0 { strike() }; lastBeat = b }
            }
            if v(9) > 0.01 {
                let att = AudioReactive.shared.level(.attack, at: now)
                if att > 1 - v(9) * 0.8, Double.random(in: 0...1) < 0.25 { strike() }
            }
        }
        let life = max(v(7), 0.05)
        bolts.removeAll { time - $0.born > life }
        if bolts.count > 12 { bolts.removeFirst(bolts.count - 12) }
        let k = Float(dst.height) / 1080
        var segs: [MoreGenRenderer.Seg] = []
        for b in bolts {
            let age = Float((time - b.born) / life)
            // 走った瞬間がいちばん明るく、ちらつきながら消える
            let flick: Float = 0.7 + 0.3 * Float.random(in: 0...1)
            let bright = (1 - age) * (1 - age) * flick * 1.4
            for (p, q, w) in b.segs {
                segs.append(.init(ab: SIMD4(p.x, p.y, q.x, q.y), col: SIMD4(b.color.x, b.color.y, b.color.z, bright),
                                  info: SIMD4(Float(v(4)) * k * w, Float(v(5)) * 14 * k * w, 0, 0)))
            }
        }
        r.drawSegs(segs, into: dst, pipe: "seg", load: false, cb: cb)
    }
}

/// 育つ線：線を伸ばす先（芽）を動かして、覚えた絵に描き足していく（古い線はだんだん消える）
final class GrowthSim {
    private struct Tip { var p: SIMD2<Float>; var ang: Float; var w: Float; var age: Float; var turn: Float }
    private var tips: [Tip] = []
    private var canvas: [MTLTexture] = []
    private var cur = 0
    private var fresh = true
    private var kindNow = -1

    private func spawn(_ kind: Int, A: Float) -> Tip {
        switch kind {
        case 0:   // 回路：端から、45° ごとの向きで
            let side = Int.random(in: 0..<4)
            let p: SIMD2<Float> = side == 0 ? SIMD2(0, Float.random(in: 0...1)) : side == 1 ? SIMD2(1, Float.random(in: 0...1))
                : side == 2 ? SIMD2(Float.random(in: 0...1), 0) : SIMD2(Float.random(in: 0...1), 1)
            let base: Float = [0, .pi, .pi / 2, -.pi / 2][side]
            return Tip(p: p, ang: base, w: 1, age: 0, turn: 0)
        case 1:   // 枝：下から上へ
            return Tip(p: SIMD2(Float.random(in: 0.1...0.9), 1.01), ang: -.pi / 2 + Float.random(in: -0.3...0.3), w: 1.6, age: 0, turn: 0)
        default:  // 菌糸：どこからでも
            return Tip(p: SIMD2(Float.random(in: 0.2...0.8), Float.random(in: 0.2...0.8)), ang: Float.random(in: 0...(2 * .pi)), w: 0.8, age: 0, turn: 0)
        }
    }

    func render(_ e: Effect, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        let r = MoreGenRenderer.shared
        func v(_ i: Int) -> Double { e.value(i, at: now, beat: stack.beat, origin: stack.origin) }
        let A = Float(dst.width) / Float(max(dst.height, 1))
        let kind = Int(v(0).rounded())
        if canvas.count != 2 || canvas[0].width != dst.width || canvas[0].height != dst.height {
            canvas = (0..<2).compactMap { _ in r.texture(dst.width, dst.height) }
            fresh = true
        }
        guard canvas.count == 2 else { return }
        if fresh || kind != kindNow {
            for c in canvas { r.clear(c, cb: cb) }
            tips = []
            fresh = false
            kindNow = kind
        }
        let want = max(Int(v(1).rounded()), 1)
        let k = Float(dst.height) / 1080
        var segs: [MoreGenRenderer.Seg] = []
        if dt > 0 {
            // 長く進めるとき（置いたばかり・止めていた）は細かく分けて進める
            let n = dt > 0.1 ? min(Int(dt / 0.05), 60) : 1
            let h = min(dt / Double(n), 0.1)
            for _ in 0..<n {
            while tips.count < want { tips.append(spawn(kind, A: A)) }
            let step = Float(v(2)) * Float(h) * 0.35
            let branch = Float(v(3)), bend = Float(v(8))
            var born: [Tip] = []
            for i in tips.indices {
                var t = tips[i]
                let from = t.p
                switch kind {
                case 0:
                    // まっすぐ進み、ときどき 45° 曲がる。曲がった所に丸い点
                    if Float.random(in: 0...1) < 0.04 * (0.3 + bend) {
                        t.ang += Bool.random() ? .pi / 4 : -.pi / 4
                        segs.append(.init(ab: SIMD4(t.p.x, t.p.y, t.p.x + 0.0001, t.p.y), col: SIMD4(1, 1, 1, 1),
                                          info: SIMD4(Float(v(5)) * 3.5 * k, 0, 0, 0)))
                    }
                case 1:
                    t.turn += Float.random(in: -1...1) * 0.08 * bend
                    t.turn *= 0.92
                    t.ang += t.turn
                    t.ang += (-.pi / 2 - t.ang) * 0.01
                    t.w = max(t.w * 0.997, 0.25)
                default:
                    t.ang += Float.random(in: -1...1) * 0.35 * (0.3 + bend)
                }
                t.p += SIMD2(cos(t.ang) / A, sin(t.ang)) * step
                t.age += step
                segs.append(.init(ab: SIMD4(from.x, from.y, t.p.x, t.p.y), col: SIMD4(1, 1, 1, 1),
                                  info: SIMD4(Float(v(5)) * k * t.w, 0, 0, 0)))
                // 枝分かれ
                if Float.random(in: 0...1) < branch * 0.02 * (kind == 2 ? 3 : 1), tips.count + born.count < want * 6 {
                    var b = t
                    b.ang += (Bool.random() ? 1 : -1) * (kind == 0 ? .pi / 4 : Float.random(in: 0.3...0.9))
                    b.w *= 0.7
                    born.append(b)
                }
                tips[i] = t
            }
            tips += born
            // 画面の外へ出た・長く伸びた芽は消す（足りなければまた生まれる）
            tips.removeAll { $0.p.x < -0.05 || $0.p.x > 1.05 || $0.p.y < -0.05 || $0.p.y > 1.05 || $0.age > 3 }
            }
            // 色を付ける
            let mode = Int(v(6).rounded())
            for i in segs.indices {
                let c: SIMD3<Float>
                switch mode {
                case 0: c = SIMD3(Float(e.color.r), Float(e.color.g), Float(e.color.b))
                case 1:
                    let pc = e.palette.isEmpty ? RGB.white : e.palette[Int(abs(segs[i].ab.y * 997).truncatingRemainder(dividingBy: Float(e.palette.count)))]
                    c = SIMD3(Float(pc.r), Float(pc.g), Float(pc.b))
                default:
                    let h = Double(segs[i].ab.x * 0.6 + segs[i].ab.y * 0.4) + now * 0.05
                    let rgb = RGB.hsb(h - floor(h), 0.8, 1)
                    c = SIMD3(Float(rgb.r), Float(rgb.g), Float(rgb.b))
                }
                segs[i].col = SIMD4(c.x, c.y, c.z, 1)
                segs[i].info.y = Float(v(7)) * 6 * k
            }
            // 古い線をだんだん消してから、新しい線を描き足す
            let fade = Float(pow(1 - min(v(4), 0.99) * 0.6, min(dt, 3) * 6))
            var kf = fade
            let next = 1 - cur
            let src = canvas[cur]
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = canvas[next]
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
                enc.setRenderPipelineState(r.pipe("mg_fade16"))
                enc.setFragmentBytes(&kf, length: 4, index: 0)
                enc.setFragmentTexture(src, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.endEncoding()
            }
            r.drawSegs(segs, into: canvas[next], pipe: "seg16", load: true, cb: cb)
            cur = next
        }
        var u = MoreFXUniforms()
        let c = canvas[cur]
        r.full(dst, "mg_copy", &u, cb: cb) { enc in enc.setFragmentTexture(c, index: 0) }
    }
}

/// ロゴを粒に：画像（または文字）の形に粒を並べ、散らしては戻す
final class LogoParticleSim {
    struct Part { var p: SIMD4<Float>; var col: SIMD4<Float> }
    private var pos: [SIMD2<Float>] = []
    private var vel: [SIMD2<Float>] = []
    private var target: [SIMD2<Float>] = []
    private var tcolor: [SIMD3<Float>] = []
    private var source = ""
    private var count = 0
    private var aspect: Float = 0

    /// 形の点を作る（画像の不透明な所・文字の形）。0〜1 の正方形の中、縦横比はそのまま
    static func samplePoints(_ src: String, count: Int) -> [(SIMD2<Float>, SIMD3<Float>)] {
        var img: CGImage?
        let path = (src as NSString).expandingTildeInPath
        if !src.isEmpty, FileManager.default.fileExists(atPath: path), let ns = NSImage(contentsOfFile: path) {
            img = ns.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let W = 512, H: Int
        var px: [UInt8]
        if let img {
            H = max(Int(Double(W) * Double(img.height) / Double(max(img.width, 1))), 1)
            px = [UInt8](repeating: 0, count: W * H * 4)
            let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        } else {
            // 文字：太い字で描く
            let text = src.isEmpty ? "HALO" : src
            let font = NSFont.systemFont(ofSize: 160, weight: .black)
            let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
            let line = CTLineCreateWithAttributedString(s)
            let b = CTLineGetTypographicBounds(line, nil, nil, nil)
            let scale = min(Double(W) * 0.95 / max(b, 1), 1)
            H = 220
            px = [UInt8](repeating: 0, count: W * H * 4)
            let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.scaleBy(x: scale, y: scale)
            ctx.textPosition = CGPoint(x: (Double(W) / scale - b) / 2, y: (Double(H) / scale - 120) / 2)
            CTLineDraw(line, ctx)
        }
        // 不透明（または明るい）所を集める
        var cand: [(Int, Int)] = []
        let opaque = px.enumerated().contains { $0.offset % 4 == 3 && $0.element < 250 }
        for y in 0..<H { for x in 0..<W {
            let i = (y * W + x) * 4
            let a = Int(px[i + 3])
            let l = (Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])) / 3
            if opaque ? a > 128 : l > 128 { cand.append((x, y)) }
        } }
        guard !cand.isEmpty else { return [] }
        let span = Float(max(W, H))
        return (0..<count).map { _ in
            let (x, y) = cand.randomElement()!
            let i = (y * W + x) * 4
            let a = max(Float(px[i + 3]) / 255, 0.01)
            let c = SIMD3(Float(px[i]) / 255 / a, Float(px[i + 1]) / 255 / a, Float(px[i + 2]) / 255 / a)
            // CG は下が原点：上下を返す
            let p = SIMD2((Float(x) + Float.random(in: 0...1) - Float(W) / 2) / span, (Float(H) / 2 - Float(y) - Float.random(in: 0...1)) / span)
            return (p, c)
        }
    }

    func render(_ e: Effect, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        let r = MoreGenRenderer.shared
        func v(_ i: Int) -> Double { e.value(i, at: now, beat: stack.beat, origin: stack.origin) }
        let A = Float(dst.width) / Float(max(dst.height, 1))
        let n = min(max(Int(v(0).rounded()), 100), 30000)
        if e.text != source || n != count || pos.count != n {
            let pts = Self.samplePoints(e.text, count: n)
            target = pts.map(\.0)
            tcolor = pts.map(\.1)
            if pos.count != target.count {
                pos = target.map { _ in SIMD2(Float.random(in: -0.6...0.6), Float.random(in: -0.6...0.6)) }
                vel = Array(repeating: .zero, count: target.count)
            }
            source = e.text
            count = n
        }
        aspect = A
        guard !target.isEmpty else { r.clear(dst, cb: cb); return }
        let scatter = Float(v(2)), back = Float(v(3)), jitter = Float(v(4)), size = Float(v(5)), mode = Int(v(8).rounded())
        let steps = dt > 0.05 ? min(Int(dt / 0.02), 120) : 1
        let h = Float(min(max(dt, 0) / Double(steps), 0.05))
        if h > 0 {
            let T = Float(now)
            for _ in 0..<steps {
            for i in pos.indices {
                let goal = target[i] * size
                var acc = (goal - pos[i]) * back * 8 * (1 - scatter)
                let d = pos[i]
                let len = max(simd_length(d), 0.001)
                switch mode {
                case 0: acc += d / len * scatter * 3
                case 1: acc += SIMD2(1.4, sin(d.y * 9 + T * 2) * 0.6) * scatter * 2.5
                default: acc += SIMD2(-d.y, d.x) / len * scatter * 4 + d / len * scatter * 0.6
                }
                // ゆらぎ（粒ごとに違う向き）
                let fi = Float(i)
                acc += SIMD2(sin(T * 1.7 + fi * 0.37), cos(T * 1.3 + fi * 0.71)) * jitter * 0.6
                vel[i] = (vel[i] + acc * h) * pow(0.05, h)
                pos[i] += vel[i] * h
            }
            }
        }
        let k = Float(dst.height) / 1080
        let ps = Float(v(1)) * k * 2.5
        let glow = Float(v(7))
        let cm = Int(v(6).rounded())
        var parts = [Part](repeating: Part(p: .zero, col: .zero), count: pos.count)
        for i in pos.indices {
            let p = pos[i]
            let c: SIMD3<Float>
            switch cm {
            case 0: c = tcolor[i]
            case 1: c = SIMD3(Float(e.color.r), Float(e.color.g), Float(e.color.b))
            default:
                let pal = e.palette.isEmpty ? [RGB.white] : e.palette
                let pc = pal[i % pal.count]
                c = SIMD3(Float(pc.r), Float(pc.g), Float(pc.b))
            }
            parts[i] = Part(p: SIMD4(0.5 + p.x / A, 0.5 - p.y, ps, glow), col: SIMD4(c.x, c.y, c.z, 1))
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd),
              let buf = r.device.makeBuffer(bytes: parts, length: MemoryLayout<Part>.stride * parts.count, options: .storageModeShared) else { return }
        enc.setRenderPipelineState(r.pipe("pt"))
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: parts.count)
        enc.endEncoding()
    }
}

/// 追加のジェネレーターを描く（EffectProcessor から）
enum MoreGenerators {
    static func draw(_ e: Effect, key: String, life: LifeStore, into dst: MTLTexture, stack: EffectStack, now: Double, cb: MTLCommandBuffer) {
        let o = stack.origin
        switch e.kind {
        case .laser, .synthwave, .metaballs, .starfield, .fractal:
            MoreGenRenderer.shared.render(e, into: dst, now: now, stack: stack, cb: cb)
        case .reactionDiffusion:
            guard let (s, dt) = life.state(key, now: now, origin: o, warm: 3, make: { ReactionDiffusionSim() }) else { return }
            s.render(e, into: dst, dt: dt, now: now, stack: stack, cb: cb)
        case .ripples:
            guard let (s, dt) = life.state(key, now: now, origin: o, warm: 2, make: { RippleSim() }) else { return }
            s.render(e, into: dst, dt: dt, now: now, stack: stack, cb: cb)
        case .lightning:
            guard let (s, dt) = life.state(key, now: now, origin: o, warm: 0, make: { LightningSim() }) else { return }
            s.render(e, into: dst, dt: dt, now: now, stack: stack, cb: cb)
        case .growth:
            guard let (s, dt) = life.state(key, now: now, origin: o, warm: 3, make: { GrowthSim() }) else { return }
            s.render(e, into: dst, dt: dt, now: now, stack: stack, cb: cb)
        case .logoParticles:
            guard let (s, dt) = life.state(key, now: now, origin: o, warm: 2, make: { LogoParticleSim() }) else { return }
            s.render(e, into: dst, dt: dt, now: now, stack: stack, cb: cb)
        default:
            break
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// ジェネレーター「ロゴを粒に」の、形の元（画像を選ぶ・文字を打つ）
struct LogoSourcePicker: View {
    @Binding var effect: Effect
    private var isImage: Bool {
        let p = (effect.text as NSString).expandingTildeInPath
        return !effect.text.isEmpty && FileManager.default.fileExists(atPath: p)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("形").font(.system(size: 12)).foregroundStyle(.secondary)
                if isImage {
                    Label(URL(fileURLWithPath: effect.text).lastPathComponent, systemImage: "photo")
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("文字にする") { effect.text = "HALO" }
                } else {
                    TextField("文字（例：HALO）", text: $effect.text).frame(maxWidth: 200)
                    Spacer()
                }
                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif, .image]
                    panel.message = "粒にする画像（透明付きの PNG がおすすめ）"
                    if panel.runModal() == .OK, let u = panel.url { effect.text = u.path }
                } label: {
                    Label("画像を選ぶ…", systemImage: "photo.badge.plus")
                }
            }
            Text("透明付きの画像は、見えている所が粒になる。透明の無い画像は、明るい所が粒になる")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
