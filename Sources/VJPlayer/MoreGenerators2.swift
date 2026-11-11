import AppKit
import CoreText
import Metal
import simd

// 追加のジェネレーター 第 2 弾（どれも時刻だけで描く。前のコマは使わない）：
//   プラズマ・オーロラ・星雲・トルシェ模様・六角のタイル・文字の雨・回るワイヤーフレーム・モアレ
// 線の太さ・点の大きさは高さ 1080 を基準にして、描く大きさ（画質）が変わっても同じ見た目にする。

extension EffectKind {
    /// 第 2 弾のジェネレーター（描き方は MoreGen2Renderer）
    static let moreGenerators2: [EffectKind] = [.plasma, .aurora, .nebula, .truchet, .hexGrid, .codeRain, .wireframe, .moire]
}

private let moreGen2Source = """
#include <metal_stdlib>
using namespace metal;

struct VO { float4 pos [[position]]; float2 uv; };
vertex VO g2_full(uint vid [[vertex_id]]) {
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
// 1 次元のなめらかなノイズ（sin を使わない軽い乱数で）
static float hq(float x) { x = fract(x * 0.1031); x *= x + 33.33; x *= x + x; return fract(x); }
static float n1(float x) { float i = floor(x), f = fract(x); return mix(hq(i), hq(i + 1.0), f * f * (3.0 - 2.0 * f)); }
static float fbm1(float x) { float s = 0.0, a = 0.5; for (int i = 0; i < 3; i++) { s += a * n1(x); x = x * 2.07 + 13.1; a *= 0.5; } return s / 0.875; }
static float3 hue(float h) { float3 k = abs(fract(float3(h) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0); return saturate(k - 1.0); }
static float lum(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
static float mx3(float3 c) { return max(c.r, max(c.g, c.b)); }
// 0 → 0、0.5 → 1、1 → 0 の三角の波
static float tri(float x) { return 1.0 - abs(fract(x) * 2.0 - 1.0); }

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
// 乱数の表（256×256・くり返し）から読むノイズ。格子の 4 つの角を gather の 1 回で取る
static float vnT(texture2d<float> nt, float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float2 im = i - 256.0 * floor(i / 256.0);
    constexpr sampler gs(filter::nearest, address::repeat, coord::normalized);
    float4 g = nt.gather(gs, (im + 1.0) / 256.0);
    return mix(mix(g.w, g.z, w.x), mix(g.x, g.y, w.x), w.y);
}
static float fbmT(texture2d<float> nt, float2 p) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { s += a * vnT(nt, p); p = p * 2.03 + float2(17.3, 9.1); a *= 0.5; }
    return s / 0.9375;
}
// 小さな星（p は高さを 1 とした位置、H は描く高さ px）
static float starField(float2 p, float H, float T) {
    float cell = 16.0 / 1080.0;
    float2 g = p / cell;
    float2 id = floor(g), f = fract(g);
    float pr = h2(id + 17.3);
    if (pr > 0.10) return 0.0;
    float2 sp = 0.2 + 0.6 * h22(id);
    float dpx = length(f - sp) * cell * H;
    float sz = max((0.6 + 1.1 * h2(id + 3.1)) * H / 1080.0, 0.75);
    float tw = 0.65 + 0.35 * sin(T * (1.0 + 3.0 * h2(id + 5.5)) + pr * 60.0);
    return exp(-dpx * dpx / (sz * sz)) * tw * (0.35 + 0.65 * h2(id + 9.9));
}

// ===== プラズマ =====
// a = 大きさ, 進んだ量, ゆがみ, 色の付け方 / b = 色の回り(進んだ量), 帯の段数, コントラスト
fragment float4 g2_plasma(VO in [[stage_in]], constant MU& u [[buffer(0)]]) {
    float A = u.size.x / max(u.size.y, 1.0);
    float2 p = (in.uv - 0.5) * float2(A, 1.0);
    float T = u.a.y;
    float2 q = p * (11.0 / max(u.a.x, 0.05));
    float w = u.a.z;
    // 座標を sin で曲げて、有機的に
    q += w * 1.6 * float2(sin(q.y * 0.9 + T * 0.7), cos(q.x * 0.8 - T * 0.6));
    q += w * 0.6 * float2(sin(q.y * 2.1 - T * 1.1), cos(q.x * 1.9 + T * 0.9));
    float v = sin(q.x + T);
    v += sin((q.y + T) * 0.8);
    v += sin((q.x + q.y + T * 1.3) * 0.7);
    float2 c = q + float2(2.5 * sin(T * 0.33), 2.5 * cos(T * 0.41));
    v += sin(sqrt(dot(c, c) + 1.0) + T);
    float ph = v * 0.25;                       // -1〜1
    float n = u.b.y;
    if (n > 0.5) ph = (floor(ph * n * 0.5) + 0.5) / (n * 0.5);
    float cph = u.b.x;
    int mode = int(u.a.w + 0.5);
    float3 col;
    if (mode == 0) col = hue(ph * 0.9 + cph);
    else if (mode == 1) col = pal(u, tri(ph * 0.4 + 0.25 + cph));
    else if (mode == 2) col = palWrap(u, ph * 0.75 + cph);
    else col = float3(tri(ph * 0.4 + 0.25 + cph));
    // コントラスト：明るさにうねりを付けて、色を濃く
    float k = u.b.z;
    col = pow(saturate(col), float3(1.0 + k));
    col *= mix(1.0, 0.2 + 0.8 * (0.5 + 0.5 * cos(v * 1.7 + T * 0.3)), k);
    return float4(col, 1.0);
}

// ===== オーロラ =====
// a = 進んだ量, 高さ, うねり, すじの細かさ / b = 枚数, 明るさ, 星
fragment float4 g2_aurora(VO in [[stage_in]], constant MU& u [[buffer(0)]]) {
    float H = u.size.y;
    float A = u.size.x / max(H, 1.0);
    float2 p = float2(in.uv.x * A, in.uv.y);
    float T = u.a.x;
    float len = u.a.y, wav = u.a.z, fine = u.a.w;
    int N = clamp(int(u.b.x + 0.5), 1, 4);
    float3 acc = 0.0;
    for (int i = 0; i < N; i++) {
        float fi = float(i);
        float depth = N > 1 ? fi / float(N - 1) : 0.0;       // 0 = 手前、1 = 奥
        float sx = p.x * (0.8 + 0.3 * fi) + fi * 13.7;
        // ゆっくり横にうねる
        float wv = fbm1(sx * 0.5 + T * 0.05 + fi * 3.0) - 0.5;
        float x = sx + wv * wav * 2.0 + T * 0.02 * (i % 2 == 0 ? 1.0 : -1.0);
        // カーテンの下の端（奥ほど上）
        float yb = 0.74 - 0.13 * fi + (fbm1(x * 0.9 + T * 0.08 + 5.0) - 0.5) * 0.6 * wav;
        float h = yb - p.y;                                   // 下の端からの高さ（上が +）
        float Hh = len * (0.8 - 0.25 * depth);
        float prof = h >= 0.0 ? exp(-h / max(Hh * 0.35, 0.02)) : exp(-h * h / 0.0006);
        float rim = exp(-abs(h) / 0.012) * 0.6;
        // カーテンのある所・無い所（上へ行くほど少し斜めにずらして、切れ目がまっすぐな縦線にならないように）
        float xd = x + h * 0.8 - T * 0.04 + fi * 5.1;
        float dens = 0.12 + 0.88 * smoothstep(0.25, 0.75, n1(xd * 0.8) * 0.65 + n1(xd * 1.7 + 3.0) * 0.35);
        // 細い縦すじ（x だけのノイズ）
        float f1 = 25.0 + 140.0 * fine;
        float rays = mix(0.3, 1.0, n1(x * f1 + T * 0.3)) * mix(0.55, 1.0, n1(x * f1 * 0.23 - T * 0.15 + 7.0));
        float b = dens * rays * (prof + rim) * (1.0 - 0.45 * depth);
        float3 c = pal(u, saturate(h / max(Hh * 0.55, 0.03)));
        acc += c * b;
    }
    acc *= u.b.y;
    if (u.b.z > 0.5) acc += float3(0.9, 0.95, 1.0) * starField(p, H, u.time) * (1.0 - saturate(mx3(acc) * 2.0));
    return float4(acc, saturate(mx3(acc)));
}

// ===== 星雲・煙 =====
// a = 大きさ, 進んだ量, 渦の強さ / b = 流れのずれ xy, 濃さ, コントラスト / c = 色の付け方, 星
fragment float4 g2_nebula(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> nt [[texture(0)]]) {
    float H = u.size.y;
    float A = u.size.x / max(H, 1.0);
    float2 p = (in.uv - 0.5) * float2(A, 1.0);
    float T = u.a.y;
    float2 q0 = p * (2.4 / max(u.a.x, 0.05)) - u.b.xy + 40.0;
    float w = u.a.z * 2.0;
    // f(p + f(p + f(p)))：2 段のゆがみ
    float2 q = float2(fbmT(nt, q0 + float2(0.0, T * 0.15)), fbmT(nt, q0 + float2(5.2, 1.3) - T * 0.12));
    float2 r = float2(fbmT(nt, q0 + w * q + float2(1.7, 9.2) + T * 0.1), fbmT(nt, q0 + w * q + float2(8.3, 2.8) - T * 0.08));
    float f = fbmT(nt, q0 + w * r);
    float thr = mix(0.68, 0.22, u.b.z);
    float soft = mix(0.4, 0.06, u.b.w);
    float d = smoothstep(thr, thr + soft, f);
    float ci = saturate((r.x - 0.3) * 1.8 + d * 0.35);
    int mode = int(u.c.x + 0.5);
    float3 rgb;
    // 濃い所ほど明るい（縁はうっすら、芯は明るく）
    float core = saturate((f - thr) / (soft + 0.25));
    float shade = 0.45 + 0.8 * core;
    if (mode == 0) rgb = pal(u, ci) * d * shade;
    else if (mode == 1) rgb = hue(ci * 0.8 + f * 0.6 + u.time * 0.01) * d * shade;
    else {
        float x = d * 0.5 + core * 0.5;
        rgb = mode == 2 ? float3(smoothstep(0.0, 0.4, x), smoothstep(0.3, 0.75, x), smoothstep(0.65, 1.0, x))
                        : float3(smoothstep(0.55, 1.0, x), smoothstep(0.3, 0.9, x), smoothstep(0.0, 0.45, x));
    }
    float a = d;
    if (u.c.y > 0.5) {
        float s = starField(p + 7.0, H, u.time) * (1.0 - d);
        rgb += float3(s); a = max(a, s);
    }
    return float4(rgb, saturate(max(a, mx3(rgb))));
}

// ===== トルシェ模様 =====
// a = マスの数, 形, 線の太さ, 回る位相 / b = 光る, 塗り分ける, 回る速さ（1 秒に何回） / c.xy = 流れのずれ（マス）
fragment float4 g2_truchet(VO in [[stage_in]], constant MU& u [[buffer(0)]]) {
    float H = u.size.y;
    float N = max(u.a.x, 1.0);
    float2 p = in.uv * u.size / H * N + u.c.xy + 100.0;
    float2 id = floor(p);
    float2 f = fract(p) - 0.5;
    float r0 = step(0.5, h2(id));
    // マスごとに違うときに、90° くるっと回る（回る途中はなめらかに）
    // 回るのにかかる時間は 0.3 秒くらい（回る回数が増えても、ぱっと飛ばない）
    float m = 0.7 + 0.6 * h2(id + 9.1);
    float wn = clamp(0.3 * u.b.z * m, 0.02, 0.6);
    float ph = u.a.w * m + h2(id + 3.7) * (1.0 - wn);
    float k = floor(ph), fr = fract(ph);
    float e = smoothstep(1.0 - wn, 1.0, fr);
    float ang = (k + e + r0) * 1.5707963;
    float ca = cos(ang), sa = sin(ang);
    f = float2(f.x * ca - f.y * sa, f.x * sa + f.y * ca);
    int shape = int(u.a.y + 0.5);
    float hw = u.a.z * 0.5;
    float fw = N / H * 0.9;                                    // 1 画素がマスのどれだけか
    float line, dl, inside;
    if (shape == 0) {
        float da = length(f - 0.5) - 0.5, db = length(f + 0.5) - 0.5;
        dl = min(abs(da), abs(db));
        line = 1.0 - smoothstep(hw - fw, hw + fw, dl);
        inside = 1.0 - smoothstep(-fw, fw, min(da, db));
    } else if (shape == 1) {
        float sd = (f.x - f.y) * 0.7071068;
        dl = abs(sd);
        line = 1.0 - smoothstep(hw - fw, hw + fw, dl);
        inside = smoothstep(-fw, fw, sd);
    } else {
        // 三角：斜めに半分を塗る。線の太さ = まわりのすき間
        float sd = (f.x - f.y) * 0.7071068;
        float bd = 0.5 - max(abs(f.x), abs(f.y));
        float s = min(sd, bd) - hw * 0.5;
        line = smoothstep(-fw, fw, s);
        dl = max(-s, 0.0);
        inside = smoothstep(-fw, fw, sd);
    }
    float glow = shape == 2 ? 0.0 : exp(-max(dl - hw, 0.0) * 14.0) * u.b.x * 0.6 * (1.0 - line);
    if (shape == 2) glow = exp(-dl * 14.0) * u.b.x * 0.5 * (1.0 - line);
    float3 lc = u.color.rgb;
    float3 rgb = lc * (line + glow);
    float a = saturate(line + glow);
    if (u.b.y > 0.5) {
        // 塗り分け：線で分かれた面を 2 色で（マスの市松と向きで、となりと色がそろう）
        float q = fmod(k + r0 + step(0.5, e), 2.0);
        float par = fmod(id.x + id.y + q, 2.0);
        float s = par > 0.5 ? 1.0 - inside : inside;
        float3 fc = mix(u.pal[0].rgb, pal(u, 1.0), s);
        rgb = mix(fc, lc, line) + lc * glow;
        a = 1.0;
    }
    return float4(rgb, a);
}

// ===== 六角のタイル =====
// a = 縦の数, すき間, 角の丸み, 光り方 / b = 進んだ量, 光る量, ふち取りだけ, 色の付け方 / c.x = 回転(rad)
fragment float4 g2_hex(VO in [[stage_in]], constant MU& u [[buffer(0)]]) {
    float H = u.size.y;
    float A = u.size.x / max(H, 1.0);
    float2 p0 = (in.uv - 0.5) * float2(A, 1.0);
    float ca = cos(u.c.x), sa = sin(u.c.x);
    p0 = float2(p0.x * ca - p0.y * sa, p0.x * sa + p0.y * ca);
    float sc = max(u.a.x, 1.0) * 0.8660254;
    float2 p = p0 * sc;
    const float2 s = float2(1.0, 1.7320508);
    float4 hc = floor(float4(p, p - float2(0.5, 1.0)) / s.xyxy) + 0.5;
    float4 hh = float4(p - hc.xy * s, p - (hc.zw + 0.5) * s);
    float2 h, id;
    if (dot(hh.xy, hh.xy) < dot(hh.zw, hh.zw)) { h = hh.xy; id = hc.xy; } else { h = hh.zw; id = hc.zw + 0.5; }
    float2 ah = abs(h);
    float hd = max(dot(ah, float2(0.5, 0.8660254)), ah.x);
    float sd = mix(hd, length(h), u.a.z) - 0.5 * (1.0 - u.a.y);
    float fw = sc / H;
    float fill = 1.0 - smoothstep(-fw, fw, sd);
    float lw = 0.07;
    float ring = 1.0 - smoothstep(lw * 0.5 - fw, lw * 0.5 + fw, abs(sd + lw * 0.5));
    float2 cp = id * s / sc;                                   // タイルの真ん中（高さを 1 とした位置）
    float T = u.b.x;
    int mode = int(u.a.w + 0.5);
    float v;
    if (mode == 0) v = 0.5 + 0.5 * sin(length(cp) * 14.0 - T * 3.0);
    else if (mode == 1) v = saturate((vn(cp * 4.0 + float2(T * 0.5, -T * 0.3)) - 0.5) * 2.2 + 0.5);
    else if (mode == 2) {
        float ph = T * (0.5 + 0.8 * h2(id + 2.2)) + h2(id + 1.3) * 7.0;
        float kk = floor(ph);
        v = h2(id + kk * 1.71) * (1.0 - 0.5 * fract(ph));
    } else v = 0.5 + 0.5 * sin((cp.x * 0.8 + cp.y * 0.6) * 12.0 - T * 3.0);
    float th = mix(1.05, -0.25, u.b.y);
    float lit = smoothstep(th, th + 0.25, v);
    float bri = lit * (0.55 + 0.45 * v);
    int cm = int(u.b.w + 0.5);
    // 2 色：光っているタイルの中で、明るさで色 1 → 色 2 へ
    float ci = saturate((v - th) / max(1.0 - th, 0.05));
    float3 col = cm == 0 ? u.color.rgb : (cm == 1 ? pal(u, ci) : hue(h2(id * 0.731 + 4.4) + T * 0.02));
    float shp = u.b.z > 0.5 ? ring : fill * 0.85 + ring * 0.35;
    float3 rgb = col * bri * shp;
    return float4(rgb, saturate(bri * min(shp, 1.0)));
}

// ===== 文字の雨 =====
// a = 縦の行数, 落ちる速さ, 尾の長さ, 列の濃さ / b = 文字の変わる速さ, 先頭の白さ, 光る, 向き
fragment float4 g2_rain(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> atlas [[texture(0)]]) {
    float W = u.size.x, H = u.size.y;
    float ch = H / max(u.a.x, 1.0), cw = ch * 0.62;
    float2 px = in.uv * u.size;
    float2 g = px / float2(cw, ch);
    float2 cell = floor(g), f = fract(g);
    int dir = int(u.b.w + 0.5);
    float col, pos, L;
    if (dir < 2) { col = cell.x; L = ceil(H / ch); pos = dir == 0 ? cell.y : L - 1.0 - cell.y; }
    else { col = cell.y + 500.0; L = ceil(W / cw); pos = dir == 2 ? cell.x : L - 1.0 - cell.x; }
    float T = u.time;
    float tailN = max(u.a.z * L, 1.0);
    float bright = 0.0, head = 0.0;
    for (int k = 0; k < 2; k++) {
        float fk = float(k);
        float act = k == 0 ? u.a.w : u.a.w * 0.5;
        if (h2(float2(col * 1.37, fk + 4.2)) >= act) continue;
        float hk = h2(float2(col, fk * 7.3 + 1.1));
        float sp = (0.5 + 0.9 * hk) * u.a.y * 12.0;
        float P = L + tailN + L * (0.2 + 0.8 * h2(float2(col, fk + 9.7)));
        float hd = floor(fmod(T * sp + hk * 997.0 + fk * P * 0.5, P));
        float dist = hd - pos;
        if (dist >= 0.0 && dist < tailN) {
            bright = max(bright, pow(1.0 - dist / tailN, 1.5));
            if (dist < 1.0) head = 1.0;
        }
    }
    if (bright <= 0.0) return float4(0.0);
    // 字：ときどき変わる（先頭は速く変わる）
    float ck = floor(T * u.b.x * (6.0 + 10.0 * head) + h2(cell + 0.5) * 5.0);
    float gi = floor(h2(cell * 1.13 + ck * 0.917) * 64.0);
    float2 gc = float2(fmod(gi, 8.0), floor(gi / 8.0));
    float2 auv = (gc + 0.04 + f * 0.92) / 8.0;
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float lod = max(log2(72.0 / ch), 0.0);
    float gv = atlas.sample(s, auv, level(lod)).r;
    float flick = 0.85 + 0.15 * h2(cell + floor(T * 12.0));
    float3 c = u.color.rgb;
    float3 hc = mix(c, float3(1.0), u.b.y);
    float3 rgb = mix(c, hc, head) * gv * bright * flick * (1.0 + head * 0.5);
    // 光る：字のまわりのぼんやりした光
    float halo = saturate(1.0 - length((f - 0.5) * float2(1.0, 0.75)) * 1.6);
    rgb += mix(c, hc, head) * u.b.z * bright * halo * 0.35;
    return float4(rgb, saturate(mx3(rgb)));
}

// ===== モアレ =====
// a = 形, 細かさ, 中心の離れ, 回り(rad) / b = 太さ, 組の数, ふくらみ(進んだ量), 重ね方 / c.x = やわらかさ
fragment float4 g2_moire(VO in [[stage_in]], constant MU& u [[buffer(0)]]) {
    float H = u.size.y;
    float A = u.size.x / max(H, 1.0);
    float2 p = (in.uv - 0.5) * float2(A, 1.0);
    int shape = int(u.a.x + 0.5);
    float fq = u.a.y, sep = u.a.z, th = u.a.w;
    float duty = u.b.x;
    int n = clamp(int(u.b.y + 0.5), 2, 3);
    float ex = u.b.z;
    float x = 0.0;
    float3 add = 0.0;
    for (int i = 0; i < 3; i++) {
        if (i >= n) break;
        float fi = float(i);
        float ang = th + fi * 6.2831853 / float(n);
        float2 c = sep * 0.3 * float2(cos(ang), sin(ang));
        int kind = shape == 0 ? 0 : (shape == 1 ? 1 : (shape == 2 ? (i == 1 ? 1 : 0) : 2));
        float ph, fw;
        float2 d = p - c;
        if (kind == 0) { ph = length(d) * fq - ex; fw = fq / H; }
        else if (kind == 1) {
            float la = th * 0.25 + (fi - float(n - 1) * 0.5) * (0.03 + sep * 0.2);
            ph = dot(d, float2(cos(la), sin(la))) * fq - ex * (i % 2 == 0 ? 1.0 : -1.0);
            fw = fq / H;
        } else {
            float spokes = max(floor(fq * 0.5), 3.0);
            float r = max(length(d), 1e-4);
            ph = (atan2(d.y, d.x) / 6.2831853) * spokes + ex * 0.15 * (i % 2 == 0 ? 1.0 : -1.0);
            fw = spokes / (6.2831853 * r) / H;
        }
        float tr = abs(fract(ph) - 0.5);
        float e = max(fw, u.c.x * 0.25);
        float on = smoothstep(0.5 - duty * 0.5 - e, 0.5 - duty * 0.5 + e, tr);
        // 1 画素より細かい所は、平均の明るさへ溶かす（ちらつき・偽の模様を出さない）
        on = mix(on, duty, saturate((fw - 0.3) / 0.4));
        x = i == 0 ? on : x + on - 2.0 * x * on;
        add += on * pal(u, fi / float(n - 1));
    }
    float3 rgb = int(u.b.w + 0.5) == 0 ? pal(u, saturate(length(p) * 1.1)) * x : add * 0.8;
    return float4(rgb, saturate(mx3(rgb)));
}

// ===== 線を光らせて描く（ワイヤーフレーム）：線分ごとに四角を描き、重なりは明るい方を取る =====
struct Seg { float4 ab; float4 col; float4 info; };
struct SVO { float4 pos [[position]]; float2 p; float2 a; float2 b; float4 col; float w; float g; };
vertex SVO g2_seg_v(uint vid [[vertex_id]], uint iid [[instance_id]], constant Seg* segs [[buffer(0)]], constant float2& size [[buffer(1)]]) {
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
fragment float4 g2_seg_f(SVO in [[stage_in]]) {
    float2 pa = in.p - in.a, ba = in.b - in.a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    float d = length(pa - ba * h);
    float core = 1.0 - smoothstep(in.w * 0.5 - 0.5, in.w * 0.5 + 0.7, d);
    float glow = in.g > 0.0 ? exp(-d / max(in.g, 0.5)) * 0.55 : 0.0;
    float v = (core + glow) * in.col.a;
    float3 c = in.col.rgb * v + float3(core * in.col.a * 0.35);
    return float4(c, saturate(v));
}
"""

