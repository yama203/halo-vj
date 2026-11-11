import Metal
import QuartzCore
import simd

// 追加のエフェクト（第 2 弾）：
//   ぼかし（光・ぼかし）／レンズ・極座標・タイル・ゆれ（形）／キー抜き（色）／LED パネル・スライス（グリッチ・デジタル）
// どれも前のコマを使わない。値の渡し方・色の持ち方（premultiplied）は MoreEffects.swift と同じ。

private let moreFX2Source = """
#include <metal_stdlib>
using namespace metal;

struct VO { float4 pos [[position]]; float2 uv; };
vertex VO m2_full(uint vid [[vertex_id]]) {
    float2 c = float2(float(vid & 1), float(vid >> 1));
    VO o; o.pos = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0); o.uv = c; return o;
}
static float h2(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float lum(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// a〜d = 値 / size = 絵の大きさ / time / mixAmt = 不透明度 / color・pal = 色（MoreEffects.swift と同じ形）
struct MU { float4 a, b, c, d; float4 color; float4 pal[8]; float2 size; float time; float mixAmt; int palCount; };

static float4 finish(float4 orig, float4 col, float m) { return mix(orig, col, saturate(m)); }

// 端の扱い：0 のばす / 1 折り返す（鏡） / 2 透明 / 3 くり返す
static float4 sampEdge(texture2d<float> t, float2 uv, int edge) {
    constexpr sampler sc(filter::linear, address::clamp_to_edge);
    constexpr sampler sm(filter::linear, address::mirrored_repeat);
    constexpr sampler sz(filter::linear, address::clamp_to_zero);
    constexpr sampler sr(filter::linear, address::repeat);
    if (edge == 1) return t.sample(sm, uv);
    if (edge == 2) return t.sample(sz, uv);
    if (edge == 3) return t.sample(sr, uv);
    return t.sample(sc, uv);
}
// ミップマップ付きの絵から、細かさ（lod）を決めて取る（縮めて並べたときのちらつきを防ぐ）
static float4 sampLod(texture2d<float> t, float2 uv, float lod, int edge) {
    constexpr sampler sc(filter::linear, mip_filter::linear, address::clamp_to_edge);
    constexpr sampler sm(filter::linear, mip_filter::linear, address::mirrored_repeat);
    constexpr sampler sz(filter::linear, mip_filter::linear, address::clamp_to_zero);
    constexpr sampler sr(filter::linear, mip_filter::linear, address::repeat);
    float l = clamp(lod, 0.0, 12.0);
    if (edge == 1) return t.sample(sm, uv, level(l));
    if (edge == 2) return t.sample(sz, uv, level(l));
    if (edge == 3) return t.sample(sr, uv, level(l));
    return t.sample(sc, uv, level(l));
}

// そのまま写す（値 0 のとき・ミップマップの元を作るとき）
fragment float4 m2_copy(VO in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    return t.sample(s, in.uv);
}
// 半分に縮める（2×2 か 2×1 の平均。出す画素の真ん中が、元の画素のさかい目に来る）
fragment float4 m2_down(VO in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return t.sample(s, in.uv);
}

// ===== ぼかし =====
// 片方向のガウス。d = 1 画素の向き(uv), sg = シグマ(この大きさでの画素), edge = 端(0 のばす 2 透明)
static float4 gauss1(texture2d<float> t, float2 uv, float2 d, float sg, int edge) {
    sg = max(sg, 0.05);
    int n = min(int(ceil(sg * 3.0)), 12);
    float k = -0.5 / (sg * sg);
    // 隣り合う 2 つを、間の 1 か所から直線補間で取る（取る回数が半分）
    float4 acc = sampEdge(t, uv, edge); float ws = 1.0;
    for (int i = 1; i <= n; i += 2) {
        float w1 = exp(float(i * i) * k), w2 = i + 1 <= n ? exp(float((i + 1) * (i + 1)) * k) : 0.0;
        float w = w1 + w2;
        float o = (float(i) * w1 + float(i + 1) * w2) / w;
        acc += (sampEdge(t, uv + d * o, edge) + sampEdge(t, uv - d * o, edge)) * w;
        ws += 2.0 * w;
    }
    return acc / ws;
}
// b.xy = 1 画素の向き(uv), b.z = シグマ, b.w = 端
fragment float4 m2_blur(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    return gauss1(t, in.uv, u.b.xy, u.b.z, int(u.b.w + 0.5));
}
// 縮めないとき：最後の向きのぼかしと重ねるのを 1 回で（a.x = 明るい所を残す, b = m2_blur と同じ）
fragment float4 m2_blurLast(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]],
                            texture2d<float> bl [[texture(1)]]) {
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    float4 o = t.sample(sn, in.uv);
    float4 b = gauss1(bl, in.uv, u.b.xy, u.b.z, int(u.b.w + 0.5));
    float4 c = mix(b, max(b, o), saturate(u.a.x));
    return finish(o, c, u.mixAmt);
}
// 小さい絵をなめらかに広げる（B スプライン。直線でつなぐと、広いぼかしに折れ目が出るので）
static float4 sampSmooth(texture2d<float> t, float2 uv) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 sz = float2(t.get_width(), t.get_height());
    float2 p = uv * sz - 0.5;
    float2 i = floor(p), f = p - i;
    float2 f2 = f * f, f3 = f2 * f;
    float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    float2 w3 = f3 / 6.0;
    float2 g0 = w0 + w1, g1 = w2 + w3;
    float2 h0 = (i - 0.5 + w1 / g0) / sz, h1 = (i + 1.5 + w3 / g1) / sz;
    return g0.y * (g0.x * t.sample(s, float2(h0.x, h0.y)) + g1.x * t.sample(s, float2(h1.x, h0.y)))
         + g1.y * (g0.x * t.sample(s, float2(h0.x, h1.y)) + g1.x * t.sample(s, float2(h1.x, h1.y)));
}
// 重ねる：a.x = 明るい所を残す, a.y = 縮めてぼかした(1)
fragment float4 m2_blurOut(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]],
                           texture2d<float> bl [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 o = t.sample(s, in.uv);
    float4 b = u.a.y > 0.5 ? sampSmooth(bl, in.uv) : bl.sample(s, in.uv);
    float4 c = mix(b, max(b, o), saturate(u.a.x));
    return finish(o, c, u.mixAmt);
}

// ===== レンズ =====
// p は真ん中からの位置（高さを 1 とする）、R = 効く半径。強さ s で取る所を返す
static float2 lensMap(float2 p, int k, float s, float R, float T) {
    float r = length(p) / R;
    if (r >= 1.0 || s <= 0.0) return p;
    float e = 1.0 - r * r; e *= e;               // 真ん中 1 → 縁 0（縁でなめらかにつながる）
    if (k == 0) return p * (1.0 - 0.85 * s * e);  // 魚眼：真ん中ほど近くを取る → ふくらむ
    if (k == 1) return p * (1.0 + 1.2 * s * e);   // へこむ：真ん中ほど遠くを取る
    if (k == 2) {                                 // 渦：真ん中ほど強く回す
        float a = s * 5.0 * (1.0 - r) * (1.0 - r);
        float ca = cos(a), sa = sin(a);
        return float2(p.x * ca - p.y * sa, p.x * sa + p.y * ca);
    }
    if (k == 3) return p / (1.0 + 2.0 * s);       // 虫めがね：丸の中だけ拡大
    // 波打つレンズ：距離の sin で外へ・内へ
    float w = sin(r * 28.0 - T * 2.5);
    float2 dir = p / max(length(p), 1e-5);
    return p + dir * w * 0.035 * s * R * e;
}
// a = 種類, 強さ, 大きさ, 色のにじみ / b = 中心x, 中心y, 端
fragment float4 m2_lens(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]],
                        texture2d<float> m [[texture(1)]]) {
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    float4 o = t.sample(sn, in.uv);
    float A = u.size.x / max(u.size.y, 1.0);
    float2 asp = float2(A, 1.0);
    float2 c = u.b.xy;
    float2 p = (in.uv - c) * asp;
    int k = int(u.a.x + 0.5);
    float s = saturate(u.a.y), R = max(u.a.z, 0.01), ca = saturate(u.a.w);
    int edge = int(u.b.z + 0.5);
    float sr = saturate(s * (1.0 + 0.3 * ca)), sb = saturate(s * (1.0 - 0.3 * ca));
    float2 qg = lensMap(p, k, s, R, u.time);
    float2 qr = lensMap(p, k, sr, R, u.time), qb = lensMap(p, k, sb, R, u.time);
    // 細かさ：取る所が画素ごとにどれだけ動くか
    float2 qpx = qg * u.size.y;
    float lod = log2(max(max(length(dfdx(qpx)), length(dfdy(qpx))), 1e-4));
    float4 gr = sampLod(m, qr / asp + c, lod, edge), gg = sampLod(m, qg / asp + c, lod, edge), gb = sampLod(m, qb / asp + c, lod, edge);
    float4 col = float4(gr.r, gg.g, gb.b, max(max(gr.a, gg.a), gb.a));
    if (k == 3) {
        // 虫めがねの縁：1.5 画素でなめらかに
        float inside = saturate((R - length(p)) * u.size.y / 1.5 + 0.5);
        col = mix(o, col, inside);
    }
    return finish(o, col, u.mixAmt);
}

// ===== 極座標 =====
// a = 向き(0 輪にする 1 ほどく), 回す(周), 巻く回数, 半径のずれ(流れ込み) / b = 中心x, 中心y, 鏡, 入れ替え
static float tri1(float x) { float f = fract(x); return 1.0 - abs(2.0 * f - 1.0); }   // 0→1→0
static float mirrorWrap(float x) { float f = fract(x * 0.5) * 2.0; return f > 1.0 ? 2.0 - f : f; }
fragment float4 m2_polar(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]],
                         texture2d<float> m [[texture(1)]]) {
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    float4 o = t.sample(sn, in.uv);
    float A = u.size.x / max(u.size.y, 1.0);
    float2 asp = float2(A, 1.0);
    float Rn = 0.5 * sqrt(A * A + 1.0);              // 真ん中から角まで（高さを 1 とする）
    float2 c = u.b.xy;
    float n = max(floor(u.a.z + 0.5), 1.0);
    bool mir = u.b.z > 0.5, inv = u.b.w > 0.5;
    float turns = n * (mir ? 2.0 : 1.0);              // 1 周で元の絵の横を何回なめるか
    float2 msz = float2(m.get_width(), m.get_height());
    float4 col;
    if (u.a.x < 0.5) {
        // 輪にする：角度 → 横、半径 → 縦
        float2 p = (in.uv - c) * asp;
        float r = length(p);
        float uu = (atan2(p.y, p.x) / 6.2831853 + 0.5 + u.a.y) * n;
        float x = mir ? tri1(uu) : fract(uu);
        float v = r / Rn;
        float y = (inv ? v : 1.0 - v) + u.a.w;
        y = mir ? mirrorWrap(y) : fract(y);
        float rpx = max(r * u.size.y, 0.5);
        float lod = log2(max(msz.x * turns / (6.2831853 * rpx), msz.y / (Rn * u.size.y)));
        col = sampLod(m, float2(x, y), lod, 0);
    } else {
        // ほどく：横 → 角度、縦 → 半径
        float uu = in.uv.x * n;
        float x = mir ? tri1(uu) : fract(uu);
        float ang = (x - 0.5 - u.a.y) * 6.2831853;
        float v = (inv ? in.uv.y : 1.0 - in.uv.y) - u.a.w;
        v = mirrorWrap(v);
        float r = v * Rn;
        float2 q = float2(cos(ang), sin(ang)) * r / asp + c;
        // 取る所が 1 画素でどれだけ動くか（元の絵の画素）：まわり方向・半径方向
        float tang = r * msz.y * 6.2831853 * turns / u.size.x;
        float rad = Rn * msz.y / u.size.y;
        float lod = log2(max(max(tang, rad), 1e-4));
        col = sampLod(m, q, lod, 1);
    }
    return finish(o, col, u.mixAmt);
}

// ===== タイル =====
// a = 横の数, 縦の数, 鏡(0 しない 1 横 2 縦 3 両方), 段のずれ / b = 流れ(横・縦, 枚), すき間, 1 枚ずつ回す(ラジアン)
static float parity(float x) { return x - 2.0 * floor(x * 0.5); }
fragment float4 m2_tile(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]],
                        texture2d<float> m [[texture(1)]]) {
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    float4 o = t.sample(sn, in.uv);
    float2 N = max(u.a.xy, float2(1.0));
    float2 q = in.uv * N;
    q.y += u.b.y;
    float row = floor(q.y);
    q.x += row * u.a.w + u.b.x;
    float2 cell = floor(q);
    float2 f = q - cell;
    int mm = int(u.a.z + 0.5);
    if ((mm == 1 || mm == 3) && parity(cell.x) > 0.5) f.x = 1.0 - f.x;
    if ((mm == 2 || mm == 3) && parity(cell.y) > 0.5) f.y = 1.0 - f.y;
    float g = saturate(u.b.z);
    float2 tp = u.size / N;                           // 1 枚の大きさ（画素）
    float2 f2 = (f - g * 0.5) / max(1.0 - g, 0.01);
    float rot = u.b.w;
    if (abs(rot) > 1e-5) {
        // 回した 1 枚が、マスからはみ出さない大きさに縮める
        float2 ts = tp * (1.0 - g);
        float ca = abs(cos(rot)), sa = abs(sin(rot));
        float fit = min(ts.x / (ts.x * ca + ts.y * sa), ts.y / (ts.x * sa + ts.y * ca));
        float2 d = (f2 - 0.5) * ts / fit;
        float cr = cos(-rot), sr = sin(-rot);
        d = float2(d.x * cr - d.y * sr, d.x * sr + d.y * cr);
        f2 = d / ts + 0.5;
    }
    float mask = 1.0;
    if (g > 0.0 || abs(rot) > 1e-5) {
        float2 dpx = min(f2, 1.0 - f2) * tp * (1.0 - g);
        mask = saturate(min(dpx.x, dpx.y) + 0.5);
    }
    float2 msz = float2(m.get_width(), m.get_height());
    float2 shrink = N / max(1.0 - g, 0.01) * msz / u.size;
    float lod = log2(max(shrink.x, shrink.y));
    float4 col = sampLod(m, saturate(f2), lod, 0) * mask;
    return finish(o, col, u.mixAmt);
}

// ===== キー抜き =====
// a = 何で抜く(0 暗い所 1 明るい所 2 色), しきい値, やわらかさ, 色の広さ / b = 色かぶりを取る, 逆, 形を見る / color = 抜く色
static float2 chroma(float3 c) { return float2(c.r - 0.5 * (c.g + c.b), 0.8660254 * (c.g - c.b)); }
fragment float4 m2_keyer(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    float4 o = t.sample(sn, in.uv);
    float3 rgb = o.a > 1e-4 ? o.rgb / o.a : float3(0.0);
    int mode = int(u.a.x + 0.5);
    float th = saturate(u.a.y), soft = max(u.a.z, 1e-4);
    float keep;
    if (mode == 0) {
        keep = smoothstep(th - soft, th, lum(rgb));
    } else if (mode == 1) {
        keep = 1.0 - smoothstep(1.0 - th, 1.0 - th + soft, lum(rgb));
    } else {
        float3 key = u.color.rgb;
        float d = length(chroma(rgb) - chroma(key));
        keep = smoothstep(u.a.w, u.a.w + soft, d);
        // 色かぶり：抜く色の向きの成分を引く（明るさの平均は変えない）
        float3 kz = key - (key.r + key.g + key.b) / 3.0;
        float kl = length(kz);
        if (kl > 1e-3 && u.b.x > 0.0) {
            float3 kn = kz / kl;
            float3 cz = rgb - (rgb.r + rgb.g + rgb.b) / 3.0;
            float pr = max(dot(cz, kn), 0.0);
            rgb = max(rgb - kn * pr * saturate(u.b.x), 0.0);
        }
    }
    if (u.b.y > 0.5) keep = 1.0 - keep;
    float a = o.a * keep;
    float4 col = u.b.z > 0.5 ? float4(float3(a), 1.0) : float4(rgb * a, a);
    return finish(o, col, u.mixAmt);
}

// ===== LED パネル =====
// a = マスの大きさ(この大きさでの画素), 形(0 丸 1 RGB の縦 3 本 2 四角), 粒の大きさ, 明るさ / b = にじみ, 継ぎ目, すき間を透明に
// d = 粒の中心からの位置(画素)。粒の形の距離（外が正、画素）
static float ledDist(float2 d, int shape, float cell, float sz, int ch) {
    if (shape == 0) return length(d) - cell * 0.5 * sz;
    if (shape == 2) {
        float h = cell * 0.5 * sz, cr = h * 0.25;
        float2 q = abs(d) - (h - cr);
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - cr;
    }
    // RGB の縦 3 本：ch 番目の線（マスを横に 3 つに分ける）
    float sub = cell / 3.0;
    float2 dd = d - float2((float(ch) - 1.0) * sub, 0.0);
    float2 hs = float2(sub * 0.5 * sz, cell * 0.5 * sz * 0.92);
    float cr = hs.x * 0.6;
    float2 q = abs(dd) - (hs - cr);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - cr;
}
fragment float4 m2_led(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    float4 o = t.sample(sn, in.uv);
    float cell = max(u.a.x, 2.0);
    int shape = int(u.a.y + 0.5);
    float sz = clamp(u.a.z, 0.05, 1.0);
    float glowAmt = saturate(u.b.x);
    float2 px = in.uv * u.size;
    float2 cid = floor(px / cell);
    float3 lit = 0.0; float cov = 0.0;
    float4 own = t.sample(s, (cid + 0.5) * cell / u.size);
    // にじみは、自分のマスと、画素に近い側の 3 つのマスから（4 つ）
    float2 fo = px / cell - cid - 0.5;
    float2 sd2 = float2(fo.x < 0.0 ? -1.0 : 1.0, fo.y < 0.0 ? -1.0 : 1.0);
    int nb = glowAmt > 0.001 ? 4 : 1;
    float gw = (shape == 1 ? cell / 3.0 : cell) * (0.06 + 0.22 * glowAmt);   // にじみの広がり（画素）
    float gk = glowAmt * 0.45;
    for (int j = 0; j < nb; j++) {
        float2 off = j == 0 ? float2(0.0) : (j == 1 ? float2(sd2.x, 0.0) : (j == 2 ? float2(0.0, sd2.y) : sd2));
        float2 id = cid + off;
        float4 c = j == 0 ? own : t.sample(s, (id + 0.5) * cell / u.size);
        float2 d = px - (id + 0.5) * cell;
        if (shape == 1) {
            for (int ch = 0; ch < 3; ch++) {
                float sd = ledDist(d, 1, cell, sz, ch);
                float mk = j == 0 ? saturate(0.5 - sd) : 0.0;
                float g = gk * exp(-pow(max(sd, 0.0) / gw, 2.0));
                lit[ch] += (mk + g) * c[ch] * 2.6;
                cov = max(cov, (mk + g) * c.a);
            }
        } else {
            float sd = ledDist(d, shape, cell, sz, 0);
            float mk = j == 0 ? saturate(0.5 - sd) : 0.0;
            float g = gk * exp(-pow(max(sd, 0.0) / gw, 2.0));
            lit += c.rgb * (mk + g);
            cov = max(cov, (mk + g) * c.a);
        }
    }
    // パネルの継ぎ目：8×8 粒ごとに明るさと色みが少し違い、さかい目に細い線
    float seam = saturate(u.b.y);
    if (seam > 0.0) {
        float2 pid = floor(cid / 8.0);
        float pv = 1.0 + (h2(pid) - 0.5) * 0.35 * seam;
        float3 tint = 1.0 + (float3(h2(pid + 3.1), h2(pid + 7.7), h2(pid + 1.9)) - 0.5) * 0.12 * seam;
        float pw = cell * 8.0;
        float2 e = fmod(px, pw);
        float2 de = min(e, pw - e);
        float lw = max(1.0, cell * 0.12);
        float line = 1.0 - seam * (1.0 - smoothstep(lw * 0.5, lw * 0.5 + 1.0, min(de.x, de.y)));
        lit *= pv * tint * line;
    }
    lit *= u.a.w;
    float a = u.b.z > 0.5 ? saturate(cov) : own.a;
    return finish(o, float4(lit, a), u.mixAmt);
}

// ===== スライス =====
// a = 向き(0 横の帯 1 縦の帯), 帯の数, ずれ(画面に対して), ずらし方(0 ランダム 1 互い違い 2 波 3 階段)
// b = 組み替えの番号, 組み替えの途中(0〜1, ease 済み), 幅をばらばらに, 色もずらす / c = 端, 位相(周), 動く(1)
static float h21(float a, float b) { return fract(sin(a * 127.1 + b * 311.7) * 43758.5453); }
fragment float4 m2_slices(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    float4 o = t.sample(sn, in.uv);
    bool vert = u.a.x > 0.5;
    float n = max(floor(u.a.y + 0.5), 1.0);
    float y = vert ? in.uv.x : in.uv.y;
    // 帯の幅をばらばらに：単調な（折り返さない）ゆがみ
    float w = saturate(u.b.z);
    float f1 = n * 0.31 + 1.0, f2 = n * 0.53 + 2.0;
    float g = y + w * (0.6 * sin(6.2831853 * f1 * y + 1.3) / (6.2831853 * f1) + 0.4 * sin(6.2831853 * f2 * y + 4.1) / (6.2831853 * f2));
    float band = floor(g * n);
    int mode = int(u.a.w + 0.5);
    float s = u.b.x, k = saturate(u.b.y);
    float v;
    if (mode == 0) {
        v = mix(h21(band, s) * 2.0 - 1.0, h21(band, s + 1.0) * 2.0 - 1.0, k);
    } else if (mode == 1) {
        float sg = parity(band) > 0.5 ? -1.0 : 1.0;
        float p0 = u.c.z > 0.5 ? (parity(s) > 0.5 ? -1.0 : 1.0) : 1.0;
        float p1 = u.c.z > 0.5 ? -p0 : p0;
        v = sg * mix(p0, p1, k);
    } else if (mode == 2) {
        v = sin(6.2831853 * ((band + 0.5) / n * 1.5 - u.c.y));
    } else {
        v = fract((band + 0.5) / n + u.c.y) * 2.0 - 1.0;
    }
    float off = v * u.a.z;
    float dc = u.b.w * 0.3 * off;
    int edge = int(u.c.x + 0.5);
    float2 dir = vert ? float2(0.0, 1.0) : float2(1.0, 0.0);
    float2 uv = in.uv + dir * off;
    float4 cg = sampEdge(t, uv, edge);
    float4 col = cg;
    if (abs(dc) > 1e-6) {
        float4 cr = sampEdge(t, uv + dir * dc, edge), cb = sampEdge(t, uv - dir * dc, edge);
        col = float4(cr.r, cg.g, cb.b, max(max(cr.a, cg.a), cb.a));
    }
    return finish(o, col, u.mixAmt);
}

// ===== ゆれ =====
// a = ずれ x・y(画素), 回る(ラジアン), 拡大 / b = 前からの動き x・y(画素), 前からの回り(ラジアン), ぶれ(1 で 5 回取る) / c.x = 端
static float2 shakeSrc(float2 px, float2 half_, float2 off, float rot, float sc) {
    float2 p = (px - half_ - off) / sc;
    float cr = cos(-rot), sr = sin(-rot);
    return float2(p.x * cr - p.y * sr, p.x * sr + p.y * cr) + half_;
}
fragment float4 m2_shake(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    float4 o = t.sample(sn, in.uv);
    float2 half_ = u.size * 0.5;
    float2 px = in.uv * u.size;
    int edge = int(u.c.x + 0.5);
    float sc = max(u.a.w, 0.01);
    float4 col;
    if (u.b.w > 0.5) {
        col = 0.0;
        // 5 回取る。取る所を画素ごとに少しずらして、段々に見えないように
        float jt = h2(in.pos.xy) - 0.5;
        for (int j = -2; j <= 2; j++) {
            float f = (float(j) + jt) / 4.0;
            float2 q = shakeSrc(px, half_, u.a.xy - u.b.xy * f, u.a.z - u.b.z * f, sc);
            col += sampEdge(t, q / u.size, edge);
        }
        col /= 5.0;
    } else {
        col = sampEdge(t, shakeSrc(px, half_, u.a.xy, u.a.z, sc) / u.size, edge);
    }
    return finish(o, col, u.mixAmt);
}

// ===================== 第 3 弾 =====================
static float vn2(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    return mix(mix(h2(i), h2(i + float2(1, 0)), w.x), mix(h2(i + float2(0, 1)), h2(i + float2(1, 1)), w.x), w.y);
}
// 縦（y）が周期 P で一周するノイズ（P は整数）。時間を P で余りにして渡しても、つなぎ目で跳ばない
static float vn2py(float2 p, float P) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float y0 = i.y - P * floor(i.y / P);
    float y1 = y0 + 1.0 >= P ? 0.0 : y0 + 1.0;
    return mix(mix(h2(float2(i.x, y0)), h2(float2(i.x + 1.0, y0)), w.x), mix(h2(float2(i.x, y1)), h2(float2(i.x + 1.0, y1)), w.x), w.y);
}
static float2 rot2(float2 p, float a) { float c = cos(a), s = sin(a); return float2(p.x * c - p.y * s, p.x * s + p.y * c); }

// ===== フィルム =====
// a = 粒子, 粒の大きさ(画素), 周辺を暗く, 周辺の広さ / b = 傷, ごみ, ちらつき / c = 色あせ, コマの番号, 上下のゆれ(uv)
fragment float4 m2_film(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    constexpr sampler sl(filter::linear, address::clamp_to_edge);
    float4 o = t.sample(sn, in.uv);
    float k = u.size.y / 1080.0;
    float f = u.c.y;
    float4 c = abs(u.c.z) > 1e-7 ? t.sample(sl, in.uv + float2(0.0, u.c.z)) : o;
    float a = c.a;
    float3 rgb = a > 1e-4 ? c.rgb / a : float3(0.0);
    float2 px = in.uv * u.size;
    // 色あせ：彩度を下げてセピアへ、黒を少し浮かせる
    if (u.c.x > 0.0) {
        float g = lum(rgb);
        rgb = mix(rgb, g * float3(1.07, 0.95, 0.77) * 0.92 + 0.05, saturate(u.c.x));
    }
    // ちらつき：全体の明るさがコマごとに少し変わる
    rgb *= 1.0 + (h21(f, 3.7) - 0.5) * u.b.z * 0.35;
    // 粒子：コマごとに変わる細かいノイズ（暗い所ほど目立つ）
    if (u.a.x > 0.0) {
        float cs = max(u.a.y, 0.5);
        float2 sh = float2(h21(f, 1.1), h21(f, 2.3)) * 512.0;
        float n = (vn2(px / cs + sh) - 0.5) + (vn2(px / cs * 2.03 + sh.yx) - 0.5) * 0.5;
        rgb += n * u.a.x * 0.32 * (1.15 - 0.5 * lum(rgb));
    }
    // 傷：縦の細い線がときどき走る（コマごとに 3 本まで）
    if (u.b.x > 0.0) {
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            if (h21(f, 10.0 + fi) < u.b.x * 0.7) {
                float x = h21(f, 20.0 + fi) * u.size.x + sin(in.uv.y * 9.0 + fi * 2.0) * 2.0 * k;
                float w = (0.6 + h21(f, 30.0 + fi) * 1.4) * k;
                float m = 1.0 - smoothstep(w * 0.5, w * 0.5 + 1.0, abs(px.x - x));
                m *= step(abs(in.uv.y - h21(f, 40.0 + fi)), 0.3 + h21(f, 50.0 + fi) * 0.7);
                rgb = mix(rgb, h21(f, 60.0 + fi) > 0.4 ? float3(0.92) : float3(0.04), m * 0.7);
            }
        }
    }
    // ごみ：黒い小さな点（マスごとにまれに 1 つ）
    if (u.b.y > 0.0) {
        float cell = 90.0 * k;
        float2 cid = floor(px / cell);
        if (h2(cid + f * 1.37) < u.b.y * 0.06) {
            float2 ctr = (cid + 0.25 + 0.5 * float2(h2(cid + f + 3.1), h2(cid + f + 7.7))) * cell;
            float rad = (1.5 + 4.0 * h2(cid + f + 9.2)) * k;
            float2 d = px - ctr;
            float dd = length(d) - rad * (0.6 + 0.8 * vn2(d / max(rad * 0.6, 1.0) + cid));
            rgb = mix(rgb, float3(0.03), (1.0 - smoothstep(-0.5, 0.8, dd)) * 0.85);
        }
    }
    // 周辺を暗く
    if (u.a.z > 0.0) {
        float d = length((in.uv - 0.5) * 2.0) / 1.41421;
        rgb *= 1.0 - saturate(u.a.z) * pow(saturate(d * 1.1 / max(u.a.w, 0.05)), 2.2);
    }
    return finish(o, float4(max(rgb, 0.0) * a, a), u.mixAmt);
}

// ===== ミニチュア風 =====
// a = 帯の位置, 帯の幅, やわらかさ, 角度(ラジアン) / b = 形(0 帯 1 丸), 彩度, コントラスト, b1 を広げる(1)
// c = b2 を広げる(1), ぼかしあり(1) / b1 = 半分の量でぼかした絵, b2 = 全部の量でぼかした絵
fragment float4 m2_tilt(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]],
                        texture2d<float> b1 [[texture(1)]], texture2d<float> b2 [[texture(2)]]) {
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    constexpr sampler sl(filter::linear, address::clamp_to_edge);
    float4 o = t.sample(sn, in.uv);
    float A = u.size.x / max(u.size.y, 1.0);
    float2 p = (in.uv - float2(0.5, u.a.x)) * float2(A, 1.0);
    float d = u.b.x > 0.5 ? length(p) : abs(dot(p, float2(-sin(u.a.w), cos(u.a.w))));
    float hw = u.a.y * 0.5;
    float f = smoothstep(hw, hw + max(u.a.z, 0.01) * 0.6, d);   // 0 ピント → 1 いちばんぼける
    float4 c = o;
    if (u.c.y > 0.5) {
        float4 x1 = u.b.w > 0.5 ? sampSmooth(b1, in.uv) : b1.sample(sl, in.uv);
        float4 x2 = u.c.x > 0.5 ? sampSmooth(b2, in.uv) : b2.sample(sl, in.uv);
        c = f < 0.5 ? mix(o, x1, f * 2.0) : mix(x1, x2, f * 2.0 - 1.0);
    }
    if (abs(u.b.y - 1.0) > 1e-4 || abs(u.b.z - 1.0) > 1e-4) {
        float a = c.a;
        float3 rgb = a > 1e-4 ? c.rgb / a : float3(0.0);
        rgb = mix(float3(lum(rgb)), rgb, u.b.y);
        rgb = (rgb - 0.5) * u.b.z + 0.5;
        c = float4(max(rgb, 0.0) * a, a);
    }
    return finish(o, c, u.mixAmt);
}

// ===== 浮き彫り =====
// a = 強さ, 光の向き(ラジアン), 太さ(画素), 色の残し方(0 灰色 1 元の色に重ねる 2 金属) / b = 元の絵, なめらかに
static float embH(texture2d<float> t, float2 uv, float2 e, float sm) {
    constexpr sampler sl(filter::linear, address::clamp_to_edge);
    float h = lum(t.sample(sl, uv).rgb);
    if (sm > 0.0) {
        float a = lum(t.sample(sl, uv + float2(e.x, e.y)).rgb) + lum(t.sample(sl, uv + float2(-e.x, e.y)).rgb)
                + lum(t.sample(sl, uv + float2(e.x, -e.y)).rgb) + lum(t.sample(sl, uv + float2(-e.x, -e.y)).rgb);
        h = mix(h, (h + a) / 5.0, saturate(sm));
    }
    return h;
}
fragment float4 m2_emboss(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    float4 o = t.sample(sn, in.uv);
    float w = max(u.a.z, 0.5);
    float2 L = float2(cos(u.a.y), -sin(u.a.y));       // 135° で左上から光
    float2 d = L * w / u.size;
    float2 e = float2(w * 1.5) / u.size;
    float sm = u.b.y;
    float g = embH(t, in.uv + d, e, sm) - embH(t, in.uv - d, e, sm);
    float s = 0.5 + g * u.a.x * 0.5;
    float a = o.a;
    float3 cu = a > 1e-4 ? o.rgb / a : float3(0.0);
    int mode = int(u.a.w + 0.5);
    float3 rgb;
    if (mode == 0) rgb = float3(saturate(s));
    else if (mode == 1) rgb = cu + (s - 0.5);
    else {
        float m = saturate((s - 0.5) * 2.2 + 0.35 + (lum(cu) - 0.5) * 0.4);
        rgb = float3(0.78, 0.80, 0.86) * m + pow(m, 6.0) * 0.6;
    }
    rgb = mix(rgb, cu, saturate(u.b.x));
    return finish(o, float4(saturate(rgb) * a, a), u.mixAmt);
}

// ===== 引き伸ばし =====
// a = 向き(0 右へ 1 左へ 2 下へ 3 上へ 4 両側へ), 位置, 位置の揺れ, 揺れの細かさ / b = 揺れの流れ, なじませ, 筋を足す
fragment float4 m2_stretch(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    constexpr sampler sl(filter::linear, address::clamp_to_edge);
    float4 o = t.sample(sn, in.uv);
    int dir = int(u.a.x + 0.5);
    bool vd = dir == 2 || dir == 3;
    float along = vd ? in.uv.y : in.uv.x;
    float across = vd ? in.uv.x : in.uv.y;
    // u.b.x は「流れ × 時間」を 1000 で余りにしたもの。ノイズも 1000 で一周させて、つなぎ目で跳ばないように
    float wob = (vn2py(float2(across * u.a.w, u.b.x), 1000.0) - 0.5) * u.a.z * 0.6;
    float p = u.a.y + wob;
    float past, lineAt = p;
    if (dir == 0 || dir == 2) past = along - p;
    else if (dir == 1 || dir == 3) past = p - along;
    else {
        // 両側へ：位置 = 真ん中に残す幅（1 で全部残る）
        float hw = u.a.y * 0.5 + wob;
        float dc = along - 0.5;
        past = abs(dc) - hw;
        lineAt = 0.5 + (dc < 0.0 ? -hw : hw);
    }
    if (past <= 0.0) return o;
    lineAt = saturate(lineAt);
    float4 c = t.sample(sl, vd ? float2(across, lineAt) : float2(lineAt, across));
    if (u.b.z > 0.0) {
        // 筋：1 行（1080p での 1 画素）ごとに少し明るさが違う
        float rowPx = across * (vd ? u.size.x : u.size.y) / max(u.size.y / 1080.0, 0.5);
        float row = floor(rowPx);
        float sv = h21(row, 3.3) * 0.7 + vn2(float2(row * 0.15, past * 4.0)) * 0.3 - 0.5;
        c.rgb = min(c.rgb * (1.0 + sv * u.b.z * 0.8), float3(c.a));
    }
    float m = u.b.y > 1e-4 ? smoothstep(0.0, u.b.y, past) : 1.0;
    return finish(o, mix(o, c, m), u.mixAmt);
}

// ===== 明るさでずらす =====
// a = ずれ(画素), 角度(ラジアン), 何で(0 明るさ 1 赤と緑 2 輪郭), 真ん中の明るさ / b = 色のずれ, 端, 地図を広げる(1)
// mp = ずらす地図（元の絵か、ぼかした絵）
fragment float4 m2_displace(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]],
                            texture2d<float> mp [[texture(1)]]) {
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    constexpr sampler sl(filter::linear, address::clamp_to_edge);
    float4 o = t.sample(sn, in.uv);
    bool smooth = u.b.z > 0.5;
    float4 m = smooth ? sampSmooth(mp, in.uv) : mp.sample(sl, in.uv);
    int mode = int(u.a.z + 0.5);
    float mid = u.a.w;
    float2 off;
    if (mode == 0) {
        off = float2(cos(u.a.y), sin(u.a.y)) * (lum(m.rgb) - mid);
    } else if (mode == 1) {
        off = rot2(float2(m.r - mid, m.g - mid), u.a.y);
    } else {
        float2 e = 2.0 / float2(mp.get_width(), mp.get_height());
        float gx = lum(mp.sample(sl, in.uv + float2(e.x, 0)).rgb) - lum(mp.sample(sl, in.uv - float2(e.x, 0)).rgb);
        float gy = lum(mp.sample(sl, in.uv + float2(0, e.y)).rgb) - lum(mp.sample(sl, in.uv - float2(0, e.y)).rgb);
        float2 g = float2(gx, gy);
        float gl = length(g);
        off = rot2(g / (gl + 1e-4) * min(gl * 6.0, 1.0) * 0.5, u.a.y);
    }
    off *= u.a.x / u.size;
    int edge = int(u.b.y + 0.5);
    float4 cg = sampEdge(t, in.uv + off, edge);
    float4 col = cg;
    if (u.b.x > 0.0) {
        float4 cr = sampEdge(t, in.uv + off * (1.0 + u.b.x * 0.5), edge), cb = sampEdge(t, in.uv + off * (1.0 - u.b.x * 0.5), edge);
        col = float4(cr.r, cg.g, cb.b, max(max(cr.a, cg.a), cb.a));
    }
    return finish(o, col, u.mixAmt);
}

// ===== 入れ子（ドロステ） =====
// a = 縮む割合, 数, 1 段の角度(ラジアン), 寄っていく量(0〜1) / b = 中心x, 中心y, 枠(高さに対する割合), 形(0 四角 1 丸) / c.x = 外も埋める
static float drD(float2 p, float A, bool rnd) { return rnd ? length(p) / 0.5 : max(abs(p.x) / (0.5 * A), abs(p.y) / 0.5); }
fragment float4 m2_droste(VO in [[stage_in]], constant MU& u [[buffer(0)]], texture2d<float> t [[texture(0)]],
                          texture2d<float> m [[texture(1)]]) {
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    float4 o = t.sample(sn, in.uv);
    float A = u.size.x / max(u.size.y, 1.0);
    float2 asp = float2(A, 1.0);
    float2 c = u.b.xy;
    float2 p = (in.uv - c) * asp;
    float s = clamp(u.a.x, 0.05, 0.99);
    float n = max(floor(u.a.y + 0.5), 1.0);
    float ang = u.a.z, z = u.a.w;
    bool rnd = u.b.w > 0.5;
    float d = max(drD(p, A, rnd), 1e-6);
    float k = floor(log(d) / log(s) + z);              // どの段にいるか（外が 0、内へ 1, 2, …）
    // 段ごとに回すと、さかい目も回るので直す
    for (int it = 0; it < 2; it++) {
        float dq = drD(rot2(p, -(k - z) * ang) / pow(s, k - z), A, rnd);
        if (dq > 1.0) k -= 1.0; else if (dq <= s) k += 1.0;
    }
    k = clamp(k, u.c.x > 0.5 ? -40.0 : 0.0, n - 1.0);
    float sc = pow(s, k - z);
    float2 q = rot2(p, -(k - z) * ang) / sc;
    float lod = (k - z) * -log2(s);
    float4 col = sampLod(m, q / asp + c, lod, 0);
    // 枠：内側の段のふちに線（色は「色」）
    if (u.b.z > 0.0 && k - z > 1e-4) {
        float ed = rnd ? 0.5 - length(q) : min(0.5 * A - abs(q.x), 0.5 - abs(q.y));
        float mk = saturate((u.b.z - ed * sc) * u.size.y + 0.5);
        col = mix(col, float4(u.color.rgb, 1.0), mk * step(0.0, ed + 1e-3));
    }
    return finish(o, col, u.mixAmt);
}
"""