/// 第 2 弾のジェネレーターを描く道具
final class MoreGen2Renderer {
    static let shared = MoreGen2Renderer()
    let device = MetalContext.shared.device
    private var pipes: [String: MTLRenderPipelineState] = [:]
    /// ノイズの乱数の表（シンセウェイブと同じ作り方。決まった種なので、いつも同じ形）
    private let noiseTable: MTLTexture? = MoreGenRenderer.makeNoiseTable(device: MetalContext.shared.device)
    /// 文字の雨の字の絵（横 8 字 × 縦 8 段。縮めて描くので、小さい絵も用意する）
    private lazy var rainAtlas: MTLTexture? = Self.makeRainAtlas(device: device)
    private var atlasReady = false

    private init() {
        let lib = try! device.makeLibrary(source: moreGen2Source, options: nil)
        func r(_ v: String, _ f: String, maxBlend: Bool = false) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            if maxBlend {
                // 重なった線は明るい方を取る（足すと、つなぎ目が玉のように光るので）
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.rgbBlendOperation = .max; c.alphaBlendOperation = .max
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .one
            }
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        for f in ["g2_plasma", "g2_aurora", "g2_nebula", "g2_truchet", "g2_hex", "g2_rain", "g2_moire"] {
            pipes[f] = r("g2_full", f)
        }
        pipes["seg"] = r("g2_seg_v", "g2_seg_f", maxBlend: true)
    }