/// 追加のエフェクト（第 2 弾）を描く
final class MoreFX2Renderer {
    static let shared = MoreFX2Renderer()
    let device = MetalContext.shared.device
    private var pipes: [String: MTLRenderPipelineState] = [:]
    /// 作業用の絵（名前と大きさごとに 1 枚。ぼかしの縮めた絵・ミップマップ付きの元の絵など）。
    /// 大きさの違う段（クリップ・コンポジション・見本）で交互に使っても作り直さないよう、大きさごとに持ち、
    /// 数が上限を超えたら、いちばん長く使っていないものを 1 枚だけ捨てる。
    /// また、新しく作るときに、しばらく（idleSeconds 秒）使っていないものは捨てる
    /// （解像度の違うクリップや、出力の大きさを変えたあとの古い大きさの絵が、残り続けないように）
    private var texCache: [String: (tex: MTLTexture, used: UInt64, at: Double)] = [:]
    private var useCounter: UInt64 = 0
    static let maxCachedTextures = 64
    static let idleSeconds: Double = 5
    /// テスト用：作業用の絵を作った回数
    private(set) var texturesMade = 0
    /// テスト用：時計を進める（秒）
    var testClockOffset: Double = 0
    /// テスト用：いま持っている作業用の絵の名前（名前-幅x高さ）
    var cachedTextureKeys: [String] { Array(texCache.keys) }

    private init() {
        let lib = try! device.makeLibrary(source: moreFX2Source, options: nil)
        func r(_ f: String, _ fmt: MTLPixelFormat = .bgra8Unorm) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "m2_full")
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = fmt
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        for f in ["m2_copy", "m2_blurOut", "m2_blurLast", "m2_lens", "m2_polar", "m2_tile", "m2_keyer", "m2_led", "m2_slices", "m2_shake",
                  "m2_film", "m2_tilt", "m2_emboss", "m2_stretch", "m2_displace", "m2_droste"] { pipes[f] = r(f) }
        for f in ["m2_copy", "m2_down", "m2_blur"] { pipes[f + "16"] = r(f, .rgba16Float) }
    }

    private func pipe(_ name: String) -> MTLRenderPipelineState { pipes[name]! }

    /// 作業用の絵（rgba16Float）。名前と大きさ（とミップマップの有無）ごとに 1 枚
    private func tex(_ name: String, _ w: Int, _ h: Int, mip: Bool = false) -> MTLTexture? {
        let W = max(w, 1), H = max(h, 1)
        let key = "\(name)-\(W)x\(H)\(mip ? "m" : "")"
        useCounter += 1
        let now = ProcessInfo.processInfo.systemUptime + testClockOffset
        if let c = texCache[key] {
            texCache[key] = (c.tex, useCounter, now)
            return c.tex
        }
        // しばらく使っていないものを捨てる（GPU はもう使い終わっている）
        texCache = texCache.filter { now - $0.value.at <= Self.idleSeconds }
        if texCache.count >= Self.maxCachedTextures, let old = texCache.min(by: { $0.value.used < $1.value.used })?.key {
            texCache[old] = nil
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: W, height: H, mipmapped: mip)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        guard let t = device.makeTexture(descriptor: td) else { return nil }
        texCache[key] = (t, useCounter, now)
        texturesMade += 1
        return t
    }

    /// 元の絵を、ミップマップ付きの絵に写す
    private func mipSource(_ input: MTLTexture, cb: MTLCommandBuffer) -> MTLTexture? {
        guard let m = tex("mip", input.width, input.height, mip: true) else { return nil }
        MoreFXRenderer.shared.pass(m, pipe("m2_copy16"), cb: cb) { enc in enc.setFragmentTexture(input, index: 0) }
        guard let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.generateMipmaps(for: m)
        blit.endEncoding()
        return m
    }

    /// 動きの元になるなめらかなノイズ（-1〜1）
    static func noise1(_ x: Double, seed: Double) -> Double {
        func h(_ i: Double) -> Double { let v = sin(i * 12.9898 + seed * 78.233) * 43758.5453; return v - floor(v) }
        let i = floor(x), f = x - i
        let w = f * f * (3 - 2 * f)
        return (h(i) * (1 - w) + h(i + 1) * w) * 2 - 1
    }

    /// ゆれ：t 秒のときのずれ（画素）・回り（ラジアン）・拡大
    static func shakePose(_ t: Double, amp: Double, speed: Double, type: Int, rotMax: Double, zoom: Double)
        -> (off: SIMD2<Double>, rot: Double, scale: Double) {
        var nx: Double, ny: Double, nr: Double
        let x = t * speed
        if type == 1 {
            // がたがた：1 回ごとにばらばらの所へ跳ぶ
            let s = floor(x)
            func h(_ k: Double) -> Double { let v = sin(s * 12.9898 + k * 78.233) * 43758.5453; return (v - floor(v)) * 2 - 1 }
            nx = h(1); ny = h(2); nr = h(3)
        } else {
            nx = noise1(x, seed: 1) * 0.7 + noise1(x * 2.3, seed: 2) * 0.3
            ny = noise1(x, seed: 3) * 0.7 + noise1(x * 2.3, seed: 4) * 0.3
            nr = noise1(x * 0.8, seed: 5)
        }
        if type == 2 { ny = 0 }
        if type == 3 { nx = 0 }
        let pulse = 0.5 - 0.5 * cos(2 * .pi * x)
        return (SIMD2(nx * amp, ny * amp), nr * rotMax, 1 + zoom * pulse)
    }

    func render(_ e: Effect, input: MTLTexture, into dst: MTLTexture, now: Double, stack: EffectStack, mixAmt: Float, cb: MTLCommandBuffer) {
        let base = MoreFXRenderer.shared
        func v(_ i: Int) -> Float { i < e.kind.params.count ? Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) : 0 }
        func c(_ i: Int) -> Int { Int(v(i).rounded()) }
        var u = base.uniforms(e, dst: dst, now: now, stack: stack, mixAmt: mixAmt)
        let k = Float(dst.height) / 1080
        let deg = Float.pi / 180
        let elapsed = max(now - stack.origin, 0)
        /// 量が 0 のときは元の絵そのまま
        func copy() {
            base.pass(dst, pipe("m2_copy"), cb: cb) { enc in enc.setFragmentTexture(input, index: 0) }
        }
        func one(_ name: String, mip: Bool = false) {
            let m = mip ? mipSource(input, cb: cb) : nil
            if mip && m == nil { return }
            base.pass(dst, pipe(name), cb: cb) { enc in
                enc.setFragmentBytes(&u, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
                enc.setFragmentTexture(input, index: 0)
                if let m { enc.setFragmentTexture(m, index: 1) }
            }
        }
        switch e.kind {
        case .blur:
            blur(e, v: v, input: input, into: dst, u: u, cb: cb, copy: copy)
        case .lens:
            if v(1) <= 0.0005 { copy(); return }
            u.a = SIMD4(Float(c(0)), v(1), v(2), v(5))
            u.b = SIMD4(v(3), v(4), Float([0, 1, 2][min(max(c(6), 0), 2)]), 0)
            one("m2_lens", mip: true)
        case .polar:
            // 回す（周）：角度 + 回る速さ × 時間 / 半径のずれ：ずれ + 流れる速さ × 時間
            let turn = (Double(v(1)) + Double(v(2)) * elapsed) / 360
            let flow = Double(v(4)) + Double(v(5)) * elapsed
            u.a = SIMD4(Float(c(0)), Float(turn.truncatingRemainder(dividingBy: 1)), v(3), Float(flow.truncatingRemainder(dividingBy: 2)))
            u.b = SIMD4(v(6), v(7), v(8), v(9))
            one("m2_polar", mip: true)
        case .tile:
            let nx = max(v(0), 1), ny = v(2) > 0.5 ? nx : max(v(1), 1)
            let fx = (Double(v(5)) * elapsed).truncatingRemainder(dividingBy: 1000)
            let fy = (Double(v(6)) * elapsed).truncatingRemainder(dividingBy: 1000)
            u.a = SIMD4(nx, ny, Float(c(3)), v(4))
            u.b = SIMD4(Float(fx), Float(fy), v(7), v(8) * deg)
            one("m2_tile", mip: true)
        case .keyer:
            u.a = SIMD4(Float(c(0)), v(1), v(2), v(3))
            u.b = SIMD4(v(4), v(5), v(6), 0)
            one("m2_keyer")
        case .ledWall:
            u.a = SIMD4(max(v(0) * k, 2), Float(c(1)), v(2), v(3))
            u.b = SIMD4(v(4), v(5), v(6), 0)
            one("m2_led")
        case .slices:
            if v(2) <= 0.0005 { copy(); return }
            let rate = Double(v(4))
            let x = rate * elapsed
            let s = floor(x)
            // なめらかに：組み替えの終わりの「なめらか」の割合だけ、ease でつなぐ
            let sm = Double(v(5))
            let fr = x - s
            var kk = 0.0
            if rate > 0 && sm > 0.001 {
                let a = min(max((fr - (1 - sm)) / sm, 0), 1)
                kk = a * a * (3 - 2 * a)
            }
            u.a = SIMD4(Float(c(0)), v(1), v(2), Float(c(3)))
            u.b = SIMD4(Float(s.truncatingRemainder(dividingBy: 10000)), Float(kk), v(6), v(7))
            u.c = SIMD4(Float([1, 0, 2][min(max(c(8), 0), 2)]), Float((x * 0.25).truncatingRemainder(dividingBy: 1)), rate > 0 ? 1 : 0, 0)
            one("m2_slices")
        case .shake:
            if v(0) <= 0.0005 { copy(); return }
            let amp = Double(v(0) * k)
            let speed = Double(v(1))
            let type = c(2)
            // ゆれを 0 にすると全部止まるように、回る・ズームの脈はゆれ 0〜20 px の間で 0 から決めた量まで強くなる
            let gain = min(Double(v(0)) / 20, 1)
            let rotMax = Double(v(3) * deg) * gain
            let zoom = Double(v(4)) * gain
            let p = Self.shakePose(elapsed, amp: amp, speed: speed, type: type, rotMax: rotMax, zoom: zoom)
            let q = Self.shakePose(max(elapsed - 1.0 / 30, 0), amp: amp, speed: speed, type: type, rotMax: rotMax, zoom: zoom)
            let edgeChoice = c(6)
            var scale = p.scale
            if edgeChoice == 3 {
                // 少し拡大して隠す：いちばん大きくずれても端が見えないだけ拡大（いつも同じ大きさ）
                let W = Double(dst.width), H = Double(dst.height)
                let mx = type == 3 ? 0 : amp, my = type == 2 ? 0 : amp
                let th = rotMax
                let rotFit = cos(th) + max(W / H, H / W) * sin(th)
                scale *= max((W + 2 * mx) / W, (H + 2 * my) / H) * rotFit
            }
            let blur = Double(v(5))
            let dOff = (p.off - q.off) * blur
            let dRot = (p.rot - q.rot) * blur
            let moving = blur > 0.001 && (simd_length(dOff) > 0.3 || abs(dRot) * Double(dst.height) > 0.3)
            u.a = SIMD4(Float(p.off.x), Float(p.off.y), Float(p.rot), Float(scale))
            u.b = SIMD4(Float(dOff.x), Float(dOff.y), Float(dRot), moving ? 1 : 0)
            u.c = SIMD4(Float([0, 1, 2, 0][min(max(edgeChoice, 0), 3)]), 0, 0, 0)
            one("m2_shake")
        case .film:
            let vals = [v(0), v(2), v(4), v(5), v(6), v(7), v(8)]
            if vals.allSatisfy({ $0 <= 0.0005 }) { copy(); return }
            let fps = Double(max(v(9), 1))
            let fr = floor(elapsed * fps)
            func h(_ x: Double) -> Double { let s = sin(x * 12.9898 + 4.1) * 43758.5453; return s - floor(s) }
            // ゆれ：コマが上下に少し跳ねる（ときどき大きく）
            var jump = (h(fr) - 0.5) * 0.012
            if h(fr + 0.37) > 0.93 { jump *= 3 }
            u.a = SIMD4(v(0), v(1) * k, v(2), v(3))
            u.b = SIMD4(v(4), v(5), v(6), 0)
            u.c = SIMD4(v(8), Float(fr.truncatingRemainder(dividingBy: 9973)), Float(jump) * v(7), 0)
            one("m2_film")
        case .tiltShift:
            let amount = v(0) * k
            let sat = v(6), con = v(7)
            if amount <= 0.01 && abs(sat - 1) < 1e-4 && abs(con - 1) < 1e-4 { copy(); return }
            u.a = SIMD4(v(1), v(2), v(3), v(4) * deg)
            u.b = SIMD4(Float(c(5)), sat, con, 0)
            var b1: MTLTexture = input, b2: MTLTexture = input
            if amount > 0.01 {
                // ぼかしの量が場所で変わるのを、半分の量・全部の量の 2 枚との混ぜで近似
                guard let r1 = blurTex(input, sigma: amount * 0.25, tag: "t1", u: u, cb: cb),
                      let r2 = blurTex(input, sigma: amount * 0.5, tag: "t2", u: u, cb: cb) else { return }
                b1 = r1.tex; b2 = r2.tex
                u.b.w = r1.smooth ? 1 : 0
                u.c = SIMD4(r2.smooth ? 1 : 0, 1, 0, 0)
            }
            base.pass(dst, pipe("m2_tilt"), cb: cb) { enc in
                enc.setFragmentBytes(&u, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
                enc.setFragmentTexture(input, index: 0)
                enc.setFragmentTexture(b1, index: 1)
                enc.setFragmentTexture(b2, index: 2)
            }
        case .emboss:
            if v(0) <= 0.0005 && c(4) == 1 { copy(); return }
            let angle = (Double(v(1)) + Double(v(2)) * elapsed).truncatingRemainder(dividingBy: 360)
            u.a = SIMD4(v(0), Float(angle) * deg, v(3) * k, Float(c(4)))
            u.b = SIMD4(v(5), v(6), 0, 0)
            one("m2_emboss")
        case .stretch:
            u.a = SIMD4(Float(c(0)), v(1), v(2), v(3))
            // 1000 で余りにする（シェーダーのノイズも 1000 で一周する）。負の流れでも 0〜1000 に
            let flow = Double(v(4)) * elapsed
            u.b = SIMD4(Float(flow - 1000 * floor(flow / 1000)), v(5), v(6), 0)
            one("m2_stretch")
        case .displace:
            let amount = v(0) * k
            if amount <= 0.01 { copy(); return }
            u.a = SIMD4(amount, v(1) * deg, Float(c(2)), v(4))
            u.b = SIMD4(v(5), Float([0, 1, 2][min(max(c(6), 0), 2)]), 0, 0)
            var map: MTLTexture = input
            if v(3) > 0.001 {
                // ずらす地図を先にぼかす（なめらかなゆがみ）
                guard let r = blurTex(input, sigma: (2 + v(3) * 30) * k, tag: "d", u: u, cb: cb) else { return }
                map = r.tex
                u.b.z = r.smooth ? 1 : 0
            }
            base.pass(dst, pipe("m2_displace"), cb: cb) { enc in
                enc.setFragmentBytes(&u, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
                enc.setFragmentTexture(input, index: 0)
                enc.setFragmentTexture(map, index: 1)
            }
        case .droste:
            let ang = (Double(v(2)) + Double(v(3)) * elapsed) * Double.pi / 180
            let zoom = Double(v(4)) * elapsed
            u.a = SIMD4(v(0), v(1), Float(ang.truncatingRemainder(dividingBy: 2 * .pi)), Float(zoom - floor(zoom)))
            u.b = SIMD4(v(5), v(6), v(7), Float(c(8)))
            u.c = SIMD4(v(9), 0, 0, 0)
            one("m2_droste", mip: true)
        default:
            return
        }
    }

    /// ぼかした絵を作る（ぼかし・ミニチュア風・明るさでずらすで使う）。sigma は input の画素。
    /// 広いときは半分ずつ縮めてからぼかす。返す絵が縮めたもの（smooth）なら、B スプラインで広げて取る
    func blurTex(_ input: MTLTexture, sigma: Float, horiz: Bool = true, vert: Bool = true, edge: Float = 0, tag: String,
                 u: MoreFXUniforms, cb: MTLCommandBuffer) -> (tex: MTLTexture, smooth: Bool)? {
        let base = MoreFXRenderer.shared
        var D = 1
        while sigma / Float(D) > (D == 1 ? 2 : 3), D < 64 { D *= 2 }
        var src = input
        var level = 1
        while level < D {
            level *= 2
            let w = horiz ? max(input.width / level, 1) : input.width
            let h = vert ? max(input.height / level, 1) : input.height
            guard let t = tex("blurL\(level)\(horiz ? "h" : "")\(vert ? "v" : "")", w, h) else { return nil }
            base.pass(t, pipe("m2_down16"), cb: cb) { enc in enc.setFragmentTexture(src, index: 0) }
            src = t
        }
        let sl = sigma / Float(D)
        let w = src.width, h = src.height
        guard let a = tex("blurA" + tag, w, h), let b = tex("blurB" + tag, w, h) else { return nil }
        var cur = src
        if horiz {
            var hu = u; hu.b = SIMD4(1 / Float(w), 0, sl, edge)
            let out = vert ? b : a
            base.pass(out, pipe("m2_blur16"), cb: cb) { enc in
                enc.setFragmentBytes(&hu, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
                enc.setFragmentTexture(cur, index: 0)
            }
            cur = out
        }
        if vert {
            var vu = u; vu.b = SIMD4(0, 1 / Float(h), sl, edge)
            base.pass(a, pipe("m2_blur16"), cb: cb) { enc in
                enc.setFragmentBytes(&vu, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
                enc.setFragmentTexture(cur, index: 0)
            }
            cur = a
        }
        return (cur, D > 1)
    }

    /// ぼかし：縮めないときは、最後の向きのぼかしと重ねるのを 1 回で
    private func blur(_ e: Effect, v: (Int) -> Float, input: MTLTexture, into dst: MTLTexture, u: MoreFXUniforms, cb: MTLCommandBuffer,
                      copy: () -> Void) {
        let base = MoreFXRenderer.shared
        let amount = v(0) * Float(dst.height) / 1080
        if amount <= 0.01 { copy(); return }
        let kind = Int(v(1).rounded())
        let edge: Float = Int(v(3).rounded()) == 1 ? 2 : 0
        let horiz = kind != 2, vert = kind != 1
        // 量 = おおよその半径（シグマの 2 倍）
        let sigma = amount * 0.5
        if sigma <= 2 {
            let w = input.width, h = input.height
            var last = u
            last.a = SIMD4(v(2), 0, 0, 0)
            var lastSrc = input
            if horiz && vert {
                guard let a = tex("blurA", w, h) else { return }
                var hu = u; hu.b = SIMD4(1 / Float(w), 0, sigma, edge)
                base.pass(a, pipe("m2_blur16"), cb: cb) { enc in
                    enc.setFragmentBytes(&hu, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
                    enc.setFragmentTexture(input, index: 0)
                }
                lastSrc = a
            }
            last.b = vert ? SIMD4(0, 1 / Float(h), sigma, edge) : SIMD4(1 / Float(w), 0, sigma, edge)
            base.pass(dst, pipe("m2_blurLast"), cb: cb) { enc in
                enc.setFragmentBytes(&last, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
                enc.setFragmentTexture(input, index: 0)
                enc.setFragmentTexture(lastSrc, index: 1)
            }
            return
        }
        guard let r = blurTex(input, sigma: sigma, horiz: horiz, vert: vert, edge: edge, tag: "", u: u, cb: cb) else { return }
        var o = u; o.a = SIMD4(v(2), r.smooth ? 1 : 0, 0, 0)
        base.pass(dst, pipe("m2_blurOut"), cb: cb) { enc in
            enc.setFragmentBytes(&o, length: MemoryLayout<MoreFXUniforms>.stride, index: 0)
            enc.setFragmentTexture(input, index: 0)
            enc.setFragmentTexture(r.tex, index: 1)
        }
    }
}