    private func full(_ dst: MTLTexture, _ name: String, _ u: inout MoreFXUniforms, cb: MTLCommandBuffer, texture: MTLTexture? = nil) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: rpd), let p = pipes[name] else { return }
        e.setRenderPipelineState(p)
        e.setFragmentBytes(&u, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
        if let texture { e.setFragmentTexture(texture, index: 0) }
        e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        e.endEncoding()
    }

    func render(_ e: Effect, into dst: MTLTexture, now: Double, stack: EffectStack, cb: MTLCommandBuffer) {
        func v(_ i: Int) -> Float { Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) }
        var u = MoreFXRenderer.shared.uniforms(e, dst: dst, now: now, stack: stack, mixAmt: 1)
        let t = u.time
        let deg = Float.pi / 180
        switch e.kind {
        case .plasma:
            u.a = SIMD4(v(0), t * v(1), v(2), v(3).rounded())
            u.b = SIMD4(v(4) * t * 0.25, v(5), v(6), 0)
            full(dst, "g2_plasma", &u, cb: cb)
        case .aurora:
            u.a = SIMD4(t * v(0), v(1), v(2), v(3))
            u.b = SIMD4(v(4), v(5), v(6), 0)
            full(dst, "g2_aurora", &u, cb: cb)
        case .nebula:
            // 流れる向き：0° = 右、90° = 上（煙が立ちのぼる）
            let a = v(3) * deg, m = v(4) * t * 0.5
            u.a = SIMD4(v(0), t * v(1), v(2), 0)
            u.b = SIMD4(cos(a) * m, -sin(a) * m, v(5), v(6))
            u.c = SIMD4(v(7).rounded(), v(8), 0, 0)
            full(dst, "g2_nebula", &u, cb: cb, texture: noiseTable)
        case .truchet:
            let a = v(4) * deg, m = v(5) * t
            u.a = SIMD4(v(0), v(1).rounded(), v(2), t * v(3) * 0.35)
            u.b = SIMD4(v(6), v(7), v(3) * 0.35, 0)
            u.c = SIMD4(-cos(a) * m, sin(a) * m, 0, 0)
            full(dst, "g2_truchet", &u, cb: cb)
        case .hexGrid:
            u.a = SIMD4(v(0), v(1), v(2), v(3).rounded())
            u.b = SIMD4(t * v(4), v(5), v(6), v(7).rounded())
            u.c = SIMD4(v(8) * deg, 0, 0, 0)
            full(dst, "g2_hex", &u, cb: cb)
        case .codeRain:
            guard let atlas = rainAtlas else { return }
            if !atlasReady, let blit = cb.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: atlas)
                blit.endEncoding()
                atlasReady = true
            }
            u.a = SIMD4(v(0), v(1), v(2), v(3))
            u.b = SIMD4(v(4), v(5), v(6), v(7).rounded())
            full(dst, "g2_rain", &u, cb: cb, texture: atlas)
        case .moire:
            u.a = SIMD4(v(0).rounded(), v(1), v(2), v(3) * deg * t)
            u.b = SIMD4(v(4), v(5), t * v(6), v(7).rounded())
            u.c = SIMD4(v(8), 0, 0, 0)
            full(dst, "g2_moire", &u, cb: cb)
        case .wireframe:
            drawSegs(Self.wireframeSegs(e, v: v, t: t, size: SIMD2(Float(dst.width), Float(dst.height))), into: dst, cb: cb)
        default:
            return
        }
    }

    // MARK: - 回るワイヤーフレーム

    struct Seg { var ab: SIMD4<Float>; var col: SIMD4<Float>; var info: SIMD4<Float> }

    private func drawSegs(_ segs: [Seg], into dst: MTLTexture, cb: MTLCommandBuffer) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        if !segs.isEmpty, let p = pipes["seg"] {
            enc.setRenderPipelineState(p)
            var size = SIMD2<Float>(Float(dst.width), Float(dst.height))
            guard let buf = device.makeBuffer(bytes: segs, length: MemoryLayout<Seg>.stride * segs.count, options: .storageModeShared) else {
                enc.endEncoding(); return
            }
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&size, length: 8, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: segs.count)
        }
        enc.endEncoding()
    }

    /// 形の辺（半径 1 ほどの大きさ）。球・トーラスは輪を折れ線にする
    static let shapes: [[(SIMD3<Float>, SIMD3<Float>)]] = (0..<7).map(makeShape)

    private static func makeShape(_ k: Int) -> [(SIMD3<Float>, SIMD3<Float>)] {
        typealias V = SIMD3<Float>
        func pairs(_ vs: [V], len: Float) -> [(V, V)] {
            var out: [(V, V)] = []
            for i in vs.indices { for j in vs.indices where j > i && abs(simd_distance(vs[i], vs[j]) - len) < 0.01 * len { out.append((vs[i], vs[j])) } }
            return out
        }
        func ring(_ n: Int, _ f: (Float) -> V) -> [(V, V)] {
            (0..<n).map { i in (f(Float(i) / Float(n) * 2 * .pi), f(Float(i + 1) / Float(n) * 2 * .pi)) }
        }
        switch k {
        case 0:   // 立方体
            var vs: [V] = []
            for x in [-1, 1] { for y in [-1, 1] { for z in [-1, 1] { vs.append(V(Float(x), Float(y), Float(z)) / sqrt(3)) } } }
            return pairs(vs, len: 2 / sqrt(3))
        case 1:   // 正四面体
            let vs = [V(1, 1, 1), V(1, -1, -1), V(-1, 1, -1), V(-1, -1, 1)].map { $0 / sqrt(3) }
            return pairs(vs, len: 2 * sqrt(2) / sqrt(3))
        case 2:   // 正八面体
            let vs = [V(1, 0, 0), V(-1, 0, 0), V(0, 1, 0), V(0, -1, 0), V(0, 0, 1), V(0, 0, -1)]
            return pairs(vs, len: sqrt(2))
        case 3:   // 正二十面体（辺 30 本）
            let g: Float = (1 + sqrt(5)) / 2
            var vs: [V] = []
            for a in [-1, 1] as [Float] { for b in [-1, 1] as [Float] {
                vs += [V(0, a, b * g), V(a, b * g, 0), V(b * g, 0, a)]
            } }
            let r = sqrt(1 + g * g)
            return pairs(vs.map { $0 / r }, len: 2 / r)
        case 4:   // 球：経線 4 本・緯線 5 本
            var out: [(V, V)] = []
            for m in 0..<4 {
                let a = Float(m) * .pi / 4
                out += ring(24) { s in V(cos(s) * cos(a), sin(s), cos(s) * sin(a)) }
            }
            for lat in [-60, -30, 0, 30, 60] as [Float] {
                let y = sin(lat * .pi / 180), r = cos(lat * .pi / 180)
                out += ring(24) { s in V(cos(s) * r, y, sin(s) * r) }
            }
            return out
        case 5:   // トーラス：管の輪 12 本・大きな輪 4 本
            let R: Float = 0.7, r: Float = 0.3
            var out: [(V, V)] = []
            for m in 0..<12 {
                let a = Float(m) / 12 * 2 * .pi
                out += ring(16) { s in V((R + r * cos(s)) * cos(a), r * sin(s), (R + r * cos(s)) * sin(a)) }
            }
            for (rr, y) in [(R + r, Float(0)), (R - r, 0), (R, r), (R, -r)] {
                out += ring(32) { s in V(rr * cos(s), y, rr * sin(s)) }
            }
            return out
        default:  // ピラミッド（四角い底と、てっぺん）
            let b: [V] = [V(-0.8, -0.55, -0.8), V(0.8, -0.55, -0.8), V(0.8, -0.55, 0.8), V(-0.8, -0.55, 0.8)]
            let top = V(0, 0.95, 0)
            return (0..<4).map { (b[$0], b[($0 + 1) % 4]) } + b.map { ($0, top) }
        }
    }

    /// 辺を回して、画面に落とした線分にする
    static func wireframeSegs(_ e: Effect, v: (Int) -> Float, t: Float, size: SIMD2<Float>) -> [Seg] {
        let deg = Float.pi / 180
        let edges = shapes[min(max(Int(v(0).rounded()), 0), shapes.count - 1)]
        let A = size.x / max(size.y, 1)
        let k = size.y / 1080
        let width = v(5) * k, glow = v(6) * 9 * k
        let dim = v(7), persp = v(8)
        let cm = Int(v(9).rounded())
        let count = min(max(Int(v(10).rounded()), 1), 5)
        let col = SIMD3<Float>(Float(e.color.r), Float(e.color.g), Float(e.color.b))
        let palette = e.palette.isEmpty ? [RGB.black, RGB.white] : e.palette
        func pal(_ x: Float) -> SIMD3<Float> {
            let n = palette.count
            if n == 1 { return SIMD3(Float(palette[0].r), Float(palette[0].g), Float(palette[0].b)) }
            let f = min(max(x, 0), 1) * Float(n - 1)
            let i = min(Int(f), n - 2)
            let a = palette[i], b = palette[i + 1], w = f - Float(i)
            return SIMD3(Float(a.r), Float(a.g), Float(a.b)) * (1 - w) + SIMD3(Float(b.r), Float(b.g), Float(b.b)) * w
        }
        func hue(_ h: Float) -> SIMD3<Float> {
            let x = h - floor(h)
            func ch(_ o: Float) -> Float { min(max(abs((x + o).truncatingRemainder(dividingBy: 1) * 6 - 3) - 1, 0), 1) }
            return SIMD3(ch(0), ch(2.0 / 3), ch(1.0 / 3))
        }
        var segs: [Seg] = []
        segs.reserveCapacity(edges.count * count)
        for j in 0..<count {
            let sj = v(1) * pow(0.7, Float(j))
            let sgn: Float = j % 2 == 0 ? 1 : -0.8
            let m = 1 + 0.25 * Float(j)
            let ax = v(2) * deg * t * sgn * m + Float(j) * 0.6
            let ay = v(3) * deg * t * sgn * m + Float(j) * 0.9
            let az = v(4) * deg * t * sgn * m
            let rx = simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(ax), -sin(ax)), SIMD3(0, sin(ax), cos(ax))])
            let ry = simd_float3x3(rows: [SIMD3(cos(ay), 0, sin(ay)), SIMD3(0, 1, 0), SIMD3(-sin(ay), 0, cos(ay))])
            let rz = simd_float3x3(rows: [SIMD3(cos(az), -sin(az), 0), SIMD3(sin(az), cos(az), 0), SIMD3(0, 0, 1)])
            let R = rz * ry * rx
            // 画面に落とす（z は手前が +。遠近 0 は平行投影）
            func proj(_ p: SIMD3<Float>) -> (SIMD2<Float>, Float) {
                let q = R * p
                let f = 1 / (1 - persp * 0.45 * q.z)
                let x = q.x * sj * f * 0.45, y = q.y * sj * f * 0.45
                return (SIMD2(0.5 + x / A, 0.5 - y), q.z)
            }
            for (i, (a, b)) in edges.enumerated() {
                let (pa, za) = proj(a), (pb, zb) = proj(b)
                let dd = ((za + zb) * 0.5) * 0.5 + 0.5             // 0 = 奥、1 = 手前
                let bright = 1 + dim * (0.2 + 0.8 * dd - 1)
                let w = width * (1 + dim * (0.45 + 0.55 * dd - 1))
                let c: SIMD3<Float> = cm == 0 ? col : (cm == 1 ? hue(Float(i) / Float(max(edges.count, 1)) + Float(j) * 0.17 + t * 0.05) : pal(dd))
                segs.append(Seg(ab: SIMD4(pa.x, pa.y, pb.x, pb.y), col: SIMD4(c.x, c.y, c.z, bright), info: SIMD4(w, glow, 0, 0)))
            }
        }
        return segs
    }

    // MARK: - 文字の雨の字

    /// 字の並び（半角カタカナ・数字・記号で 64 字）
    static let rainGlyphs: [Character] = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜｦﾝ0123456789Z:=*+<>¦")

    /// 白い字・黒い地の絵（横 8 字 × 縦 8 段、1 字 44×72 px）
    static func makeRainAtlas(device: MTLDevice) -> MTLTexture? {
        let cw = 44, ch = 72
        let W = cw * 8, H = ch * 8
        var px = [UInt8](repeating: 0, count: W * H)
        guard let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(ch) * 0.74, weight: .semibold)
        for (i, chr) in rainGlyphs.prefix(64).enumerated() {
            let s = NSAttributedString(string: String(chr), attributes: [.font: font, .foregroundColor: NSColor.white])
            let line = CTLineCreateWithAttributedString(s)
            ctx.textPosition = .zero
            let b = CTLineGetImageBounds(line, ctx)
            let col = i % 8, row = i / 8
            let x = CGFloat(col * cw) + (CGFloat(cw) - b.width) / 2 - b.minX
            let y = CGFloat(H - (row + 1) * ch) + (CGFloat(ch) - b.height) / 2 - b.minY
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: W, height: H, mipmapped: true)
        td.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: td) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: px, bytesPerRow: W)
        return t
    }
}
