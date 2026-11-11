import Metal
import AppKit
import QuartzCore
import CoreVideo
import simd

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    VOut o;
    o.pos = float4(p[vid], 0, 1);
    return o;
}

struct Uniforms {
    float3x3 hinv;     // 出力座標(0..1) -> 映像UV(0..1) への射影変換
    float2 viewSize;
    int mode;          // 0: 黒, 1: 映像, 2: テストパターン
    float master;      // マスター不透明度
};

static float4 testPattern(float2 uv, float2 px) {
    float2 g = uv * float2(16.0, 9.0);
    float2 fw = fwidth(g) * 1.2;
    float2 f = fract(g);
    float grid = max(step(f.x, fw.x) + step(1.0 - fw.x, f.x), step(f.y, fw.y) + step(1.0 - fw.y, f.y));
    float2 e = min(uv, 1.0 - uv) / fwidth(uv);
    float border = step(min(e.x, e.y), 4.0);
    float diag = step(abs(uv.x - uv.y) / fwidth(uv.x - uv.y), 1.0) + step(abs(uv.x + uv.y - 1.0) / fwidth(uv.x + uv.y), 1.0);
    float3 c = float3(0.12);
    c = mix(c, float3(0.8), saturate(grid));
    c = mix(c, float3(0.2, 0.7, 1.0), saturate(diag));
    c = mix(c, float3(1.0, 0.2, 0.2), border);
    return float4(c, 1.0);
}

fragment float4 fmain(VOut in [[stage_in]],
                      constant Uniforms& u [[buffer(0)]],
                      texture2d<float> tex [[texture(0)]],
                      sampler s [[sampler(0)]]) {
    float2 q = in.pos.xy / u.viewSize;
    float3 h = u.hinv * float3(q, 1.0);
    if (h.z <= 0.0) return float4(0, 0, 0, 1);
    float2 uv = h.xy / h.z;
    if (any(uv < 0.0) || any(uv > 1.0)) return float4(0, 0, 0, 1);
    if (u.mode == 2) return testPattern(uv, in.pos.xy);
    if (u.mode == 0) return float4(0, 0, 0, 1);
    // 大きな合成の絵を小さな画面（出力モニターなど）に縮めて出すときは、4 点を平均してちらつきを抑える
    float2 duv = fwidth(uv);
    float2 texel = duv * float2(tex.get_width(), tex.get_height());
    if (max(texel.x, texel.y) > 1.25) {
        float2 o = duv * 0.25;
        float3 c = tex.sample(s, uv + float2(-o.x, -o.y)).rgb + tex.sample(s, uv + float2(o.x, -o.y)).rgb
                 + tex.sample(s, uv + float2(-o.x, o.y)).rgb + tex.sample(s, uv + float2(o.x, o.y)).rgb;
        return float4(c * 0.25 * u.master, 1.0);
    }
    return float4(tex.sample(s, uv).rgb * u.master, 1.0);
}

// レイヤー合成。重ね方そのものはパイプラインのブレンド設定で決まる（Compositor 参照）
struct LayerUniforms {
    float3x3 inv;      // 出力のピクセル → クリップの UV（クリップ・レイヤー・コンポジションのトランスフォームを合成した逆行列）
    float opacity;
    int blend;         // 0: 通常, 1: 加算, 2: スクリーン, 3: 乗算
    int premul;        // 1: 色に不透明度が掛かった絵（レイヤーのエフェクトを通した絵）、2: 調整レイヤー（下の絵と置き換える）
};

fragment float4 flayer(VOut in [[stage_in]],
                       constant LayerUniforms& u [[buffer(0)]],
                       texture2d<float> tex [[texture(0)]],
                       sampler s [[sampler(0)]]) {
    float2 uv = (u.inv * float3(in.pos.xy, 1.0)).xy;
    // クリップの外は透明。縁は 1 ピクセルぶんぼかしてギザギザを抑える
    float2 e = min(uv, 1.0 - uv) / max(fwidth(uv), float2(1e-6));
    float cover = saturate(min(e.x, e.y) + 0.5);
    float4 c = tex.sample(s, saturate(uv));
    if (u.blend == 5 || u.blend == 6) {
        // マスク：明るさ（クリップの外は 0）で下の絵を残す。不透明度でかかり具合
        float3 rgb = u.premul == 1 ? c.rgb : c.rgb * c.a;
        float l = saturate(dot(rgb, float3(0.2126, 0.7152, 0.0722))) * cover;
        if (u.blend == 6) l = 1.0 - l;
        float m = mix(1.0, l, saturate(u.opacity));
        return float4(m, m, m, 1.0);
    }
    if (u.premul == 2) {
        // 調整レイヤー：エフェクトを通した絵で、下の絵を置き換える（不透明度の割合で）。
        // マスクで透明になった所は黒くなる（下の絵を切り抜く）
        float k = saturate(u.opacity * cover);
        return float4(c.rgb * k, k);
    }
    if (u.premul == 1) {
        float cov = saturate(u.opacity * cover);
        float k = c.a * cov;
        if (u.blend == 3) return float4(mix(float3(1.0), c.rgb / max(c.a, 1e-4), k), 1.0);
        return float4(c.rgb * cov, k);
    }
    float k = saturate(c.a * u.opacity * cover);
    if (u.blend == 3) return float4(mix(float3(1.0), c.rgb, k), 1.0);
    return float4(c.rgb * k, k);
}

// エフェクト（1 つずつ）。入出力は「色に不透明度が掛かった」絵
struct EffectUniforms {
    int kind;          // 0: ミラー, 1: カラーライズ, 2: レベル, 3: ポスタライズ, 4: ストロボ（エコーは fecho）
    float4 a;
    float4 b;
    float2 size;
    float4 color;      // カラーライズの色
    float4 pal[8];     // カラーライズのパレット（暗い → 明るい）
    int palCount;
    int ptCount;       // 自由な形のマスク：点の数と、点（ピクセル。1 つの float4 に 2 点）
    float4 pts[16];
    float mixAmt;      // エフェクトの不透明度（0 = 元の絵、1 = いっぱいにかかる）
};


// ---- ジェネレーター（動画の代わりに置く絵）。入力の絵は使わず、大きさだけ見る ----
static float ghash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float gnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    return mix(mix(ghash(i), ghash(i + float2(1, 0)), w.x), mix(ghash(i + float2(0, 1)), ghash(i + float2(1, 1)), w.x), w.y);
}
static float2 grot(float2 p, float deg) {
    float a = deg * 3.14159265 / 180.0;
    return float2(p.x * cos(a) + p.y * sin(a), -p.x * sin(a) + p.y * cos(a));
}
// パレット（n 色を順になめらかにつなぐ）の x（0〜1）の色
static float3 gpal(constant float4* pal, int count, float x) {
    int n = max(count, 1);
    if (n == 1) return pal[0].rgb;
    float t = saturate(x) * float(n - 1);
    int i = min(int(floor(t)), n - 2);
    return mix(pal[i].rgb, pal[i + 1].rgb, t - float(i));
}
// ふち（sd：中がマイナス）を aa の幅でなめらかにした不透明度
static float gcover(float sd, float aa) { return 1.0 - smoothstep(-aa, aa, sd); }

// マスク：m（1 = 見える、0 = 隠す）を、ふちのぼかしの幅 f（px）で、形からの距離 sd（中がマイナス）から決める
static float maskFrom(float sd, float f) { return saturate(0.5 - sd / max(f, 1.0)); }

constant float bayer4[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

static float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}

static float3 hsv2rgb(float3 c) {
    float3 p = abs(fract(c.xxx + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), saturate(p - 1.0), c.y);
}

static float3 hueShift(float3 c, float h) {
    float3 hsv = rgb2hsv(c);
    hsv.x = fract(hsv.x + h);
    return hsv2rgb(hsv);
}

static float3 pureHue(float h) {
    float3 k = abs(fract(float3(h) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return saturate(k - 1.0);
}

static float4 effectBody(VOut in, constant EffectUniforms& u, texture2d<float> tex, texture2d<float> aux, sampler s);
static bool isGenerator(int k) { return (k >= 8 && k <= 13) || (k >= 15 && k <= 20); }

fragment float4 feffect(VOut in [[stage_in]],
                        constant EffectUniforms& u [[buffer(0)]],
                        texture2d<float> tex [[texture(0)]],
                        texture2d<float> aux [[texture(1)]],
                        sampler s [[sampler(0)]]) {
    float4 r = effectBody(in, u, tex, aux, s);
    // 不透明度：元の絵とエフェクトをかけた絵を混ぜる（ジェネレーターは元の絵が無いのでそのまま）
    if (u.mixAmt >= 0.999 || isGenerator(u.kind)) return r;
    return mix(tex.sample(s, in.pos.xy / u.size), r, saturate(u.mixAmt));
}

static float pmod(float x, float m) { return x - m * floor(x / m); }

// 波長（nm）の色（見える光の範囲をなめらかに近似）
static float3 spectralColor(float lam) {
    float r = exp(-pow((lam - 605.0) / 48.0, 2.0)) + 0.28 * exp(-pow((lam - 430.0) / 22.0, 2.0));
    float g = exp(-pow((lam - 545.0) / 45.0, 2.0));
    float b = exp(-pow((lam - 452.0) / 34.0, 2.0));
    return float3(r, g, b);
}

// 3D の地形・点の雲：画面の高さ y に、傾き a（横の傾き b は無いとして）の板の上で、平らなら何番目の列が来るか
// （列の番号 = v × n + 動いた量）。y が地平線より上なら、とても大きな数
static float terrainRowAt(float y, float a, float b, float n, float moved) {
    const float D = 1.6;
    float den = D * cos(a) - y * sin(a);
    if (den <= 1e-4) return 1e6;
    float v = y * D / den;
    // 横にも傾けているときは、ずれる分をゆとりで見る
    return (v - abs(sin(b)) * 1.5) * n + moved;
}

// ---- ドット（粒） ----
static float2 dhash2(float2 p) {
    return fract(sin(float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)))) * 43758.5453);
}
// 粒の形の「大きさ」（半径 1 の形のふちで 1）。0 円 / 1 四角 / 2 ひし形 / 3 十字
static float dotShape(float2 d, int shape) {
    float2 a = abs(d);
    if (shape == 1) return max(a.x, a.y) * 1.12;
    if (shape == 2) return (a.x + a.y) * 0.8;
    if (shape == 3) return min(max(a.x * 3.0, a.y), max(a.x, a.y * 3.0)) * 0.9;
    return length(d);
}
// 波（-1〜1）。0 横 / 1 中心から / 2 ノイズ。pw は板の上の場所
static float dotWave(float2 pw, int kind, float freq, float ph) {
    if (kind == 0) return sin(pw.x * freq * 6.2831853 - ph);
    if (kind == 1) return sin(length(pw) * freq * 6.2831853 - ph);
    float2 q = pw * freq * 1.5 + float2(ph * 0.12, ph * 0.07);
    return (gnoise(q) * 0.68 + gnoise(q * 2.03 + 3.1) * 0.32) * 2.0 - 1.0;
}

// テキスト：文字のテクスチャ（白）の不透明度。q は文字のかたまりの中心が 0、高さ H・幅 W（画面の高さが 1）
static float textCover(texture2d<float> aux, float2 q, float W, float H, float lod) {
    constexpr sampler ts(filter::linear, mip_filter::linear, address::clamp_to_zero);
    float2 uv = q / float2(W, H) + 0.5;
    if (any(uv < 0.0) || any(uv > 1.0)) return 0.0;
    return aux.sample(ts, uv, level(lod)).a;
}

// ---- うねり（有機的な歪み）・トンネル用のノイズ ----
static float wfbm(float2 p, int oct) {
    float v = 0.0, amp = 0.5, tot = 0.0;
    for (int i = 0; i < 6; i++) {
        if (i >= oct) break;
        v += gnoise(p) * amp; tot += amp;
        p = float2(p.x * 1.6 + p.y * 1.2, -p.x * 1.2 + p.y * 1.6) + 7.31;
        amp *= 0.5;
    }
    return v / max(tot, 1e-4);
}
// 画面の端の扱い：0 のばす（サンプラーに任せる）/ 1 折り返す / 2 透明（外なら -1）
static float2 warpEdge(float2 uv, int mode) {
    if (mode == 1) {
        float2 m = abs(uv) - 2.0 * floor(abs(uv) * 0.5);
        return float2(m.x > 1.0 ? 2.0 - m.x : m.x, m.y > 1.0 ? 2.0 - m.y : m.y);
    }
    return uv;
}
// トンネルの形の「半径」（円・四角・六角・三角。内接円の半径が 1 になる形で 1）
static float tunnelRadius(float2 v, int shape) {
    if (shape == 0) return length(v);
    float n = shape == 1 ? 4.0 : (shape == 2 ? 6.0 : 3.0);
    float seg = 6.2831853 / n;
    float a = atan2(v.y, v.x) + (shape == 3 ? 1.5707963 : (shape == 1 ? 0.7853982 : 0.0));
    float m = pmod(a, seg) - 0.5 * seg;
    return length(v) * cos(m);
}
// 模様の線の 1 本分（0〜1 の中で 0.5 に線）の濃さと、線からの距離
static float2 tunnelLine(float x, float th, float fw) {
    float d = abs(fract(x) - 0.5);
    float dl = d - th * 0.5;
    return float2(gcover(dl, fw), dl);
}

static float4 tunnelBody(float2 px, constant EffectUniforms& u) {
    // a = 進んだ量, 形, 模様, 輪の数 / b = 線の太さ, (回る速さ), ねじれ, 奥の暗さ
    // pts0 = うねり, うねりの時間, 中心X, 中心Y / pts1 = まわりの区切り, 色の付け方, 明るさ, 光のにじみ / pts2.x = 回った角度（度）
    float4 q0 = u.pts[0], q1 = u.pts[1];
    float2 p = (px - 0.5 * u.size) / u.size.y - float2(q0.z, -q0.w);
    int shape = int(u.a.y + 0.5), pat = int(u.a.z + 0.5);
    const float R = 0.25;
    float moved = u.a.x, wt = q0.y;
    // うねり：奥の端（消える所）が vp へずれて、手前からそこへなめらかに曲がって見える。
    // 奥ほど vp に近づくだけ（行ったり来たりしない）なので、奥行きの答えは 1 つに決まる（ほかの所に穴が出ない）
    float2 vp = q0.x * 0.2 * float2(sin(wt * 0.9) + 0.35 * sin(wt * 2.3 + 1.0), cos(wt * 0.7) + 0.35 * cos(wt * 1.9 + 2.0));
    // 曲がりは丸い筒として求める（形やねじれを入れて求め直すと、三角などで答えが暴れて模様が崩れるため）
    float z = 1.0, w = 0.5;
    for (int it = 0; it < 8; it++) {
        z = R / max(length(p - vp * w), 1e-4);
        w = mix(w, z / (z + 1.2), 0.7);
    }
    // ねじれ：丸い筒の奥行きで回す角度を決めてから、形（四角・三角など）の奥行きを求める
    float2 pp = grot(p - vp * w, u.pts[2].x + u.b.z * z * 60.0);
    float r = max(tunnelRadius(pp, shape), 1e-4);
    z = R / r;
    float ang = atan2(pp.y, pp.x) / 6.2831853 + 0.5;
    float depth = z + moved;
    float U = depth * u.a.w * 0.5;
    float seg = max(q1.x, 1.0);
    float V = ang * seg;
    float fw = max(fwidth(U), 1e-5);
    // 角度のつなぎ目（0 と 1）で fwidth が跳ねないように
    float fwv = max(min(fwidth(V), fwidth(fract(ang + 0.5) * seg)), 1e-5);
    float th = u.b.x;
    float k, avg, dl = 1.0, dlfw = fw, extraFw = 0.0;
    if (pat == 0) {
        float2 l = tunnelLine(U, th, fw);
        k = l.x; dl = l.y; avg = th;
    } else if (pat == 1) {
        float2 lu = tunnelLine(U, th, fw), lv = tunnelLine(V, th, fwv);
        k = max(lu.x, lv.x);
        dl = lu.y / fw < lv.y / fwv ? lu.y : lv.y; dlfw = lu.y / fw < lv.y / fwv ? fw : fwv; avg = 1.0 - (1.0 - th) * (1.0 - th);
    } else if (pat == 2) {
        float su = clamp((0.25 - abs(fract(U) - 0.5)) / fw, -1.0, 1.0);
        float sv = clamp((0.25 - abs(fract(V) - 0.5)) / fwv, -1.0, 1.0);
        float white = 0.5 + 0.5 * su * sv;
        // 線の太さを 50% より上げると、すき間のマスが真ん中から埋まっていく（100% で全部埋まる）
        float h = saturate((1.0 - th) * 2.0);
        float lu = abs(fract(U * 2.0 + 0.5) - 0.5), lv = abs(fract(V * 2.0 + 0.5) - 0.5);
        float hole = gcover(lu - h * 0.5, fw * 2.0) * gcover(lv - h * 0.5, fwv * 2.0);
        if (h >= 0.999) hole = 1.0;
        k = white + (1.0 - white) * (1.0 - hole);
        avg = 0.5 + 0.5 * (1.0 - h * h);
    } else if (pat == 3) {
        // 光の筋：まわりの区切りごとに、長さと場所がばらばらの光が奥から飛んでくる
        float id = floor(V);
        float h = ghash(float2(id, 3.1)), h2 = ghash(float2(id, 8.7));
        float2 lv = tunnelLine(V, th, fwv);
        float xr = depth * 2.5 * (0.6 + h2) + h * 7.0;
        float x = fract(xr);
        extraFw = fwidth(xr);
        float len = 0.1 + 0.25 * h2;
        float dash = smoothstep(0.0, 0.08, x) * (1.0 - smoothstep(len - 0.08, len, x));
        k = lv.x * dash * (0.35 + 0.65 * h); dl = lv.y; dlfw = fwv; avg = th * 0.06;
    } else {
        // もや：角度のつなぎ目が出ないように、2 つのノイズを混ぜる
        float2 a1 = float2(U * 0.8, V), a2 = float2(U * 0.8, V - seg);
        float n = mix(wfbm(a1, 4), wfbm(a2, 4), ang);
        k = smoothstep(0.62 - th * 0.5, 0.95 - th * 0.5, n);
        avg = 0.25;
    }
    // 奥（細かすぎる所）は平均の濃さにして、ちらつかないように
    float fade = saturate(max(max(fw, pat == 0 ? 0.0 : fwv), extraFw * 0.5) * 2.0 - 0.4);
    k = mix(k, avg, fade);
    // 線の太さがいっぱいなら、どの模様もすき間なく埋まる（ふちのにじみで細い筋が残らないように、手前から寄せる）
    k = mix(k, 1.0, smoothstep(0.95, 1.0, th));
    // 光のにじみ：線のまわりに、画面の上でいつも同じ幅（1080p で約 20px）の光
    float dpx = max(dl, 0.0) / max(dlfw, 1e-5);
    float glow = q1.w * exp(-dpx / (20.0 * u.size.y / 1080.0)) * 0.6 * (1.0 - fade);
    if (pat == 3) glow *= k > 0.0 ? saturate(k * 3.0) : 0.0;
    if (pat == 2 || pat == 4) glow = q1.w * k * 0.4;
    float kt = saturate(k + glow);
    float fog = exp(-u.b.w * z * 0.6);
    int cm = int(q1.y + 0.5);
    float3 col = u.color.rgb;
    if (cm == 1) col = gpal(u.pal, u.palCount, 1.0 - abs(fract(depth * 0.08) * 2.0 - 1.0));
    else if (cm == 2) col = pureHue(fract(depth * 0.05 + ang));
    float a = saturate(kt * fog);
    return float4(col * q1.z * kt * fog, a);
}

static float4 warpBody(float2 px, constant EffectUniforms& u, texture2d<float> tex, sampler s) {
    // a = 強さ(px), 大きさ, 時間（速さ × 秒）, 種類 / b = 細かさ, ねばり, 色のずれ, 画面の端
    float2 p = px / u.size.y / max(u.a.y, 0.01);
    float t = u.a.z;
    int kind = int(u.a.w + 0.5);
    int oct = 2 + int(u.b.x * 4.0 + 0.5);
    float visc = u.b.y;
    float2 d;
    if (kind == 1) {
        // 熱気：上へ流れながら横にゆらめく
        float2 q = float2(p.x * 1.4, p.y * 0.8 + t * 1.5);
        d = float2(wfbm(q, oct) - 0.5, (wfbm(q + float2(4.3, 1.7), oct) - 0.5) * 0.35) * 6.0;
        d += visc * 3.0 * (float2(wfbm(q * 2.1 + d * 0.7 + 9.1, oct), 0.5) - 0.5);
    } else if (kind == 2 || kind == 3) {
        // 渦：ノイズの坂に直角に流す（渦を巻く）／波紋：ノイズの等高線に沿って波打つ
        float e = 0.02;
        float2 q = p + visc * float2(wfbm(p * 0.7 + t * 0.2, 3), wfbm(p * 0.7 + 5.2 - t * 0.2, 3));
        float n0, nx, ny;
        if (kind == 2) {
            n0 = wfbm(q + t * 0.25, oct); nx = wfbm(q + float2(e, 0) + t * 0.25, oct); ny = wfbm(q + float2(0, e) + t * 0.25, oct);
        } else {
            n0 = sin(wfbm(q, oct) * 14.0 - t * 3.0);
            nx = sin(wfbm(q + float2(e, 0), oct) * 14.0 - t * 3.0);
            ny = sin(wfbm(q + float2(0, e), oct) * 14.0 - t * 3.0);
        }
        float2 g = float2(nx - n0, ny - n0) / e;
        d = kind == 2 ? float2(g.y, -g.x) * 0.8 : g * 0.1;
    } else {
        // 液体：ゆがんだ場所でノイズを引き直す（ねばりで、ゆがみが重なる）
        float2 q1 = float2(wfbm(p + t * 0.3, oct), wfbm(p + float2(5.2, 1.3) - t * 0.25, oct));
        float2 q2 = float2(wfbm(p + 4.0 * visc * q1 + float2(1.7, 9.2) + t * 0.15, oct),
                           wfbm(p + 4.0 * visc * q1 + float2(8.3, 2.8) - t * 0.12, oct));
        d = (mix(q1, q2, 0.35 + 0.65 * visc) - 0.5) * 6.0;
    }
    float2 off = d * u.a.x * (u.size.y / 1080.0) / u.size;
    float2 uv = px / u.size;
    int edge = int(u.b.w + 0.5);
    float ca = u.b.z;
    float2 uvg = warpEdge(uv + off, edge);
    float4 c = tex.sample(s, uvg);
    if (ca > 0.001) {
        float2 ur = warpEdge(uv + off * (1.0 + ca * 0.6), edge), ub = warpEdge(uv + off * (1.0 - ca * 0.6), edge);
        float4 cr = tex.sample(s, ur), cb = tex.sample(s, ub);
        if (edge == 2) {
            cr *= all(ur >= 0.0 && ur <= 1.0) ? 1.0 : 0.0;
            cb *= all(ub >= 0.0 && ub <= 1.0) ? 1.0 : 0.0;
        }
        c = float4(cr.r, c.g, cb.b, max(c.a, max(cr.a, cb.a)));
    }
    if (edge == 2 && any(uvg < 0.0 || uvg > 1.0)) c = ca > 0.001 ? float4(c.r, 0.0, c.b, max(c.r, c.b)) : float4(0.0);
    return c;
}

static float4 effectBody(VOut in, constant EffectUniforms& u, texture2d<float> tex, texture2d<float> aux, sampler s) {
    float2 px = in.pos.xy;
    float2 uv = px / u.size;
    if (u.kind == 20) return tunnelBody(px, u);
    if (u.kind == 21) return warpBody(px, u, tex, s);
    if (u.kind == 22) {
        // 切り替えの形：a = 形（1 ワイプ / 2 円 / 3 ノイズ / 4 明るさ / 5 グリッチ）, 進み具合, ぼかし, 種
        int k = int(u.a.x + 0.5);
        float p = u.a.y, sft = max(u.a.z, 0.001);
        float2 q = uv;
        if (k == 5) {
            // グリッチ：切り替えの途中だけ、行ごとに横へずれる
            float row = floor(uv.y * 40.0);
            float amt = 1.0 - abs(2.0 * p - 1.0);
            q.x = fract(q.x + (ghash(float2(row, floor(u.a.w + p * 20.0))) - 0.5) * 0.15 * amt);
        }
        float4 c = tex.sample(s, q);
        float v;
        if (k == 1) v = uv.x;
        else if (k == 2) {
            float2 d = (uv - 0.5) * float2(u.size.x / u.size.y, 1.0);
            v = length(d) / (0.5 * length(float2(u.size.x / u.size.y, 1.0)));
        } else if (k == 3) {
            float2 nq = uv * float2(u.size.x / u.size.y, 1.0) * 6.0 + u.a.w;
            v = gnoise(nq) * 0.6 + gnoise(nq * 2.7 + 3.1) * 0.4;
        } else if (k == 4) {
            float a = max(c.a, 1e-4);
            v = 1.0 - saturate(dot(c.rgb / a, float3(0.2126, 0.7152, 0.0722)));
        } else if (k == 5) {
            v = ghash(floor(uv * float2(16.0, 9.0)) + u.a.w);
            sft = 0.001;
        } else {
            return c * p;
        }
        // 進み具合 p で、v の小さい所から現れる（ぼかしの幅も入れて、0 で何も・1 で全部）
        float t = p * (1.0 + sft) - sft;
        float m = 1.0 - smoothstep(t, t + sft, v);
        return c * m;
    }
    if (u.kind == 19) {
        // 光の流れ：a = 動いた量（速さ × 秒）, ぼけ, 帯の数, 帯の太さ / b = うねり, 色のにじみ, 虹色, 粒子感
        // pts[0] = 角度, 明るさ, 色相ずらし, まわりの光 / pts[1] = 大きさ, 経過秒
        float T = u.a.x;
        float soft = u.a.y, w = max(u.a.w, 0.01);
        int count = clamp(int(u.a.z + 0.5), 1, 4);
        float warp = u.b.x, disp = u.b.y, irid = u.b.z, grain = u.b.w;
        float2 p = (px - 0.5 * u.size) / u.size.y;
        p = grot(p, u.pts[0].x) / max(u.pts[1].x, 0.05);
        // ゆっくり動くノイズで場所をゆがめる（うねり）
        float2 wq = p * 0.9;
        float2 wv = float2(gnoise(wq + float2(T * 0.31, 1.7)), gnoise(wq * 1.3 + float2(4.1, T * 0.23))) * 2.0 - 1.0;
        float2 q = p + wv * warp * 0.32;
        float hueRot = u.pts[0].z / 360.0;
        float cx = u.pts[1].z, sf = max(u.pts[1].w, 0.05);
        float3 sum = float3(0.0);
        for (int k = 0; k < 4; k++) {
            if (k >= count) break;
            float fk = float(k);
            // 帯のふち（ゆったりした弧）。帯は、ふちの片側（d > 0）へ広がる光の面
            float off = (fk - float(count - 1) * 0.5) * 0.38;
            float y = off + 0.18 * sin(q.x * 0.9 + T * 0.35 + fk * 2.1) + 0.08 * sin(q.x * 1.9 - T * 0.27 + fk * 4.3);
            float d = q.y - y;
            float wk = w * (1.0 - fk * 0.25);
            float spread = wk * (1.0 + soft * 4.0);
            // 分光：6 つの波長で、少しずつずらして光を測る（プリズムのように、ふちと中に虹の帯ができる）
            float3 I = float3(0.0), norm = float3(0.0);
            float dispK = disp * wk * (0.04 + cx * 0.05);
            for (int j = 0; j < 6; j++) {
                float lam = 420.0 + 52.0 * float(j);
                float3 sc = spectralColor(lam);
                float dj = d - (float(j) - 2.5) * dispK;   // 短い波長（青）ほど外へにじむ
                float ej = smoothstep(-wk * (0.2 + soft * 0.55), wk * 0.3, dj);
                float bj = exp(-pow(max(dj, 0.0) / (spread * (1.0 + (float(j) - 2.5) * 0.04 * cx)), 1.6));
                I += ej * bj * sc;
                norm += sc;
            }
            I /= norm;
            // 色：ふちの近くは白、奥へいくほどベージュ → 青緑 → 深い青（虹色の強さで鮮やかさ）
            float t = saturate(d / spread);
            float3 warm = float3(1.0, 0.70, 0.42), teal = float3(0.12, 0.60, 0.95), deep = float3(0.02, 0.16, 0.50);
            float3 pal = t < 0.2 ? mix(float3(1.0), warm, t / 0.2)
                       : t < 0.62 ? mix(warm, teal, (t - 0.2) / 0.42) : mix(teal, deep, (t - 0.62) / 0.38);
            float drift = 0.5 + 0.5 * sin(q.x * 1.1 + T * 0.2 + fk * 1.7);
            pal = mix(pal, pal.zyx * float3(1.0, 0.9, 1.0), drift * 0.35);
            float3 tint = mix(float3(1.0), pal, irid);
            // 光の中の色の重なり（縞にならないように、くり返さない形で）：
            // ① ぼんやりした色の光がいくつか、ゆっくり動きながら重なる
            float3 inner = float3(0.0);
            for (int m = 0; m < 5; m++) {
                float fm = float(m) + fk * 5.0;
                float cxm = 0.85 * sin(T * 0.11 * (1.0 + float(m) * 0.27) + fm * 2.31) / sf;
                float tcm = 0.25 + 0.5 * (0.5 + 0.5 * sin(T * 0.09 * (1.0 + float(m) * 0.19) + fm * 1.73));
                float2 dq = float2((q.x - cxm) / (0.42 / sf * (1.0 + 0.25 * sin(fm * 1.3))),
                                   (t - tcm) / (0.2 * (1.0 + 0.3 * cos(fm * 0.9))));
                // 色は青・青緑・琥珀・橙のあたりから（緑のまん中はさける）。ゆっくり入れ替わる
                float sel = fract(0.29 * fm + T * 0.008);
                float lam = sel < 0.5 ? mix(455.0, 495.0, sel * 2.0) : mix(585.0, 625.0, sel * 2.0 - 1.0);
                inner += exp(-dot(dq, dq)) * spectralColor(lam) * 1.3;
            }
            // ② 光のひだ：とてもやわらかい薄い光の面がいくつか、違う曲がり方で重なる（ふちで少し色が分かれる）
            for (int m = 0; m < 3; m++) {
                float fm = float(m);
                // それぞれ傾きを変えて、ふちと平行にならず交わるように
                float yv = 0.2 + 0.25 * fm + (fm - 1.0) * 0.22 * q.x
                         + 0.16 * sin(q.x * (0.6 + 0.5 * fm) * sf + T * (0.18 + 0.06 * fm) + fm * 2.0 + fk * 3.1);
                float wv2 = 0.06 + 0.035 * fm;
                float3 dv = (float3(t - 0.012, t, t + 0.012) - yv) / wv2;
                inner += exp(-dv * dv) * spectralColor(fm == 1.0 ? 600.0 : 460.0 + 20.0 * fm) * 0.5;
            }
            tint = mix(tint, tint * 0.45 + inner, cx * smoothstep(0.03, 0.3, t));
            if (abs(hueRot) > 1e-4) tint = hueShift(tint, hueRot);
            sum += I * tint * (1.0 - fk * 0.3);
        }
        // まわりのぼんやりした光（大きくゆっくり動く、青と琥珀色の雲）
        float2 gq = p * 0.6 + float2(T * 0.09, -T * 0.06);
        float g1 = smoothstep(0.55, 1.0, gnoise(gq + 7.3)), g2 = smoothstep(0.6, 1.0, gnoise(gq * 1.3 + 2.1));
        float3 c1 = float3(0.08, 0.35, 0.70), c2 = float3(0.75, 0.48, 0.22);
        if (abs(hueRot) > 1e-4) { c1 = hueShift(c1, hueRot); c2 = hueShift(c2, hueRot); }
        sum += (c1 * g1 + c2 * g2 * 0.6) * u.pts[0].w * 0.5;
        float3 c = (1.0 - exp(-sum * u.pts[0].y * 1.6)) * u.color.rgb;
        // フィルムのざらつき（明るい所ほど目立つ。コマごとに変わる）
        uint2 ip = uint2(px) + uint2(uint(u.pts[1].y * 24.0) * 1973u, uint(u.pts[1].y * 24.0) * 9277u);
        uint hsh = ip.x * 1597334677u ^ ip.y * 3812015801u;
        hsh = (hsh ^ (hsh >> 16)) * 2246822519u; hsh ^= hsh >> 13;
        float gr = float(hsh & 0xFFFFu) / 65535.0 - 0.5;
        c = saturate(c + gr * grain * (0.25 + dot(c, float3(0.33))));
        float a = max(max(c.r, c.g), c.b);
        return float4(c, a);
    }
    if (u.kind == 18) {
        // ドット：a = 数（高さあたり）, 大きさ（px・1080p）, 形, 並び / b = 角度, 動いた量（個）, 位置のばらつき, 大きさのばらつき
        // pts[0] = 明滅, 波の大きさ, 波の細かさ, 波の位相 / pts[1] = 波の形, 傾き（縦・横、度）, 遠くを暗く
        // pts[2] = 波の高さ, ぼかし（px）, 経過秒 / pts[3] = ふらふら, ふらふらの進んだ量, 光のにじみ
        float n = max(u.a.x, 0.5);
        int shape = int(u.a.z + 0.5), layout = int(u.a.w + 0.5);
        float moved = u.b.y, jitter = layout == 2 ? max(u.b.z, 0.6) : u.b.z, sizeRand = u.b.w;
        float twinkle = u.pts[0].x, wAmt = u.pts[0].y, wFreq = max(u.pts[0].z, 0.05), wPh = u.pts[0].w;
        int wKind = int(u.pts[1].x + 0.5);
        float fog = u.pts[1].w, height = u.pts[2].x, t = u.pts[2].z;
        float k1080 = u.size.y / 1080.0;
        float rPx = u.a.y * k1080 * 0.5, blurPx = u.pts[2].y * k1080;
        float ta = u.pts[1].y * 3.14159265 / 180.0, tb = u.pts[1].z * 3.14159265 / 180.0;
        const float D = 1.6;
        // 粒 1 つの大きさ・明るさ（場所 cell の粒。pw は板の上の場所）
        #define DOT_MOD(cell, wv, R, bright) { \
            float2 hr = dhash2(cell + 17.0); \
            R *= 1.0 - sizeRand * hr.x; \
            R *= max(0.0, 1.0 + wAmt * (wv)); \
            bright = 1.0 - twinkle * (0.5 + 0.5 * sin(t * (2.0 + hr.y * 5.0) + hr.x * 40.0)); }
        if (height > 1e-4) {
            // 3D の点の雲：手前の列から、各列の近くの粒を画面に写して描く（波の高さで上へ持ち上がる）
            float2 p = (px - 0.5 * u.size) / u.size.y;
            p.y = -p.y;
            float3 ax = float3(cos(tb), 0.0, sin(tb));
            float3 ay = float3(-sin(tb) * sin(ta), cos(ta), cos(tb) * sin(ta));
            float sx = p.x, py = p.y;
            float denom = sx * ax.z - D * ax.x;
            if (abs(denom) < 1e-5) return float4(0.0);
            float cover = 0.0;
            float rMax = rPx * 2.0 * (1.0 + wAmt) / u.size.y;
            int i0 = int(floor(-2.5 * n + moved));
            // この高さに届きうる列から始める（それより手前の列は、いちばん持ち上がっても届かない）
            i0 = max(i0, int(floor(terrainRowAt(py - height * 2.5 - rMax * 2.0, ta, tb, n, moved))) - 2);
            int i1 = min(int(ceil(4.0 * n + moved)), i0 + 400);
            for (int i = i0; i <= i1; i++) {
                float v = (float(i) + 0.5 - moved) / n;
                float u0 = (D * v * ay.x - sx * (v * ay.z + D)) / denom;
                float depth = u0 * ax.z + v * ay.z + D;
                if (depth < 0.05) continue;
                float yFlat = v * ay.y * D / depth;
                float rU = rMax * clamp(D / depth, 0.25, 2.0) + 2.0 / u.size.y;
                if (yFlat - rU > py) break;
                if (yFlat + height * D / depth + rU < py) continue;
                float shift = layout == 1 && (i & 1) != 0 ? 0.5 : 0.0;
                // ばらつきが小さければ、いちばん近い粒だけ見る（軽く）
                int reach = jitter > 0.15 ? 1 : 0;
                float jc = reach == 0 ? floor(u0 * n - shift) : floor(u0 * n - shift);
                for (int j = -reach; j <= reach; j++) {
                    float2 cell = float2(jc + float(j), float(i));
                    float2 jit = (dhash2(cell) - 0.5) * jitter;
                    float uu = (cell.x + 0.5 + shift + jit.x) / n;
                    float vv = (float(i) + 0.5 + jit.y - moved) / n;
                    float2 pw = float2(uu, (float(i) + 0.5 + jit.y) / n);
                    float wv = dotWave(pw, wKind, wFreq, wPh);
                    float h = height * (0.5 + 0.5 * wv);
                    float3 P = uu * ax + vv * ay + float3(0.0, h, 0.0);
                    float dep = P.z + D;
                    if (dep < 0.05) continue;
                    float2 sp = P.xy * D / dep;
                    float R = rPx * clamp(D / dep, 0.25, 2.0), bright = 1.0;
                    DOT_MOD(cell, wv, R, bright)
                    float d = dotShape((p - sp) * u.size.y, shape);
                    float c = (1.0 - smoothstep(R - 0.75, R + 0.75 + blurPx, d)) * min(1.0, R * 1.5);
                    cover = max(cover, c * bright * exp(-max(dep - D, 0.0) * fog * 1.2));
                }
            }
            float k = saturate(cover);
            return float4(u.color.rgb * k, k);
        }
        // 平ら（と、奥への傾き）：板の上の場所を探して、近くの粒（3×3 のます）を描く
        float2 p = (px - 0.5 * u.size) / u.size.y;
        float2 q = p;
        float fogk = 1.0;
        if (abs(ta) > 1e-4 || abs(tb) > 1e-4) {
            float tx = -ta;
            float3 eye = float3(0.0, 0.0, -D);
            float3 dir = float3(p, D);
            float3 ax = float3(cos(tb), 0.0, sin(tb));
            float3 ay = float3(-sin(tb) * sin(tx), cos(tx), cos(tb) * sin(tx));
            float3 nrm = cross(ax, ay);
            float dn = dot(dir, nrm);
            if (abs(dn) < 1e-5) return float4(0.0);
            float tt = -dot(eye, nrm) / dn;
            if (tt <= 0.0) return float4(0.0);
            float3 hit = eye + dir * tt;
            q = float2(dot(hit, ax), dot(hit, ay));
            fogk = exp(-max(tt - 1.0, 0.0) * fog * 2.0);
        }
        float2 r = grot(q, u.b.x);
        float2 g = r * n + float2(-moved, 0.0);
        // 1 ピクセルで何ますぶん動くか（遠くほど大きい）
        float fw = max(length(fwidth(g)), 1e-5);
        float unitPx = u.size.y / n;
        float cover = 0.0, glowSum = 0.0;
        float2 c0 = floor(g);
        // ふらふら：粒ごとに違う、なめらかな道すじ（速さの違う波を重ねる）。最大でます 1.5 つ分まで離れる
        float wander = u.pts[3].x, wT = u.pts[3].y, glow = u.pts[3].z;
        float wAmp = wander * 1.5;
        float Rbase = rPx / unitPx;
        // 光の輪の届く所（ますの数）
        float haloR = glow > 1e-3 ? Rbase * (2.0 + 9.0 * glow) + blurPx / unitPx * 0.5 : 0.0;
        // 見るますの広さ：ふらふら・光の輪が大きいほど遠くのますの粒まで見る（最大 7×7）
        int reach = clamp(int(ceil(wAmp + jitter * 0.5 + max(Rbase * 1.2, haloR) + 0.5)) - 1, 1, 3);
        for (int dy = -reach; dy <= reach; dy++) {
            for (int dx = -reach; dx <= reach; dx++) {
                float2 cell = c0 + float2(dx, dy);
                float shift = layout == 1 && fmod(abs(cell.y), 2.0) > 0.5 ? 0.5 : 0.0;
                float2 cellS = float2(floor(g.x - shift) + float(dx), cell.y);
                float2 center = cellS + float2(0.5 + shift, 0.5) + (dhash2(cellS) - 0.5) * jitter;
                if (wAmp > 1e-4) {
                    float2 h1 = dhash2(cellS + 41.7), h2 = dhash2(cellS + 83.1);
                    float2 f1 = 0.35 + h1 * 0.6, f2 = 0.9 + h2 * 0.9;
                    float2 o = float2(sin(wT * f1.x + h2.x * 6.283) + 0.45 * sin(wT * f2.x * 1.3 + h1.y * 6.283),
                                      sin(wT * f1.y + h2.y * 6.283 + 1.7) + 0.45 * sin(wT * f2.y * 1.1 + h1.x * 6.283));
                    center += o / 1.45 * wAmp;
                }
                float2 pw = (center + float2(moved, 0.0)) / n;
                float R = Rbase, bright = 1.0;
                float wv = wAmt > 0.0 ? dotWave(pw, wKind, wFreq, wPh) : 0.0;
                DOT_MOD(cellS, wv, R, bright)
                float d = dotShape(g - center, shape);
                float e = fw * 0.75 + blurPx / unitPx * 0.5;
                float c = (1.0 - smoothstep(R - e, R + e, d)) * min(1.0, 2.0 * R / fw);
                cover = max(cover, c * bright);
                if (glow > 1e-3 && R > 1e-5) {
                    // 光の輪：ふちから外へなだらかに消える（重なると足し合わさる）
                    float haloW = R * (2.0 + 9.0 * glow) + blurPx / unitPx * 0.5;
                    float x = max(length(g - center) - R * 0.6, 0.0) / haloW;
                    glowSum += exp(-x * 3.5) * (1.0 - smoothstep(0.7, 1.0, x)) * bright * (0.35 + 0.5 * glow);
                }
            }
        }
        cover = max(cover, 1.0 - exp(-glowSum * 1.4));
        // 粒が細かくなりすぎた所（地平線の近く）は消す
        cover *= 1.0 - smoothstep(0.3, 0.6, fw);
        float k = saturate(cover * fogk);
        return float4(u.color.rgb * k, k);
        #undef DOT_MOD
    }
    if (u.kind == 17 && u.pts[1].y > 1e-4) {
        // ライン（波の高さ＝3D の地形）：線を描いた板の上の横の線を、上（画面の縦）へ持ち上げて遠近で見る。
        // 手前の線から順に描いて、手前の山より下に来る奥の線は隠す（地形の見え方）
        // a = 本数, 太さ（px）, -, 動いた量（本） / b = ぼかし（px）, -, 山の細かさ / pts[0] = 波の位相, -, 傾き（縦・横）
        // pts[1] = 遠くを暗く, 波の高さ, 山の形, 真ん中 / pts[2].x = 山の下を黒く塗る
        const float D = 1.6;
        float2 p = (px - 0.5 * u.size) / u.size.y;
        p.y = -p.y;   // ここでは上が +
        float ta = u.pts[0].z * 3.14159265 / 180.0, tb = u.pts[0].w * 3.14159265 / 180.0;
        float3 ax = float3(cos(tb), 0.0, sin(tb));
        float3 ay = float3(-sin(tb) * sin(ta), cos(ta), cos(tb) * sin(ta));
        float n = max(u.a.x, 0.5);
        float m = u.a.w;
        float sx = p.x, py = p.y;
        float denom = sx * ax.z - D * ax.x;
        if (abs(denom) < 1e-5) return float4(0.0);
        float k1080 = u.size.y / 1080.0;
        float wpx = u.a.y * k1080;
        float thin = saturate(wpx);
        float halfPx = max(wpx, 1.0) * 0.5;
        float blurPx = u.b.x * k1080;
        float height = u.pts[1].y, fog = u.pts[1].x, flat = u.pts[1].w;
        int shape = int(u.pts[1].z + 0.5);
        float freq = max(u.b.z, 0.05), ph = u.pts[0].x;
        float e = 1.0 / u.size.y;
        float maxPrev = -1e9, cover = 0.0;
        int i0 = int(floor(-2.5 * n + m));
        // この高さに届きうる列から始める。手前の列は隠す役に立つこともあるので、その分（線の上の高さ）はゆとりを持つ
        i0 = max(i0, int(floor(terrainRowAt(py - height * 2.5 - 4.0 / u.size.y, ta, tb, n, m))) - 2);
        int i1 = int(ceil(4.0 * n + m));
        i1 = min(i1, i0 + 400);
        for (int i = i0; i <= i1; i++) {
            float v = (float(i) - m) / n;
            float z = float(i) / n;   // 地形の場所（線と一緒に流れる）
            // この列（画面の x）で、線のどこが見えているか（高さは縦だけなので x と奥行きには効かない）
            float u0 = (D * v * ay.x - sx * (v * ay.z + D)) / denom;
            float u1 = (D * v * ay.x - (sx + e) * (v * ay.z + D)) / ((sx + e) * ax.z - D * ax.x);
            float depth = u0 * ax.z + v * ay.z + D;
            if (depth < 0.05) continue;
            // 山の無いときの高さ（線はここより上にしか来ない）。重い山の計算を、届かない線では飛ばす
            float yFlat = v * ay.y * D / depth;
            float hwU = halfPx * clamp(D / depth, 0.25, 2.0) / u.size.y + 2.0 / u.size.y;
            // この線がもう上を通っている → この線もこれより奥の線も、ここには描かれない（手前の山に隠れる）
            if (yFlat - hwU > py) break;
            // いちばん高くしてもここまで届かない → 描かれない（隠す役にも立たない）
            if (yFlat + height * D / depth + hwU < py) { maxPrev = max(maxPrev, yFlat); continue; }
            float depth1 = u1 * ax.z + v * ay.z + D;
            float h0, h1;
            {
                float xs[2] = { u0, u1 };
                float hs[2];
                for (int s2 = 0; s2 < 2; s2++) {
                    float x = xs[s2], hh;
                    if (shape == 0) {
                        hh = 0.5 + 0.5 * sin(x * freq * 6.2831853 + ph) * cos(z * freq * 5.0 + ph * 0.5);
                    } else {
                        float2 q = float2(x, z) * freq * 1.5 + float2(ph * 0.15, 0.0);
                        float nv = gnoise(q) * 0.68 + gnoise(q * 2.03 + 3.1) * 0.32;
                        if (shape == 2) { float r = 1.0 - abs(nv * 2.0 - 1.0); hh = r * r; }
                        else hh = smoothstep(0.25, 0.85, nv);
                    }
                    // 真ん中：プラスで真ん中を平らに（道のように）、マイナスで真ん中だけ山に
                    float c = smoothstep(0.05, 0.6, abs(x));
                    hh *= flat >= 0.0 ? mix(1.0, c, flat) : mix(1.0, 1.0 - c, -flat);
                    hs[s2] = hh;
                }
                h0 = hs[0]; h1 = hs[1];
            }
            float y0 = (v * ay.y + height * h0) * D / depth;
            float y1 = (v * ay.y + height * h1) * D / max(depth1, 0.05);
            float slope = (y1 - y0) / e;
            float dpx = abs(py - y0) * u.size.y / sqrt(1.0 + slope * slope);
            float hw = halfPx * clamp(D / depth, 0.25, 2.0);
            float c = 1.0 - smoothstep(hw - 0.75 - blurPx * 0.5, hw + 0.75 + blurPx * 0.5, dpx);
            // 手前の線（の山）より下なら隠れている
            float vis = smoothstep(-1.0, 1.0, (py - maxPrev) * u.size.y + hw);
            float fogk = exp(-max(depth - D, 0.0) * fog * 1.2);
            cover = max(cover, c * vis * fogk * thin);
            maxPrev = max(maxPrev, y0);
        }
        float k = saturate(cover);
        // 山の下を黒く塗る（下の映像を隠す）
        float fillA = u.pts[2].x > 0.5 && py < maxPrev ? 1.0 : 0.0;
        return float4(u.color.rgb * k, max(k, fillA));
    }
    if (u.kind == 17) {
        // ライン：a = 本数（画面の高さあたり）, 太さ（px・1080p）, 角度, 動いた量（本）
        //         b = ぼかし（px・1080p）, 波の大きさ, 波の細かさ, （波の速さ。動いた量は pts で）
        //         pts[0] = 波の位相, 線ごとの波のずれ, 奥への傾き（縦・横、度） / pts[1].x = 遠くを暗く
        float2 p = (px - 0.5 * u.size) / u.size.y;
        float n = max(u.a.x, 0.001);
        float2 q = p;
        float fog = 1.0;
        float tx = -u.pts[0].z * 3.14159265 / 180.0, ty = u.pts[0].w * 3.14159265 / 180.0;
        if (abs(tx) > 1e-4 || abs(ty) > 1e-4) {
            // 3D：線を描いた板（中心が画面の真ん中、大きさは傾けないときと同じ）を傾けて、目から見た所を探す
            const float D = 1.6;
            float3 eye = float3(0.0, 0.0, -D);
            float3 dir = float3(p, D);
            // 板の向き：横の軸まわりに tx（プラスで上が奥＝床のように）、縦の軸まわりに ty
            float3 ax = float3(cos(ty), 0.0, sin(ty));
            float3 ay = float3(-sin(ty) * sin(tx), cos(tx), cos(ty) * sin(tx));
            float3 nrm = cross(ax, ay);
            float dn = dot(dir, nrm);
            if (abs(dn) < 1e-5) return float4(0.0);
            float t = -dot(eye, nrm) / dn;
            if (t <= 0.0) return float4(0.0);
            float3 hit = eye + dir * t;
            q = float2(dot(hit, ax), dot(hit, ay));
            // 遠いほど暗く（目からの距離が真ん中より遠い分）
            fog = exp(-max(t - 1.0, 0.0) * u.pts[1].x * 2.0);
        }
        float2 r = grot(q, u.a.z);
        // 線の位置（線の間隔が 1）。波は線に沿って（r.y の方向に）うねる。線ごとのずれで 1 本ずつ違う形に
        float x = r.x * n - u.a.w;
        float amp = u.b.y * n, freq = u.b.z * 6.2831853;
        float shift = u.pts[0].y * 6.2831853 * 0.37;
        // 波でずれた線は隣の線の所まで来ることがあるので、近くの何本かを見て、いちばん近い線を探す
        int reach = min(int(ceil(amp)) + 1, 12);
        float base = floor(x + 0.5);
        float best = 1e9, bestSlope = 0.0;
        for (int j = -reach; j <= reach; j++) {
            float idx = base + float(j);
            float ph = r.y * freq + u.pts[0].x + idx * shift;
            float c = idx + amp * sin(ph);
            float dx = abs(x - c);
            if (dx < best) { best = dx; bestSlope = amp * freq / n * cos(ph); }
        }
        // 線に対して直角の距離にする（波が急な所で線が細く見えないように）
        float corr = 1.0 / sqrt(1.0 + bestSlope * bestSlope);
        float dl = best * corr;
        float k1080 = u.size.y / 1080.0;
        float unitPx = u.size.y / n;   // 傾けないときの線の間隔（px）
        float halfw = u.a.y * k1080 * 0.5 / unitPx;
        float blur = u.b.x * k1080 / unitPx;
        // 1 ピクセルで線の位置がどれだけ変わるか（遠くや波で変わる）。細すぎる・遠すぎる線は薄くして、ちらつかないように
        float fw = max(fwidth(x) * corr, 1e-5);
        float edge = fw * 0.75 + blur * 0.5;
        float k = (1.0 - smoothstep(halfw - edge, halfw + edge, dl)) * min(1.0, 2.0 * halfw / fw);
        // 線が細かくなりすぎた所（地平線の近く）は消す
        k *= 1.0 - smoothstep(0.25, 0.5, fwidth(x));
        k = saturate(k * fog);
        return float4(u.color.rgb * k, k);
    }
    if (u.kind == 16) {
        // フィロタキシス（Resolume 用の FFGL ジェネレーター Phyllotaxis をそのまま移したもの）
        // a = 生まれる速さ, 広がる速さ, 粒の大きさ, 育つ時間 / b = 外ほど大きく, 光のにじみ, 回った量（回転 × 秒）, 線の長さ
        // pts[0] = 経過秒, 色のばらつき
        const float GOLDEN_ANGLE = 2.39996323;
        float2 uv2 = (px - 0.5 * u.size) / u.size.y;
        uv2.y = -uv2.y;   // 元（OpenGL）と同じく上が +
        float time = u.pts[0].x, colorRandom = u.pts[0].y;
        float birthRate = max(u.a.x, 0.001), moveSpeed = u.a.y, dotRadius = u.a.z, growTime = u.a.w;
        float sizeGrowth = u.b.x, glowAmt = u.b.y, lineLength = u.b.w;
        float currentBirth = time * birthRate;
        float baseRot = u.b.z * 6.28318;
        float aa = 1.5 / max(u.size.y, 1.0);
        float3 colorSum = float3(0.0);
        int maxDots = min(int(ceil(birthRate / max(moveSpeed, 0.0001))) + 2, 2048);
        for (int j = 0; j < maxDots; j++) {
            float fi = floor(currentBirth) - float(j);
            if (fi < 0.0) break;
            float age = (currentBirth - fi) / birthRate;
            float r = age * moveSpeed;
            if (r > 1.0) break;
            float angle = fi * GOLDEN_ANGLE + baseRot;
            float2 dirOut = float2(cos(angle), sin(angle));
            float2 pos = r * dirOut;
            float sz = dotRadius * (1.0 + r * sizeGrowth);
            float2 delta = uv2 - pos;
            if (abs(delta.x) > sz * 5.0 + lineLength || abs(delta.y) > sz * 5.0 + lineLength) continue;
            float sizeT = smoothstep(0.0, growTime, age);
            if (sizeT < 0.001) continue;
            sz *= sizeT;
            float fade = sizeT * (1.0 - smoothstep(0.6, 0.95, r));
            // 頭から後ろへ伸びる棒との距離（長さ 0 なら円）
            float len = min(lineLength, r);
            float2 seg = -dirOut * len;
            float segL2 = dot(seg, seg);
            float h = segL2 > 1e-12 ? clamp(dot(uv2 - pos, seg) / segL2, 0.0, 1.0) : 0.0;
            float d = length(uv2 - (pos + seg * h));
            float core = (1.0 - smoothstep(sz - aa, sz + aa, d)) * fade;
            float halo = exp(-d * d / (sz * sz * 2.5)) * glowAmt * fade;
            // 粒ごとの色（生まれた番号から決める。時間では変わらない）
            float3 p3 = fract(float3(fi * 12.9898) * float3(0.1031, 0.1030, 0.0973));
            p3 += dot(p3, p3.yzx + 33.33);
            float hue = fract((p3.x + p3.y) * p3.z);
            float3 pColor = mix(u.color.rgb, hsv2rgb(float3(hue, 0.75, 1.0)), colorRandom);
            colorSum += pColor * (core + halo);
        }
        float3 c = saturate(colorSum);
        // まわりは透明（明るさをそのまま不透明度に。色は不透明度が掛かった形）
        return float4(c, max(max(c.r, c.g), c.b));
    }
    if (u.kind == 15) {
        // テキスト：a = 動き, 大きさ（1 行の高さ）, 動いた量, 波 / b.x = グリッチ, b.y = 塗り
        // pts[0] = テクスチャの横/縦, テクスチャが何行ぶんか, 弾み, 経過秒
        // pts[1] = テクスチャの高さ（px）, 横の間隔, 縦の間隔（1 行の高さが 1）
        float2 p = (px - 0.5 * u.size) / u.size.y;
        float texA = u.pts[0].x, texLines = max(u.pts[0].y, 1.0), punch = u.pts[0].z, t = u.pts[0].w;
        int m = int(u.a.x + 0.5);
        float lineH = u.a.y * (m == 5 ? punch : 1.0);
        float H = lineH * texLines, W = H * texA;
        if (H <= 1e-5) return float4(0.0);
        // 時計：流さないときに画面の幅からはみ出す文字（終わったときの文字など）は、幅に収まるように縮める
        float aspect = u.size.x / u.size.y;
        if (u.pts[1].w > 0.5 && m != 1 && m != 2 && m != 3 && W - lineH * 0.6 > aspect * 0.94) {
            float k = aspect * 0.94 / (W - lineH * 0.6);
            lineH *= k; H *= k; W *= k;
        }
        float lod = max(log2(u.pts[1].x / max(H * u.size.y, 1.0)), 0.0);
        float moved = u.a.z;
        // 波：横の位置で上下に揺らす
        p.y += u.a.w * lineH * 0.35 * sin(p.x / max(lineH, 0.02) * 1.6 - t * 4.0);
        // グリッチ：横の帯がときどきずれて、色が分かれる
        float g = u.b.x, split = 0.0;
        if (g > 0.001) {
            float tt = floor(t * 14.0);
            float row = floor(p.y * 28.0);
            if (ghash(float2(row, tt)) < g * 0.45) p.x += (ghash(float2(row * 1.7, tt + 3.1)) - 0.5) * 0.25 * g;
            if (ghash(float2(tt, 5.3)) < g) split = g * 0.015 * (0.4 + ghash(float2(tt, 8.1)));
        }
        // 動き：q を文字のかたまりの中の位置に
        float2 q = p;
        // 間隔は文字の余白（テクスチャのまわり）のぶんを引いて、すき間そのものの大きさにする
        // （余白は上下左右とも 1 行の高さの 0.3。TextLook.pad と同じ）
        float pad2 = lineH * 0.6;
        float gapX = lineH * u.pts[1].y - pad2, gapY = lineH * u.pts[1].z - pad2;
        if (m == 1) {
            float P = max(W + gapX, lineH * 0.05);
            q.x = pmod(p.x + moved + 0.5 * P, P) - 0.5 * P;
        } else if (m == 2) {
            float P = max(H + gapY, lineH * 0.05);
            q.y = pmod(p.y + moved + 0.5 * P, P) - 0.5 * P;
        } else if (m == 3) {
            // 敷き詰め：行ごとに逆向きに流れる
            float Py = max(H + gapY, lineH * 0.05), Px = max(W + gapX, lineH * 0.05);
            float row = floor((p.y + 0.5 * Py) / Py);
            q.y = pmod(p.y + 0.5 * Py, Py) - 0.5 * Py;
            float dir = fmod(abs(row), 2.0) < 0.5 ? 1.0 : -1.0;
            q.x = pmod(p.x + moved * dir + row * W * 0.37 + 0.5 * Px, Px) - 0.5 * Px;
        }
        float3 k;
        if (split > 0.0) {
            k = float3(textCover(aux, q + float2(split, 0.0), W, H, lod), textCover(aux, q, W, H, lod),
                       textCover(aux, q - float2(split, 0.0), W, H, lod));
        } else {
            k = float3(textCover(aux, q, W, H, lod));
        }
        float a = max(max(k.r, k.g), k.b);
        float3 col = u.b.y > 0.5 ? gpal(u.pal, u.palCount, saturate(q.x / W + 0.5)) : u.color.rgb;
        return float4(col * k, a);
    }
    if (u.kind >= 8 && u.kind <= 13) {
        // 縦の長さを 1 とした、中心が 0 の座標（y は下が +）
        float2 p = (px - 0.5 * u.size) / u.size.y;
        float aspect = u.size.x / u.size.y;
        if (u.kind == 8) return float4(u.color.rgb * u.a.x, 1.0);
        if (u.kind == 9) {
            // グラデーション：a = 形, 角度, 繰り返し, 動いた量
            float2 d = grot(p, u.a.y);
            float t;
            int shape = int(u.a.x + 0.5);
            if (shape == 1) t = length(p) / (0.5 * length(float2(aspect, 1.0)));
            else if (shape == 2) t = atan2(d.y, d.x) / 6.2831853 + 0.5;
            else t = d.x / aspect + 0.5;
            t = t * u.a.z - u.a.w;
            // 端で折り返して、つなぎ目が出ないように
            float x = 1.0 - abs(fract(t * 0.5) * 2.0 - 1.0);
            return float4(gpal(u.pal, u.palCount, x), 1.0);
        }
        if (u.kind == 10) {
            // ストライプ：a = 本数, 太さ, 角度, 動いた量 / b.x = ぼかし
            float sCoord = grot(p, u.a.z).y * u.a.x - u.a.w;
            float c = abs(fract(sCoord) - 0.5);
            float aa = fwidth(sCoord) + u.b.x * 0.5;
            float k = gcover(c - u.a.y * 0.5, aa);
            return float4(u.color.rgb * k, k);
        }
        if (u.kind == 11) {
            // チェッカー・格子・ドット：a = 模様, マスの数, 太さ, 動いた量（横へ流れる）
            float2 q = p * u.a.y + float2(u.a.w, 0.0);
            float2 f = fract(q);
            float aa = fwidth(q.x);
            int m = int(u.a.x + 0.5);
            float k;
            if (m == 0) {
                float2 cell = floor(q);
                k = fmod(abs(cell.x + cell.y), 2.0) < 0.5 ? 1.0 : 0.0;
            } else if (m == 1) {
                float d = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
                k = gcover(d - u.a.z * 0.5, aa);
            } else {
                k = gcover(length(f - 0.5) - u.a.z * 0.5, aa);
            }
            return float4(u.color.rgb * k, k);
        }
        if (u.kind == 12) {
            // ノイズ：a = 種類, 細かさ, 動いた量（時間）, コントラスト
            float v;
            if (u.a.x > 0.5) {
                // 砂嵐：粒は細かさで決まる。コマ（1/30 秒）ごとに変わる
                float grain = max(u.size.y / (u.a.y * 40.0), 1.0);
                v = ghash(floor(px / grain) + floor(u.a.z * 30.0) * float2(17.13, 9.71));
            } else {
                // なめらか：2 段重ねて、時間で 2 枚のあいだを行き来する
                float2 q = p * u.a.y;
                float t0 = floor(u.a.z), ft = smoothstep(0.0, 1.0, fract(u.a.z));
                float2 o0 = float2(t0 * 3.7, t0 * 1.9), o1 = o0 + float2(3.7, 1.9);
                float n0 = gnoise(q + o0) * 0.65 + gnoise(q * 2.1 + o0 * 1.3) * 0.35;
                float n1 = gnoise(q + o1) * 0.65 + gnoise(q * 2.1 + o1 * 1.3) * 0.35;
                v = mix(n0, n1, ft);
            }
            v = saturate((v - 0.5) * u.a.w + 0.5);
            return float4(u.color.rgb * v, 1.0);
        }
        // 図形：a = 形, 大きさ, 線の太さ, 数 / b = 角度, ぼかし
        float n = max(u.a.w, 1.0);
        float2 q = p * n;
        // 1 つのときは並べない（左右の端に隣の図形が出ないように）
        float2 f = grot(n < 1.5 ? q : fract(q + 0.5) - 0.5, u.b.x);
        float r = u.a.y * 0.5, th = u.a.z * 0.5;
        float sd;
        int m = int(u.a.x + 0.5);
        if (m == 0) sd = length(f) - r;
        else if (m == 1) sd = abs(length(f) - r) - th;
        else if (m == 2 || m == 3) {
            float2 qq = abs(f) - r;
            sd = length(max(qq, 0.0)) + min(max(qq.x, qq.y), 0.0);
            if (m == 3) sd = abs(sd) - th;
        } else {
            // 正三角形（上向き）
            const float k3 = 1.7320508;
            float2 t = float2(abs(f.x), -f.y - r * 0.25);
            t.x -= r; t.y += r / k3;
            if (t.x + k3 * t.y > 0.0) t = float2(t.x - k3 * t.y, -k3 * t.x - t.y) / 2.0;
            t.x -= clamp(t.x, -2.0 * r, 0.0);
            sd = -length(t) * sign(t.y);
        }
        float k = gcover(sd, fwidth(q.x) + u.b.y);
        return float4(u.color.rgb * k, k);
    }
    if (u.kind == 6) {
        // マスク（形）：a = 形, 反転, 位置X, 位置Y / b = 幅, 高さ, 角度, ぼかし（高さに対する割合）
        float4 c = tex.sample(s, uv);
        float2 p = px - float2(0.5 + u.a.z, 0.5 - u.a.w) * u.size;
        float an = -u.b.z * 3.14159265 / 180.0;
        p = float2(p.x * cos(an) - p.y * sin(an), p.x * sin(an) + p.y * cos(an));
        float2 half_ = max(float2(u.b.x, u.b.y) * u.size * 0.5, float2(0.5));
        float sd;
        if (u.a.x > 0.5) {
            sd = (length(p / half_) - 1.0) * min(half_.x, half_.y);
        } else {
            float2 q = abs(p) - half_;
            sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
        }
        float m = maskFrom(sd, u.b.w * u.size.y);
        if (u.a.y > 0.5) m = 1.0 - m;
        return c * m;
    }
    if (u.kind == 7) {
        // マスク（自由な形）：a = ぼかし（高さに対する割合）, 反転
        float4 c = tex.sample(s, uv);
        int n = min(u.ptCount, 32);
        if (n < 3) return u.a.y > 0.5 ? float4(0.0) : c;
        bool inside = false;
        float d2 = 1e20;
        for (int i = 0, j = n - 1; i < n; j = i++) {
            float2 a = (i & 1) ? u.pts[i >> 1].zw : u.pts[i >> 1].xy;
            float2 b = (j & 1) ? u.pts[j >> 1].zw : u.pts[j >> 1].xy;
            if (((a.y > px.y) != (b.y > px.y)) && (px.x < (b.x - a.x) * (px.y - a.y) / (b.y - a.y) + a.x)) inside = !inside;
            float2 e = b - a, w = px - a;
            float t = saturate(dot(w, e) / max(dot(e, e), 1e-6));
            float2 d = w - e * t;
            d2 = min(d2, dot(d, d));
        }
        float sd = inside ? -sqrt(d2) : sqrt(d2);
        float m = maskFrom(sd, u.a.x * u.size.y);
        if (u.a.y > 0.5) m = 1.0 - m;
        return c * m;
    }
    if (u.kind == 4) {
        // ストロボ：a.x = 光り方（0 色で光る / 1 消える / 2 反転）、a.y = 光り具合
        float4 c = tex.sample(s, uv);
        float k = saturate(u.a.y);
        int m = int(u.a.x + 0.5);
        if (m == 1) return c * (1.0 - k);
        if (m == 2) {
            float3 rgb = c.a > 1e-4 ? c.rgb / c.a : float3(0.0);
            return float4(mix(rgb, 1.0 - rgb, k) * c.a, c.a);
        }
        return mix(c, float4(u.color.rgb, 1.0), k);
    }
    if (u.kind == 0) {
        int h = int(u.a.x + 0.5), v = int(u.a.y + 0.5);
        if (h == 1 && uv.x > 0.5) uv.x = 1.0 - uv.x;
        if (h == 2 && uv.x < 0.5) uv.x = 1.0 - uv.x;
        if (v == 1 && uv.y > 0.5) uv.y = 1.0 - uv.y;
        if (v == 2 && uv.y < 0.5) uv.y = 1.0 - uv.y;
        return tex.sample(s, uv);
    }
    float2 cellPx = px;
    if (u.kind == 3 && u.a.z > 1.5) {
        // ドット：大きな四角ごとに同じ色にする
        float d = u.a.z;
        cellPx = floor(px / d);
        uv = (cellPx * d + d * 0.5) / u.size;
    }
    float4 c = tex.sample(s, uv);
    float alpha = c.a;
    float3 rgb = alpha > 1e-4 ? c.rgb / alpha : float3(0.0);
    if (u.kind == 1) {
        float L = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        float3 tint;
        if (int(u.a.x + 0.5) == 1) {
            // パレット：暗い所は左の色、明るい所は右の色。あいだはなめらかにつなぐ
            int n = max(u.palCount, 1);
            float x = saturate(L) * float(n - 1);
            int i = min(int(floor(x)), n - 2);
            tint = n == 1 ? u.pal[0].rgb : mix(u.pal[max(i, 0)].rgb, u.pal[max(i, 0) + 1].rgb, x - float(max(i, 0)));
        } else if (u.a.y > 0.5) {
            // カラー・明るさを保つ：色相と彩度だけその色にして、明るさは元のまま
            float cmax = max(u.color.r, max(u.color.g, u.color.b));
            float cmin = min(u.color.r, min(u.color.g, u.color.b));
            float cl = (cmax + cmin) * 0.5;
            float sat = cmax - cmin < 1e-4 ? 0.0 : (cmax - cmin) / (1.0 - abs(2.0 * cl - 1.0));
            float3 hue = cmax - cmin < 1e-4 ? float3(0.5) : (u.color.rgb - cmin) / (cmax - cmin);
            float C = (1.0 - abs(2.0 * L - 1.0)) * saturate(sat);
            tint = saturate(L + C * (hue - 0.5));
        } else {
            // カラー・明るさを保たない：黒は黒、灰色はその色を暗くしたもの、白はその色そのもの
            tint = u.color.rgb * L;
        }
        // 色相をずらす（動かすと色が回る）
        if (u.a.w > 0.001) tint = hueShift(tint, u.a.w / 360.0);
        rgb = mix(rgb, tint, u.a.z);
    } else if (u.kind == 2) {
        float3 v = saturate((rgb - u.a.x) / max(u.a.y - u.a.x, 1e-4));
        v = pow(v, float3(1.0 / max(u.a.z, 0.01)));
        rgb = mix(float3(u.a.w), float3(u.b.x), v);
    } else if (u.kind == 3) {
        float n = max(u.a.x, 2.0) - 1.0;
        int2 q = int2(cellPx) & 3;
        float t = bayer4[q.x + q.y * 4] / 16.0 - 0.5 + 1.0 / 32.0;
        rgb = saturate(floor(rgb * n + 0.5 + u.a.y * t) / n);
    } else if (u.kind == 14) {
        // 反転：0 = 色と明るさ、1 = 明るさだけ（色合いはそのまま）、2 = 色だけ（明るさはそのまま）
        float L = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        int m = int(u.a.x + 0.5);
        float3 inv = m == 1 ? saturate(rgb + 1.0 - 2.0 * L) : (m == 2 ? saturate(2.0 * L - rgb) : 1.0 - rgb);
        rgb = mix(rgb, inv, saturate(u.a.y));
    }
    return float4(rgb * alpha, alpha);
}

// ---- エコー（残像）：前の絵（hist）を薄めて、今の絵と重ねる ----
struct EchoUniforms {
    int mode;          // 0: 明るい方, 1: 加算, 2: 混ぜる
    float keep;        // 前の絵をどれだけ残すか（このコマの分。時間から計算済み）
    float zoom;        // 前の絵の拡大率（このコマの分）
    float hue;         // 前の絵の色相ずれ（このコマの分、0〜1）
    float amount;      // 残像の濃さ
    float mixAmt;      // エフェクトの不透明度（残像そのものは保ったまま、出す絵だけ混ぜる）
};

struct EchoOut {
    float4 hist [[color(0)]];   // 次のコマの「前の絵」（16bit）
    float4 out [[color(1)]];    // このコマの絵（次のエフェクトへ）
};

static float4 echoMix(constant EchoUniforms& u, float4 c, float4 h) {
    float4 t = h * u.keep * u.amount;
    if (u.mode == 1) return min(c + t, 1.0);
    if (u.mode == 2) return mix(c, h * u.amount, u.keep);
    return max(c, t);
}

fragment EchoOut fecho(VOut in [[stage_in]], constant EchoUniforms& u [[buffer(0)]],
                      texture2d<float> cur [[texture(0)]], texture2d<float> hist [[texture(1)]],
                      sampler s [[sampler(0)]]) {
    float2 uv = in.pos.xy / float2(cur.get_width(), cur.get_height());
    float4 c = cur.sample(s, uv);
    float2 huv = (uv - 0.5) / u.zoom + 0.5;
    float4 h = (any(huv < 0.0) || any(huv > 1.0)) ? float4(0.0) : hist.sample(s, huv);
    if (u.hue > 0.0001 && h.a > 1e-4) h = float4(hueShift(h.rgb / h.a, u.hue) * h.a, h.a);
    float4 r = echoMix(u, c, h);
    EchoOut o;
    o.hist = r;
    o.out = mix(c, r, saturate(u.mixAmt));
    return o;
}

// ---- 特殊合成：オーバードライブ加算 ----
// 下の絵 + このレイヤー で 100% を超えた分（あふれ）を、にじみ・色相ずれ・歪みに変える
struct ODUniforms {
    float3x3 inv;      // 出力のピクセル → このレイヤーの絵の UV
    float opacity;
    float4 a;          // にじみ, にじみの広がり(px), 色相ずれ(度), 波紋の強さ
    float4 b;          // 波紋の細かさ, 白飛びの抑え, 時刻, 縮小率（あふれの絵は 1/scale の大きさ）
    float4 c;          // 波紋の速さ, 波紋の広がり(px), 波紋の山の縮小率, 大きさの倍率（出力の高さ / 1080）
    float2 size;       // 出力の大きさ
};

static float4 odLayer(constant ODUniforms& u, texture2d<float> tex, sampler s, float2 px) {
    float2 uv = (u.inv * float3(px, 1.0)).xy;
    if (any(uv < 0.0) || any(uv > 1.0)) return float4(0.0);
    return tex.sample(s, uv) * u.opacity;   // 色に不透明度が掛かった絵
}

// 縮小：n x n ピクセルを平均する（あふれの 1/4 の絵から、波紋の山用のさらに小さい絵を作る）
// 2 枚の絵を k で混ぜる（FX パッドのフェード：かける前 a とかけた後 b）
fragment float4 fmix(VOut in [[stage_in]], constant float& k [[buffer(0)]],
                     texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]]) {
    uint2 p = uint2(in.pos.xy);
    return mix(a.read(p), b.read(p), k);
}

fragment float4 fdown(VOut in [[stage_in]], constant int& n [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    int2 base = int2(in.pos.xy) * n;
    int2 lim = int2(src.get_width(), src.get_height()) - 1;
    float3 acc = float3(0.0);
    for (int y = 0; y < n; y++) {
        for (int x = 0; x < n; x++) {
            acc += src.read(uint2(min(base + int2(x, y), lim))).rgb;
        }
    }
    return float4(acc / float(n * n), 1.0);
}

// あふれた分（縮小した絵に書く）
fragment float4 fodOver(VOut in [[stage_in]], constant ODUniforms& u [[buffer(0)]],
                        texture2d<float> below [[texture(0)]], texture2d<float> layer [[texture(1)]],
                        sampler s [[sampler(0)]]) {
    // 縮めた 1 ピクセルが受け持つ範囲（scale x scale）を平均する（小さく光る所を取りこぼさない）
    int n = max(int(u.b.w + 0.5), 1);
    float2 base = (in.pos.xy - 0.5) * u.b.w;
    float3 acc = float3(0.0);
    for (int y = 0; y < n; y++) {
        for (int x = 0; x < n; x++) {
            float2 px = base + float2(x, y) + 0.5;
            float3 sum = below.sample(s, px / u.size).rgb + odLayer(u, layer, s, px).rgb;
            acc += max(sum - 1.0, 0.0);
        }
    }
    return float4(acc / float(n * n), 1.0);
}

// ぼかし（縦か横の 1 方向。13 点）
struct BlurUniforms { float2 dir; float radius; };
fragment float4 fblur(VOut in [[stage_in]], constant BlurUniforms& u [[buffer(0)]],
                      texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    float2 size = float2(tex.get_width(), tex.get_height());
    float2 uv = in.pos.xy / size;
    float3 acc = float3(0.0); float wsum = 0.0;
    for (int i = -6; i <= 6; i++) {
        float t = float(i) / 6.0;
        float w = exp(-t * t * 2.0);
        acc += tex.sample(s, uv + u.dir * t * u.radius / size).rgb * w;
        wsum += w;
    }
    return float4(acc / wsum, 1.0);
}

static float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), w.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), w.x), w.y);
}

fragment float4 fodFinal(VOut in [[stage_in]], constant ODUniforms& u [[buffer(0)]],
                         texture2d<float> below [[texture(0)]], texture2d<float> layer [[texture(1)]],
                         texture2d<float> glow [[texture(2)]], texture2d<float> ripple [[texture(3)]],
                         sampler s [[sampler(0)]]) {
    float2 px = in.pos.xy;
    float2 uv = px / u.size;
    float3 g = glow.sample(s, uv).rgb;                      // ぼかしたあふれ
    float gl = max(g.r, max(g.g, g.b));
    // 波紋：あふれた所を山にして（大きくぼかした別の絵）、そこから外へ同心円の波が広がっていく。
    // 山の高さが同じ所を同じ位相にするので、明るい所を囲む輪になる。輪に沿って絵を押し出し、波の頂を光らせる
    float2 rsize = float2(ripple.get_width(), ripple.get_height());
    float2 tx = float2(1.0 / rsize.x, 0.0), ty = float2(0.0, 1.0 / rsize.y);
    float3 lw = float3(0.3333);
    float h = dot(ripple.sample(s, uv).rgb, lw);
    float2 grad = float2(dot(ripple.sample(s, uv + tx).rgb, lw) - dot(ripple.sample(s, uv - tx).rgb, lw),
                         dot(ripple.sample(s, uv + ty).rgb, lw) - dot(ripple.sample(s, uv - ty).rgb, lw));
    float gm = length(grad);
    float2 dir = gm > 1e-9 ? -grad / gm : float2(0.0);       // 明るい所から外向き
    // 山は光った所をぼかした形（ガウス）。その傾き÷高さ×σ² が、光った所からの距離になる（明るさに関係なく求まる）
    float spread = max(u.c.y, 1.0);
    float sigma = 0.5 * spread;
    float gradPx = gm / (2.0 * max(u.c.z, 1.0));             // 1 ピクセルあたりの傾き
    float dist = h > 1e-7 ? sigma * sigma * gradPx / h : 1e9;
    float wavelength = max(1600.0 / max(u.b.x, 1.0), 6.0) * u.c.w;   // 細かさ 24 で約 67px ごと（1080p）
    float phase = 6.2831853 * (dist / wavelength - u.b.z);   // 時間とともに外へ広がる（u.b.z は 時刻×速さ の小数部）
    float wave = sin(phase);
    float env = (1.0 - smoothstep(0.55 * spread, spread, dist)) * smoothstep(1e-7, 1e-5, h);
    float2 off = dir * wave * u.a.w * 14.0 * u.c.w * env;
    float3 sum = below.sample(s, (px + off) / u.size).rgb + odLayer(u, layer, s, px + off).rgb;
    float crest = pow(max(wave, 0.0), 10.0) * env * u.a.w;  // 波の頂の光（細い輪）
    // 色相ずれ：あふれた量だけ色を回す
    float over = max(max(sum.r, max(sum.g, sum.b)) - 1.0, 0.0);
    if (u.a.z > 0.001 && over > 0.0) {
        float v = max(sum.r, max(sum.g, sum.b));
        sum = hueShift(sum / v, over * u.a.z / 360.0) * v;
    }
    // 白飛びの抑え：1 の手前から寝かせる（0 なら切り捨て）
    float k = 1.0 - 0.35 * u.b.y;
    float3 soft = select(sum, k + (1.0 - k) * (1.0 - exp(-(sum - k) / max(1.0 - k, 1e-3))), sum > k);
    float3 col = soft;
    // にじみ（ハレーション）：あふれをぼかして足す。色相ずれと同じだけ色を回す
    float3 halo = g;
    if (u.a.z > 0.001 && gl > 0.0) halo = hueShift(g / gl, gl * u.a.z / 360.0) * gl;
    col += halo * u.a.x;
    float3 rc = dot(ripple.sample(s, uv).rgb, lw) > 0.0 ? ripple.sample(s, uv).rgb / max(h * 3.0, 1e-4) : float3(1.0);
    if (u.a.z > 0.001) rc = hueShift(saturate(rc), 0.5 * u.a.z / 360.0);
    col += crest * 0.8 * saturate(rc);
    return float4(saturate(col), 1.0);
}
"""

struct Uniforms {
    var hinv: simd_float3x3
    var viewSize: SIMD2<Float>
    var mode: Int32
    var master: Float = 1
}

struct LayerUniforms {
    var inv: simd_float3x3
    var opacity: Float
    var blend: Int32
    var premul: Int32 = 0
}

struct ODUniforms {
    var inv: simd_float3x3
    var opacity: Float
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var c: SIMD4<Float>
    var size: SIMD2<Float>
}

struct BlurUniforms {
    var dir: SIMD2<Float>
    var radius: Float
}

struct EffectUniforms {
    var kind: Int32
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var size: SIMD2<Float>
    var color = SIMD4<Float>(1, 1, 1, 1)
    var pal: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
              SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var palCount: Int32 = 0
    var ptCount: Int32 = 0
    var pts: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
              SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var mixAmt: Float = 1
}

struct EchoUniforms {
    var mode: Int32
    var keep: Float
    var zoom: Float
    var hue: Float
    var amount: Float
    var mixAmt: Float = 1
}

extension ClipTransform {
    /// 動かしていない（位置・スケール・角度が初期値）
    var isPlain: Bool { x == 0 && y == 0 && scale == 1 && rotation == 0 }

    /// 出力（w x h ピクセル）の中心を基準に、移動・回転・拡大する行列（ピクセル → ピクセル）
    func matrix(width w: Float, height h: Float) -> simd_float3x3 {
        let c = SIMD2(w / 2, h / 2)
        let to = c + SIMD2(x * w, -y * h)
        let co = cos(rotation), si = sin(rotation)
        let s = max(scale, 0.0001)
        // 列優先: T(to) * R * S * T(-c)
        let rs = simd_float3x3(columns: (SIMD3(co * s, si * s, 0), SIMD3(-si * s, co * s, 0), SIMD3(0, 0, 1)))
        let t1 = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(to.x, to.y, 1)))
        let t0 = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-c.x, -c.y, 1)))
        return t1 * rs * t0
    }
}

/// 合成する1レイヤーぶん
struct LayerDraw {
    let texture: MTLTexture
    /// レイヤーの不透明度（クリップの不透明度は transform 側）
    let opacity: Float
    let blend: BlendMode
    var transform = ClipTransform()
    /// レイヤー・コンポジションのトランスフォーム（不透明度は使わない）
    var layerTransform = ClipTransform()
    var compTransform = ClipTransform()
    /// GPU が使い終わるまで保持しておく映像フレーム
    let holder: FrameHolder?
    /// クリップのエフェクト（クリップのトランスフォームのあとにかける）
    var effects = EffectStack()
    /// エフェクト用の作業テクスチャを使い分ける番号
    var effectKey = 0
    /// texture が「色に不透明度が掛かった」絵か（トランスフォームしてからエフェクトを通した絵）
    var premul = false
}

/// 1 レイヤーぶんの描画（クロスフェード中はクリップ 2 つ）
struct LayerGroup {
    /// 奥 → 手前。opacity はクロスフェードの割合だけ（レイヤーの不透明度は下の opacity）
    var draws: [LayerDraw]
    var opacity: Float
    var blend: BlendMode
    var effects = EffectStack()
    /// 作業テクスチャ・コマ間引きの使い回しに使う番号（レイヤー）
    var key = 0
    /// 調整レイヤー：draws は空で、ここまでに重ねた絵全体に effects をかけ、opacity の割合で混ぜる
    var isAdjustment = false
    /// 特殊合成（オーバードライブ加算など）の値。blend が特殊合成のときに使う
    var blendFX = EffectStack()
}

final class MetalContext {
    static let shared = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let layerPipelines: [BlendMode: MTLRenderPipelineState]
    /// レイヤーのエフェクト用に、クリップを透明な下地に重ねる（不透明度も書く）
    let accumPipeline: MTLRenderPipelineState
    let effectPipeline: MTLRenderPipelineState
    /// オーバードライブ加算：あふれ・ぼかし・仕上げ
    let odOverPipeline: MTLRenderPipelineState
    let blurPipeline: MTLRenderPipelineState
    let odFinalPipeline: MTLRenderPipelineState
    let echoPipeline: MTLRenderPipelineState
    let downPipeline: MTLRenderPipelineState
    let mixPipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let textureCache: CVMetalTextureCache
    let dummyTexture: MTLTexture

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal が使えません")
        }
        self.device = device
        self.queue = queue

        let library = try! device.makeLibrary(source: shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vmain")
        desc.fragmentFunction = library.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)

        var lp: [BlendMode: MTLRenderPipelineState] = [:]
        for mode in BlendMode.allCases {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "vmain")
            d.fragmentFunction = library.makeFunction(name: "flayer")
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = .bgra8Unorm
            ca.writeMask = [.red, .green, .blue]
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceAlphaBlendFactor = .zero
            ca.destinationAlphaBlendFactor = .one
            // シェーダーは「色 × 不透明度」を出す（乗算だけは mix(1, 色, 不透明度)）
            switch mode {
            case .normal:   // 下 × (1 - a) + 上
                ca.sourceRGBBlendFactor = .one
                ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            case .add, .overdrive, .difference, .overlay, .softLight, .colorDodge, .hueOnly, .lumOnly,
                 .refract, .light, .flowInto, .interfere, .borrowColor, .dissolve:
                // 下 + 上（下の絵を読む重ね方は別のシェーダーで混ぜる。これは使わない）
                ca.sourceRGBBlendFactor = .one
                ca.destinationRGBBlendFactor = .one
            case .screen:   // 下 + 上 × (1 - 下)
                ca.sourceRGBBlendFactor = .oneMinusDestinationColor
                ca.destinationRGBBlendFactor = .one
            case .maskLuma, .maskInvert: // 下 × マスク
                ca.sourceRGBBlendFactor = .zero
                ca.destinationRGBBlendFactor = .sourceColor
            case .multiply: // 下 × 上
                ca.sourceRGBBlendFactor = .zero
                ca.destinationRGBBlendFactor = .sourceColor
            }
            lp[mode] = try! device.makeRenderPipelineState(descriptor: d)
        }
        layerPipelines = lp

        let ad = MTLRenderPipelineDescriptor()
        ad.vertexFunction = library.makeFunction(name: "vmain")
        ad.fragmentFunction = library.makeFunction(name: "flayer")
        let ac = ad.colorAttachments[0]!
        ac.pixelFormat = .bgra8Unorm
        ac.isBlendingEnabled = true
        ac.rgbBlendOperation = .add
        ac.alphaBlendOperation = .add
        ac.sourceRGBBlendFactor = .one
        ac.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ac.sourceAlphaBlendFactor = .one
        ac.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        accumPipeline = try! device.makeRenderPipelineState(descriptor: ad)

        let ed = MTLRenderPipelineDescriptor()
        ed.vertexFunction = library.makeFunction(name: "vmain")
        ed.fragmentFunction = library.makeFunction(name: "feffect")
        ed.colorAttachments[0].pixelFormat = .bgra8Unorm
        effectPipeline = try! device.makeRenderPipelineState(descriptor: ed)

        func plain(_ f: String, _ fmt: MTLPixelFormat = .bgra8Unorm) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "vmain")
            d.fragmentFunction = library.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = fmt
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        // あふれ・ぼかしは細かい値の差（波紋の山の傾き）を使うので 16bit の小数で持つ
        odOverPipeline = plain("fodOver", .rgba16Float)
        blurPipeline = plain("fblur", .rgba16Float)
        odFinalPipeline = plain("fodFinal")
        downPipeline = plain("fdown", .rgba16Float)
        mixPipeline = plain("fmix")
        // エコーの前の絵は少しずつ薄めるので、8bit だと暗い所が消え残る。16bit の小数で持つ
        let ecd = MTLRenderPipelineDescriptor()
        ecd.vertexFunction = library.makeFunction(name: "vmain")
        ecd.fragmentFunction = library.makeFunction(name: "fecho")
        ecd.colorAttachments[0].pixelFormat = .rgba16Float
        ecd.colorAttachments[1].pixelFormat = .bgra8Unorm
        echoPipeline = try! device.makeRenderPipelineState(descriptor: ecd)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache!

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        dummyTexture = device.makeTexture(descriptor: td)!
    }
}

/// エフェクトを順にかける。作業テクスチャは「番号」ごとに 2 枚持って使い回す（描画スレッドだけが使う）
final class EffectProcessor {
    private let ctx = MetalContext.shared
    private var pools: [String: [MTLTexture]] = [:]
    var storageMode: MTLStorageMode = .private
    /// テキストのジェネレーターの文字のテクスチャ
    private let texts = TextRasterCache()

    private func textures(_ key: String, width w: Int, height h: Int) -> [MTLTexture] {
        if let p = pools[key], p[0].width == w, p[0].height == h { return p }
        let p = (0..<2).compactMap { _ -> MTLTexture? in
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = storageMode
            return ctx.device.makeTexture(descriptor: td)
        }
        pools[key] = p
        return p
    }

    /// エコーの前の絵（エフェクトごとに 2 枚を交互に使う）と、最後に描いた時刻・最後に使った時刻（実時間）。
    /// しばらく使っていないものは捨てる（群れと同じ）
    private var echoes: [String: (tex: [MTLTexture], next: Int, last: Double, used: Double)] = [:]

    private func echoTextures(_ key: String, width w: Int, height h: Int, now: Double) -> (prev: MTLTexture, out: MTLTexture, dt: Double)? {
        var e = echoes[key]
        let wall = CACurrentMediaTime()
        if e == nil || e!.tex[0].width != w || e!.tex[0].height != h {
            echoes = echoes.filter { wall - $0.value.used < 30 }
            let t = (0..<2).compactMap { _ -> MTLTexture? in
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
                td.usage = [.renderTarget, .shaderRead]
                td.storageMode = storageMode
                return ctx.device.makeTexture(descriptor: td)
            }
            guard t.count == 2 else { return nil }
            e = (t, 0, -1, wall)
        }
        guard var e else { return nil }
        // しばらく描いていなかった（クリップを止めていた等）なら、前の絵は捨てる
        let dt = e.last < 0 || now - e.last > 0.5 || now < e.last ? -1 : now - e.last
        let prev = e.tex[1 - e.next], out = e.tex[e.next]
        e.next = 1 - e.next
        e.last = now
        e.used = wall
        echoes[key] = e
        return (prev, out, dt)
    }

    /// 群れ（エフェクトごと）。しばらく使っていないものは捨てる
    private var schools: [String: SchoolSim] = [:]

    private func drawSchool(_ e: Effect, key: String, into dst: MTLTexture, stack: EffectStack, now: Double,
                            cb: MTLCommandBuffer) {
        let wall = CACurrentMediaTime()
        var dt: Double
        let sim: SchoolSim
        if let s = schools[key] {
            sim = s
            dt = s.last < 0 ? 0 : now - s.last
            // 止めていた・巻き戻した：その場から続ける
            if dt < 0 || dt > 0.5 { dt = 0 }
        } else {
            schools = schools.filter { wall - $0.value.lastUsed < 30 }
            guard let s = SchoolSim(device: ctx.device, aspect: Double(dst.width) / Double(max(dst.height, 1))) else { return }
            schools[key] = s
            sim = s
            // はじめから群れらしく見えるように、少し前から動かしておく（経過時間ぶん。2.5〜15 秒）
            dt = min(max(now - stack.origin, 2.5), 15)
        }
        sim.last = now
        sim.lastUsed = wall
        SchoolRenderer.shared.render(e, sim: sim, into: dst, dt: dt, now: now, stack: stack, cb: cb)
    }

    /// 粘菌・パーティクル・ライフ・ホタル・アトラクター・時間のずらし・流体の状態
    let life = LifeStore()

    private func drawLife(_ e: Effect, key: String, input: MTLTexture, into dst: MTLTexture, stack: EffectStack, now: Double,
                          mixAmt: Float, cb: MTLCommandBuffer) {
        let o = stack.origin
        switch e.kind {
        case .physarum:
            let start = Int(e.value(12, at: now, beat: stack.beat, origin: o).rounded())
            let (gw, gh) = PhysarumSim.gridSize(width: dst.width, height: dst.height)
            guard let (s, dt) = life.state(key, now: now, origin: o, warm: 4,
                                           valid: { (s: PhysarumSim) in s.W == gw && s.H == gh && s.start == start },
                                           make: { PhysarumSim(width: dst.width, height: dst.height, start: start) }) else { return }
            s.render(e, into: dst, dt: dt, now: now, stack: stack, cb: cb)
        case .particleLife:
            guard let (s, dt) = life.state(key, now: now, origin: o, warm: 4, make: { ParticleLifeSim() }) else { return }
            s.render(e, into: dst, dt: dt, now: now, stack: stack, cb: cb)
        case .fireflies:
            let A = Double(dst.width) / Double(max(dst.height, 1))
            guard let (s, dt) = life.state(key, now: now, origin: o, warm: 4, make: { FireflySim(aspect: A) }) else { return }
            s.render(e, into: dst, dt: dt, now: now, stack: stack, cb: cb)
        case .attractor:
            guard let (s, dt) = life.state(key, now: now, origin: o, warm: 0.5, make: { AttractorSim() }) else { return }
            s.render(e, into: dst, dt: dt, now: now, stack: stack, cb: cb)
        case .timeWarp:
            guard let (s, _) = life.state(key, now: now, origin: o, warm: 0, make: { TimeWarpSim() }) else { return }
            s.render(e, input: input, into: dst, now: now, stack: stack, mixAmt: mixAmt, cb: cb)
        case .fluid:
            guard let (s, dt) = life.state(key, now: now, origin: o, warm: 0, make: { FluidSim() }) else { return }
            s.render(e, input: input, into: dst, dt: dt, now: now, stack: stack, mixAmt: mixAmt, cb: cb)
        case .syphonIn:
            SyphonDraw.shared.render(e, into: dst, now: now, stack: stack, cb: cb)
        case .camera:
            SyphonDraw.shared.renderCamera(e, into: dst, now: now, stack: stack, cb: cb)
        case .ndiIn:
            SyphonDraw.shared.renderNDI(e, into: dst, now: now, stack: stack, cb: cb)
        case .audioScope:
            guard let (s, dt) = life.state(key, now: now, origin: o, warm: 0, make: { AudioScopeSim() }) else { return }
            s.render(e, into: dst, dt: dt, now: now, stack: stack, cb: cb)
        case .glitchBox, .vhs:
            RetroRenderer.shared.simple(e, input: input, into: dst, now: now, stack: stack, mixAmt: mixAmt, cb: cb)
        case .videoFeedback:
            guard let (s, dt) = life.state(key, now: now, origin: o, warm: 0, make: { FeedbackSim() }) else { return }
            s.render(e, input: input, into: dst, dt: dt, now: now, stack: stack, mixAmt: mixAmt, cb: cb)
        case .crt:
            guard let (s, dt) = life.state(key, now: now, origin: o, warm: 0, make: { CRTSim() }) else { return }
            s.render(e, input: input, into: dst, dt: dt, now: now, stack: stack, mixAmt: mixAmt, cb: cb)
        case .rasterScan:
            guard let (s, _) = life.state(key, now: now, origin: o, warm: 0, make: { RasterSim() }) else { return }
            s.render(e, input: input, into: dst, now: now, stack: stack, mixAmt: mixAmt, cb: cb)
        case .film, .tiltShift, .emboss, .stretch, .displace, .droste:
            MoreFX2Renderer.shared.render(e, input: input, into: dst, now: now, stack: stack, mixAmt: mixAmt, cb: cb)
        case .blur, .lens, .polar, .tile, .keyer, .ledWall, .slices, .shake:
            MoreFX2Renderer.shared.render(e, input: input, into: dst, now: now, stack: stack, mixAmt: mixAmt, cb: cb)
        case .kaleidoscope, .rgbSplit, .pixelate, .edgeNeon, .zoomBlur, .ascii, .dither, .voronoiGlass:
            MoreFXRenderer.shared.render(e, input: input, into: dst, now: now, stack: stack, mixAmt: mixAmt, cb: cb)
        case .bloom:
            MoreFXRenderer.shared.bloom(e, input: input, into: dst, now: now, stack: stack, mixAmt: mixAmt, cb: cb)
        case .pixelSort:
            MoreFXRenderer.shared.pixelSort(e, input: input, into: dst, now: now, stack: stack, mixAmt: mixAmt, cb: cb)
        case .datamosh:
            guard let (s, dt) = life.state(key, now: now, origin: o, warm: 0, make: { MoshSim() }) else { return }
            s.render(e, input: input, into: dst, dt: dt, now: now, stack: stack, mixAmt: mixAmt, cb: cb)
        case _ where EffectKind.moreGenerators.contains(e.kind):
            drawMoreGenerator(e, key: key, into: dst, stack: stack, now: now, cb: cb)
        default:
            break
        }
    }

    /// テスト用：群れの魚の場所と速さ
    func schoolFish(_ key: String, count: Int) -> [(p: SIMD3<Float>, v: SIMD3<Float>)]? { schools[key]?.fish(count) }

    /// a と b（同じ大きさ）を k（0 = a、1 = b）で混ぜた絵
    func mix(_ a: MTLTexture, _ b: MTLTexture, k: Float, key: String, cb: MTLCommandBuffer) -> MTLTexture {
        if k >= 0.999 { return b }
        if k <= 0.001 { return a }
        let pool = textures(key, width: a.width, height: a.height)
        guard pool.count == 2, let dst = pool.first(where: { $0 !== a && $0 !== b }) else { return b }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return b }
        var kk = k
        enc.setRenderPipelineState(ctx.mixPipeline)
        enc.setFragmentBytes(&kk, length: MemoryLayout<Float>.stride, index: 0)
        enc.setFragmentTexture(a, index: 0)
        enc.setFragmentTexture(b, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        return dst
    }

    /// input にエフェクトを上から順にかけた結果（エフェクトが無ければ input のまま）
    func apply(_ stack: EffectStack, to input: MTLTexture, key: String, cb: MTLCommandBuffer,
               now: Double = CACurrentMediaTime()) -> MTLTexture {
        let effects = stack.spatial
        guard !effects.isEmpty else { return input }
        let pool = textures(key, width: input.width, height: input.height)
        guard pool.count == 2 else { return input }
        var src = input
        // 作業テクスチャは交互に使う（かからないエフェクトを飛ばしても、読む絵と書く絵が同じにならないように数える）
        var pass = 0
        for e in effects {
            let mixAmt = Float(e.mix(at: now, beat: stack.beat, origin: stack.origin))
            // 不透明度 0 は飛ばす（エコーは残像を続けるために描く）
            if mixAmt < 0.001 && e.kind != .echo { continue }
            let i = pass
            pass += 1
            if e.kind == .echo {
                guard let (prev, out, dt) = echoTextures(key + "/" + e.id.uuidString, width: input.width,
                                                         height: input.height, now: now) else { continue }
                let dst = pool[i % 2]
                let rpd = MTLRenderPassDescriptor()
                for (k, t) in [out, dst].enumerated() {
                    rpd.colorAttachments[k].texture = t
                    rpd.colorAttachments[k].loadAction = .dontCare
                    rpd.colorAttachments[k].storeAction = .store
                }
                guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return src }
                func v(_ j: Int) -> Double { e.value(j, at: now, beat: stack.beat, origin: stack.origin) }
                // 時間で決める（プレビューと出力でコマ数が違っても、同じ速さで消える・広がる）
                let step = max(dt, 0)
                // 「残る長さ」で 1/100（ほぼ見えない）まで薄まる
                let keep = dt < 0 ? 0 : pow(0.01, step / max(v(1), 0.01))
                var u = EchoUniforms(mode: Int32(v(0).rounded()), keep: Float(keep),
                                     zoom: Float(pow(1 + v(2), step)), hue: Float(v(3) / 360 * step),
                                     amount: Float(v(4)), mixAmt: mixAmt)
                enc.setRenderPipelineState(ctx.echoPipeline)
                enc.setFragmentBytes(&u, length: MemoryLayout<EchoUniforms>.stride, index: 0)
                enc.setFragmentTexture(src, index: 0)
                enc.setFragmentTexture(prev, index: 1)
                enc.setFragmentSamplerState(ctx.sampler, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.endEncoding()
                src = dst
                continue
            }
            if e.kind == .school {
                let dst = pool[i % 2]
                drawSchool(e, key: key + "/" + e.id.uuidString, into: dst, stack: stack, now: now, cb: cb)
                src = dst
                continue
            }
            if e.kind.isStateful {
                let dst = pool[i % 2]
                drawLife(e, key: key + "/" + e.id.uuidString, input: src, into: dst, stack: stack, now: now,
                         mixAmt: mixAmt, cb: cb)
                src = dst
                continue
            }
            // テキスト：文字のテクスチャ（描き直すときはミップマップ作りを先に積むので、描画の前に用意する）
            var text: (TextRasterCache.Raster, TextFrame)?
            if e.kind.isText {
                let f = TextFrame.at(e, t: now, beat: stack.beat, origin: stack.origin)
                guard let r = texts.raster(e, frame: f, outHeight: input.height, cb: cb) else {
                    // 文字が空：透明な絵
                    let dst = pool[i % 2]
                    let rpd = MTLRenderPassDescriptor()
                    rpd.colorAttachments[0].texture = dst
                    rpd.colorAttachments[0].loadAction = .clear
                    rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                    rpd.colorAttachments[0].storeAction = .store
                    cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
                    src = dst
                    continue
                }
                text = (r, f)
            }
            let dst = pool[i % 2]
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = dst
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return src }
            var (va, vb) = e.shaderValues(at: now, beat: stack.beat, origin: stack.origin)
            // ドットの大きさ（px）は 1080p での大きさ。絵の大きさに比例させて、プレビューと出力で同じ見え方に
            if e.kind == .posterize { va.z = max(va.z * Float(input.height) / 1080, 1) }
            var u = EffectUniforms(kind: e.kind.shaderIndex, a: va, b: vb,
                                   size: SIMD2(Float(input.width), Float(input.height)))
            u.color = e.color.simd
            u.mixAmt = mixAmt
            let p = (e.palette.isEmpty ? [RGB.black, RGB.white] : Array(e.palette.prefix(Effect.maxPalette))).map(\.simd)
            func at(_ i: Int) -> SIMD4<Float> { i < p.count ? p[i] : p[p.count - 1] }
            u.pal = (at(0), at(1), at(2), at(3), at(4), at(5), at(6), at(7))
            u.palCount = Int32(p.count)
            if e.kind == .polyMask {
                // 点はピクセルで渡す（1 つの float4 に 2 点）
                let sz = SIMD2(Float(input.width), Float(input.height))
                let pts = e.points.prefix(Effect.maxPoints).map { SIMD2(Float($0.x), Float($0.y)) * sz }
                var packed = [SIMD4<Float>](repeating: .zero, count: 16)
                for (i, q) in pts.enumerated() {
                    if i % 2 == 0 { packed[i / 2].x = q.x; packed[i / 2].y = q.y } else { packed[i / 2].z = q.x; packed[i / 2].w = q.y }
                }
                withUnsafeMutableBytes(of: &u.pts) { raw in
                    packed.withUnsafeBytes { raw.copyMemory(from: $0) }
                }
                u.ptCount = Int32(pts.count)
            }
            if e.kind == .flow {
                func v(_ j: Int) -> Double { e.value(j, at: now, beat: stack.beat, origin: stack.origin) }
                let el = max(now - stack.origin, 0).truncatingRemainder(dividingBy: 10000)
                u.pts.0 = SIMD4(Float(v(8)), Float(v(9)), Float(v(10)), Float(v(11)))
                u.pts.1 = SIMD4(Float(v(12)), Float(el), Float(v(13)), Float(v(14)))
            }
            if e.kind == .dots {
                func v(_ j: Int) -> Double { e.value(j, at: now, beat: stack.beat, origin: stack.origin) }
                let el = max(now - stack.origin, 0)
                let ph = (v(11) * el * 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi * 1000)
                u.pts.0 = SIMD4(Float(v(8)), Float(v(9)), Float(v(10)), Float(ph))
                u.pts.1 = SIMD4(Float(v(12)), Float(v(13)), Float(v(14)), Float(v(15)))
                u.pts.2 = SIMD4(Float(v(16)), Float(v(17)), Float(el.truncatingRemainder(dividingBy: 10000)), 0)
                // ふらふらの量・進んだ量（速さ × 秒）・光のにじみ
                let wanderT = (v(19) * el).truncatingRemainder(dividingBy: 10000)
                u.pts.3 = SIMD4(Float(v(18)), Float(wanderT), Float(v(20)), 0)
            }
            if e.kind == .lines {
                // 波の位相（波の速さ × 秒）・線ごとのずれ・奥への傾き・遠くを暗く
                func v(_ j: Int) -> Double { e.value(j, at: now, beat: stack.beat, origin: stack.origin) }
                let ph = (v(7) * max(now - stack.origin, 0) * 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi * 1000)
                u.pts.0 = SIMD4(Float(ph), Float(v(8)), Float(v(9)), Float(v(10)))
                u.pts.1 = SIMD4(Float(v(11)), Float(v(12)), Float(v(13)), Float(v(14)))
                u.pts.2 = SIMD4(Float(v(15)), 0, 0, 0)
            }
            if e.kind == .tunnel {
                // うねり・うねりの時間・中心 / まわりの区切り・色の付け方・明るさ・光のにじみ / 回った角度
                func v(_ j: Int) -> Double { e.value(j, at: now, beat: stack.beat, origin: stack.origin) }
                let el = max(now - stack.origin, 0)
                u.pts.0 = SIMD4(Float(v(8)), Float((v(9) * el).truncatingRemainder(dividingBy: 10000)), Float(v(10)), Float(v(11)))
                u.pts.1 = SIMD4(Float(v(12)), Float(v(13)), Float(v(14)), Float(v(15)))
                u.pts.2 = SIMD4(Float((v(5) * el).truncatingRemainder(dividingBy: 360)), 0, 0, 0)
            }
            if e.kind == .phyllotaxis {
                // 経過秒（粒の生まれた数はこれ × 生まれる速さ）と色のばらつき
                let el = Float(max(now - stack.origin, 0).truncatingRemainder(dividingBy: 100_000))
                u.pts.0 = SIMD4(el, Float(e.value(8, at: now, beat: stack.beat, origin: stack.origin)), 0, 0)
            }
            if let (r, f) = text {
                let el = Float(max(now - stack.origin, 0).truncatingRemainder(dividingBy: 1000))
                u.pts.0 = SIMD4(r.aspect, r.lines, Float(f.punch), el)
                u.pts.1 = SIMD4(Float(r.texture.height), Float(e.value(10, at: now, beat: stack.beat, origin: stack.origin)),
                                Float(e.value(11, at: now, beat: stack.beat, origin: stack.origin)),
                                e.kind == .clock ? 1 : 0)
            }
            enc.setRenderPipelineState(ctx.effectPipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            enc.setFragmentTexture(src, index: 0)
            enc.setFragmentTexture(text?.0.texture ?? ctx.dummyTexture, index: 1)
            enc.setFragmentSamplerState(ctx.sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            src = dst
        }
        return src
    }
}

/// レイヤーを重ねて1枚の画像にする（コーナーピンをかける前の画）。
/// クリップ → レイヤー → コンポジションの順にエフェクトをかける
final class Compositor {
    private let ctx = MetalContext.shared
    private(set) var target: MTLTexture?
    /// セルフテストで中身を読むときは .shared にする
    var storageMode: MTLStorageMode = .private {
        didSet { fx.storageMode = storageMode }
    }
    private let fx = EffectProcessor()
    /// レイヤーのエフェクト用：クリップを重ねる下地（レイヤーごと）
    private var groupTargets: [Int: MTLTexture] = [:]
    /// ポスタライズ時間：前のコマの絵（レイヤーごと・コンポジション）
    private var groupCache: [Int: (tick: Int64, texture: MTLTexture, comp: ClipTransform)] = [:]
    private var compCache: (tick: Int64, texture: MTLTexture)?

    /// 1 枚ずつ重ねる（エフェクトなし。テスト用）。layers は奥 → 手前の順
    func composite(_ layers: [LayerDraw], width: Int, height: Int, cb: MTLCommandBuffer) -> MTLTexture? {
        composite(layers.map { LayerGroup(draws: [$0], opacity: 1, blend: $0.blend, key: -1) },
                  effects: EffectStack(), width: width, height: height, cb: cb)
    }

    /// クリップのトランスフォームをかけた絵（出力の大きさ、周りは透明）を作る。エフェクトの前に使う
    private var placeTargets: [Int: MTLTexture] = [:]
    private func place(_ d: LayerDraw, key: Int, width w: Int, height h: Int, cb: MTLCommandBuffer) -> MTLTexture? {
        let t: MTLTexture
        if let c = placeTargets[key], c.width == w, c.height == h { t = c } else {
            guard let c = makeTexture(w, h) else { return nil }
            placeTargets[key] = c
            t = c
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = t
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        let fw = Float(w), fh = Float(h)
        let m = d.transform.matrix(width: fw, height: fh) * simd_float3x3(diagonal: SIMD3(fw, fh, 1))
        var u = LayerUniforms(inv: m.inverse, opacity: 1, blend: 0, premul: d.premul ? 1 : 0)
        enc.setFragmentSamplerState(ctx.sampler, index: 0)
        enc.setRenderPipelineState(ctx.accumPipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        enc.setFragmentTexture(d.texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        return t
    }

    /// groups は奥 → 手前の順。effects はコンポジションのエフェクト
    func composite(_ groups: [LayerGroup], effects: EffectStack, width: Int, height: Int,
                   cb: MTLCommandBuffer, now: Double = CACurrentMediaTime()) -> MTLTexture? {
        let w = max(width, 1), h = max(height, 1)
        // ポスタライズ時間（コンポジション）：同じコマの間は前の絵をそのまま使う
        let compTick = effects.tick(at: now)
        if let compTick, let c = compCache, c.tick == compTick, c.texture.width == w, c.texture.height == h {
            return c.texture
        }
        if target?.width != w || target?.height != h {
            target = makeTexture(w, h)
        }
        guard let target else { return nil }
        let fw = Float(w), fh = Float(h)
        let uvToPx = simd_float3x3(diagonal: SIMD3(fw, fh, 1))

        // 1. クリップ・レイヤーのエフェクト（下ごしらえ）。最後に重ねるものを並べる
        struct Final {
            var texture: MTLTexture?; var matrix: simd_float3x3; var opacity: Float; var blend: BlendMode; var premul: Bool
            /// 調整レイヤー：下の絵と置き換える
            var replace = false
            /// 調整レイヤー：ここまでの絵にかけるエフェクト
            var adjust: LayerGroup? = nil
            /// 特殊合成：下の絵を読んで混ぜる
            var special: LayerGroup? = nil
        }
        var finals: [Final] = []
        for g in groups {
            if g.isAdjustment {
                finals.append(Final(texture: nil, matrix: uvToPx, opacity: g.opacity, blend: .normal, premul: true,
                                    replace: true, adjust: g))
                continue
            }
            // クリップのエフェクト
            var draws = g.draws
            for i in draws.indices where !draws[i].effects.spatial.isEmpty {
                var d = draws[i]
                var src: MTLTexture = d.texture
                // クリップのトランスフォーム（位置・スケール・角度）を先にかけてから、エフェクトを通す。
                // 回したクリップにミラーをかけると、回った絵がミラーになる（Resolume と同じ順番）
                if !d.transform.isPlain, let placed = place(d, key: d.effectKey, width: w, height: h, cb: cb) {
                    src = placed
                    d.transform = ClipTransform(opacity: d.transform.opacity)
                    d.premul = true
                }
                let out = fx.apply(d.effects, to: src, key: "c\(d.effectKey)", cb: cb, now: now)
                draws[i] = LayerDraw(texture: out, opacity: d.opacity, blend: d.blend, transform: d.transform,
                                     layerTransform: d.layerTransform, compTransform: d.compTransform,
                                     holder: d.holder, effects: d.effects, effectKey: d.effectKey, premul: d.premul)
            }
            if g.effects.isEmpty && !g.blend.readsBelow {
                for d in draws {
                    let m = d.compTransform.matrix(width: fw, height: fh)
                        * d.layerTransform.matrix(width: fw, height: fh)
                        * d.transform.matrix(width: fw, height: fh) * uvToPx
                    finals.append(Final(texture: d.texture, matrix: m, opacity: g.opacity * d.opacity * d.transform.opacity,
                                        blend: g.blend, premul: d.premul))
                }
                continue
            }
            // レイヤーのエフェクト：このレイヤーのクリップを透明な下地に重ねてから、エフェクトをかける
            let comp = draws.first?.compTransform ?? groupCache[g.key]?.comp ?? ClipTransform()
            let tick = g.effects.tick(at: now)
            var layerTex: MTLTexture?
            if let tick, let c = groupCache[g.key], c.tick == tick, c.texture.width == w, c.texture.height == h {
                layerTex = c.texture
            } else if !draws.isEmpty {
                let gt: MTLTexture
                if let t = groupTargets[g.key], t.width == w, t.height == h { gt = t } else {
                    guard let t = makeTexture(w, h) else { continue }
                    groupTargets[g.key] = t
                    gt = t
                }
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = gt
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].storeAction = .store
                rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { continue }
                enc.setFragmentSamplerState(ctx.sampler, index: 0)
                enc.setRenderPipelineState(ctx.accumPipeline)
                for d in draws {
                    let m = d.layerTransform.matrix(width: fw, height: fh) * d.transform.matrix(width: fw, height: fh) * uvToPx
                    var u = LayerUniforms(inv: m.inverse, opacity: d.opacity * d.transform.opacity, blend: 0,
                                          premul: d.premul ? 1 : 0)
                    enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                    enc.setFragmentTexture(d.texture, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
                enc.endEncoding()
                let out = fx.apply(g.effects, to: gt, key: "l\(g.key)", cb: cb, now: now)
                layerTex = out
                if let tick {
                    // 次のコマまで同じ絵を使うので、作業テクスチャとは別に取っておく
                    let keep = groupCache[g.key]?.texture
                    let dst = (keep?.width == w && keep?.height == h && keep !== out) ? keep! : makeTexture(w, h)
                    if let dst, let blit = cb.makeBlitCommandEncoder() {
                        blit.copy(from: out, to: dst)
                        blit.endEncoding()
                        groupCache[g.key] = (tick, dst, comp)
                        layerTex = dst
                    }
                } else {
                    groupCache[g.key] = nil
                }
            }
            if let layerTex {
                finals.append(Final(texture: layerTex, matrix: comp.matrix(width: fw, height: fh) * uvToPx,
                                    opacity: g.opacity, blend: g.blend, premul: true,
                                    special: g.blend.readsBelow ? g : nil))
            }
        }

        // 2. 重ねる（調整レイヤーが来たら、そこまでの絵にエフェクトをかけてから続ける）
        func beginPass(clear: Bool) -> MTLRenderCommandEncoder? {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = clear ? .clear : .load
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            let enc = cb.makeRenderCommandEncoder(descriptor: rpd)
            enc?.setFragmentSamplerState(ctx.sampler, index: 0)
            return enc
        }
        guard var enc = beginPass(clear: true) else { return nil }
        for f in finals {
            var texture = f.texture
            if let adj = f.adjust {
                enc.endEncoding()
                let key = 20000 + adj.key
                let tick = adj.effects.tick(at: now)
                if let tick, let c = groupCache[key], c.tick == tick, c.texture.width == w, c.texture.height == h {
                    texture = c.texture
                } else {
                    let out = fx.apply(adj.effects.masksLast, to: target, key: "a\(adj.key)", cb: cb, now: now)
                    // ポスタライズ時間だけのときも、前のコマの絵を取っておく（下のレイヤー全体がカクカクになる）
                    if let tick, let dst = (groupCache[key]?.texture.width == w && groupCache[key]?.texture.height == h)
                        ? groupCache[key]!.texture : makeTexture(w, h), let blit = cb.makeBlitCommandEncoder() {
                        blit.copy(from: out, to: dst)
                        blit.endEncoding()
                        groupCache[key] = (tick, dst, ClipTransform())
                        texture = dst
                    } else {
                        if tick == nil { groupCache[key] = nil }
                        texture = out === target ? nil : out
                    }
                }
                guard let e = beginPass(clear: false) else { return nil }
                enc = e
            }
            if let sp = f.special, let texture {
                // 特殊合成：下の絵を写し取ってから、シェーダーで混ぜて書き戻す
                enc.endEncoding()
                if sp.blend == .overdrive {
                    overdrive(sp, layer: texture, matrix: f.matrix, opacity: f.opacity, target: target,
                              width: w, height: h, cb: cb, now: now)
                } else {
                    blender.blend(sp, layer: texture, matrix: f.matrix, opacity: f.opacity, target: target, cb: cb, now: now)
                }
                guard let e = beginPass(clear: false) else { return nil }
                enc = e
                continue
            }
            guard let texture, let p = ctx.layerPipelines[f.blend] else { continue }
            var u = LayerUniforms(inv: f.matrix.inverse, opacity: f.opacity, blend: Int32(f.blend.rawValue),
                                  premul: f.replace ? 2 : (f.premul ? 1 : 0))
            enc.setRenderPipelineState(p)
            enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()

        // 3. コンポジションのエフェクト
        let result = fx.apply(effects, to: target, key: "comp", cb: cb, now: now)
        if let compTick {
            let keep = compCache?.texture
            if let dst = (keep?.width == w && keep?.height == h) ? keep : makeTexture(w, h),
               let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: result, to: dst)
                blit.endEncoding()
                compCache = (compTick, dst)
                return dst
            }
        } else {
            compCache = nil
        }
        return result
    }

    /// 差分・屈折・光で照らす などの、下の絵を読む重ね方
    private let blender = SpecialBlender()

    /// オーバードライブ加算（下の絵 + このレイヤーで 100% を超えた分を、にじみ・色相ずれ・歪みに）
    private var odBelow: MTLTexture?
    private var odLow: [MTLTexture] = []
    /// 波紋の山（もっと小さく縮めて大きくぼかす）
    private var odRipple: [MTLTexture] = []
    private func overdrive(_ g: LayerGroup, layer: MTLTexture, matrix: simd_float3x3, opacity: Float,
                           target: MTLTexture, width w: Int, height h: Int, cb: MTLCommandBuffer, now: Double) {
        let scale = 4
        let lw = max(w / scale, 1), lh = max(h / scale, 1)
        if odBelow?.width != w || odBelow?.height != h { odBelow = makeTexture(w, h) }
        if odLow.count != 2 || odLow[0].width != lw || odLow[0].height != lh {
            odLow = (0..<2).compactMap { _ in makeTexture(lw, lh, .rgba16Float) }
        }
        let rscale = 32
        let rw = max(w / rscale, 1), rh = max(h / rscale, 1)
        if odRipple.count != 2 || odRipple[0].width != rw || odRipple[0].height != rh {
            odRipple = (0..<2).compactMap { _ in makeTexture(rw, rh, .rgba16Float) }
        }
        guard let below = odBelow, odLow.count == 2, odRipple.count == 2, let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: target, to: below)
        blit.endEncoding()

        let fx = g.blendFX.effects.first ?? Effect(kind: .overdrive)
        func v(_ i: Int) -> Float { Float(fx.value(i, at: now, beat: g.blendFX.beat, origin: g.blendFX.origin)) }
        // px の値は 1080p の出力での大きさ。プレビューでも本番の出力でも、画面に対して同じ見え方になるように比例させる
        let k = Float(h) / 1080
        // 波紋の進み（時刻×速さ）は Double で小数部だけにして渡す（途中で跳ばない）
        let wave = now * fx.value(6, at: now, beat: g.blendFX.beat, origin: g.blendFX.origin)
        var u = ODUniforms(inv: matrix.inverse, opacity: opacity,
                           a: SIMD4(v(0), v(1), v(2), v(3)),
                           b: SIMD4(v(4), v(5), Float(wave - floor(wave)), Float(scale)),
                           c: SIMD4(v(6), v(7) * k, Float(rscale), k),
                           size: SIMD2(Float(w), Float(h)))
        func pass(_ dst: MTLTexture, _ pipe: MTLRenderPipelineState, _ setup: (MTLRenderCommandEncoder) -> Void) {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = dst
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            guard let e = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
            e.setRenderPipelineState(pipe)
            e.setFragmentSamplerState(ctx.sampler, index: 0)
            setup(e)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            e.endEncoding()
        }
        // 1. あふれ（1/4 の大きさ）
        pass(odLow[0], ctx.odOverPipeline) { e in
            e.setFragmentBytes(&u, length: MemoryLayout<ODUniforms>.stride, index: 0)
            e.setFragmentTexture(below, index: 0)
            e.setFragmentTexture(layer, index: 1)
        }
        // 1b. 波紋の山のもと：あふれ（1/4）を 8 x 8 ずつ平均して 1/32 に（全部のピクセルを読み直すより大幅に軽い）
        if v(3) > 0.001 {
            var n = Int32(rscale / scale)
            pass(odRipple[0], ctx.downPipeline) { e in
                e.setFragmentBytes(&n, length: MemoryLayout<Int32>.stride, index: 0)
                e.setFragmentTexture(odLow[0], index: 0)
            }
        }
        // 2. ぼかす（横 → 縦）
        let radius = v(1) * k / Float(scale)
        for (src, dst, dir) in [(odLow[0], odLow[1], SIMD2<Float>(1, 0)), (odLow[1], odLow[0], SIMD2<Float>(0, 1))] {
            var bu = BlurUniforms(dir: dir, radius: radius)
            pass(dst, ctx.blurPipeline) { e in
                e.setFragmentBytes(&bu, length: MemoryLayout<BlurUniforms>.stride, index: 0)
                e.setFragmentTexture(src, index: 0)
            }
        }
        // 2b. 波紋の山：1/32 の大きさで、波紋の広がりだけ大きくぼかす
        if v(3) > 0.001 {
            // 3 回ぼかして、全体で σ = 広がり/2 になるように（1 回あたりの半径は 13 点で無理なく届く大きさ）
            let rr = v(7) * k / (Float(rscale) * 1.732)
            for _ in 0..<3 {
                for (src, dst, dir) in [(odRipple[0], odRipple[1], SIMD2<Float>(1, 0)), (odRipple[1], odRipple[0], SIMD2<Float>(0, 1))] {
                    var bu = BlurUniforms(dir: dir, radius: rr)
                    pass(dst, ctx.blurPipeline) { e in
                        e.setFragmentBytes(&bu, length: MemoryLayout<BlurUniforms>.stride, index: 0)
                        e.setFragmentTexture(src, index: 0)
                    }
                }
            }
        }
        // 3. 仕上げて、合成先に書き戻す
        pass(target, ctx.odFinalPipeline) { e in
            e.setFragmentBytes(&u, length: MemoryLayout<ODUniforms>.stride, index: 0)
            e.setFragmentTexture(below, index: 0)
            e.setFragmentTexture(layer, index: 1)
            e.setFragmentTexture(odLow[0], index: 2)
            e.setFragmentTexture(odRipple[0], index: 3)
        }
    }

    private func makeTexture(_ w: Int, _ h: Int, _ fmt: MTLPixelFormat = .bgra8Unorm) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = storageMode
        return ctx.device.makeTexture(descriptor: td)
    }
}

/// 描画ループ。ディスプレイの vsync ごとに専用スレッド（CVDisplayLink）で動く。
/// メインスレッド（画面操作・SwiftUI）が忙しくても、出力の映像は止まらない。
/// 1 vsync ごとに: 各レイヤーの新しいフレームを取り込む → 登録された全ての画面（出力・プレビュー）に描く
final class RenderLoop {
    /// 何も出していないときに Syphon・NDI・照明へ送る黒（大きさが変わったら作り直す。描画スレッドだけで使う）
    private var black: MTLTexture?
    private func blackTexture(_ w: Int, _ h: Int) -> MTLTexture? {
        if let b = black, b.width == w, b.height == h { return b }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: max(w, 1), height: max(h, 1), mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        guard let t = MetalContext.shared.device.makeTexture(descriptor: td), let cb = MetalContext.shared.queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = t
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
        cb.commit()
        black = t
        return t
    }

    static let shared = RenderLoop(engine: .shared)

    struct Stats {
        var ticks = 0
        var newFrames = 0
        var maxNewFrameGapMs = 0.0
        var maxTickGapMs = 0.0
    }

    private let ctx = MetalContext.shared
    private let engine: Engine
    private var link: CVDisplayLink?

    // 下の 3 つは lock の中で触る
    private let lock = NSLock()
    /// 描画先の種類。出力（とその縮小プレビュー）か、選択中クリップのプレビューか
    enum TargetKind {
        /// 出力（コーナーピン・マスター込み）。操作画面の出力モニターも同じ
        case output
        /// コンポジション：全レイヤーの合成（コーナーピンなし、マスター込み）
        case composition
        /// 選択中のレイヤーだけ
        case layer
        /// 選択中のクリップだけ（出力していなくてもプレビュー用に再生）
        case clipPreview
        /// 編集中のシーン（出力しない）
        case scenePreview
    }
    private var targets: [ObjectIdentifier: (layer: CAMetalLayer, visible: Bool, kind: TargetKind, output: Int)] = [:]
    private var stats = Stats()
    private var lastTick = 0.0
    private var lastNewFrame = 0.0

    /// 描画スレッドだけが触る
    private var compositors: [ObjectIdentifier: Compositor] = [:]

    init(engine: Engine) {
        self.engine = engine
    }

    func start() {
        guard link == nil else { return }
        var l: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&l)
        guard let l else { NSLog("VJPlayer: CVDisplayLink を作れません"); return }
        CVDisplayLinkSetOutputHandler(l) { [weak self] _, _, _, _, _ in
            autoreleasepool { self?.tick() }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(l)
        link = l
    }

    func stop() {
        if let link { CVDisplayLinkStop(link) }
        link = nil
    }

    /// vsync を合わせるディスプレイ（出力先）。nil ならメインディスプレイ
    func setDisplay(_ id: CGDirectDisplayID?) {
        guard let link else { return }
        CVDisplayLinkSetCurrentCGDisplay(link, id ?? CGMainDisplayID())
    }

    func add(_ layer: CAMetalLayer, visible: Bool = true, kind: TargetKind = .output, output: Int = 0) {
        lock.withLock { targets[ObjectIdentifier(layer)] = (layer, visible, kind, output) }
        start()
    }

    func remove(_ layer: CAMetalLayer) {
        _ = lock.withLock { targets.removeValue(forKey: ObjectIdentifier(layer)) }
    }

    /// 出力の画面が、何番の出力か（出力の分割）
    func setOutput(_ layer: CAMetalLayer, _ output: Int) {
        lock.withLock { targets[ObjectIdentifier(layer)]?.output = output }
    }

    /// 隠れているウィンドウには描かない（描こうとすると次の描画先を待たされて全体が止まるため）
    func setVisible(_ layer: CAMetalLayer, _ visible: Bool) {
        lock.withLock { targets[ObjectIdentifier(layer)]?.visible = visible }
    }

    func resetStats() {
        lock.withLock {
            stats = Stats()
            lastTick = 0
            lastNewFrame = CACurrentMediaTime()
        }
    }

    func currentStats() -> Stats {
        lock.withLock { stats }
    }

    /// 画面下の状態表示用：前に呼んでから描いた回数と、いちばん長くあいた間隔（ms）。呼ぶと数え直す
    private var monitorTicks = 0
    private var monitorMaxGapMs = 0.0
    func takeMonitorCounts() -> (ticks: Int, maxGapMs: Double) {
        lock.withLock {
            defer { monitorTicks = 0; monitorMaxGapMs = 0 }
            return (monitorTicks, monitorMaxGapMs)
        }
    }

    /// フレームレートを落とすときのコマの選び方（描画スレッドだけが触る）
    private var gate = FrameGate()

    private func tick() {
        let now = CACurrentMediaTime()
        // フレームレートを決めていれば、その回数だけ描く（間のコマは前の絵のまま）
        let fps = engine.targetFPS()
        if fps > 0 {
            var period = link.map { CVDisplayLinkGetActualOutputVideoRefreshPeriod($0) } ?? 0
            if !(period > 0.001 && period < 0.1) { period = 1.0 / 60 }
            if !gate.shouldRender(now: now, fps: fps, halfPeriod: period / 2) { return }
        }
        let updated = engine.updateFrame()
        GPUProbe.tick(extra: lock.withLock { targets.values.filter(\.visible).map { "\($0.kind)\(Int($0.layer.drawableSize.width))x\(Int($0.layer.drawableSize.height))" }.joined(separator: " ") })
        // カーソルを合わせたエフェクト・ジェネレーターの見本（同じスレッドで描いて、作業テクスチャを取り合わないように）
        KindPreview.shared.renderIfNeeded(now: now)
        // 使われなくなったカメラ・Syphon の受け取り口を閉じる（クリップを消したあと、カメラが点いたままにならないように）
        CameraInputs.shared.closeIdle(now: now)
        SyphonInputs.shared.closeIdle(now: now)
        let current: [(ObjectIdentifier, CAMetalLayer, TargetKind, Int)] = lock.withLock {
            stats.ticks += 1
            monitorTicks += 1
            if lastTick > 0 {
                stats.maxTickGapMs = max(stats.maxTickGapMs, (now - lastTick) * 1000)
                monitorMaxGapMs = max(monitorMaxGapMs, (now - lastTick) * 1000)
            }
            lastTick = now
            if updated > 0 {
                stats.newFrames += 1
                if lastNewFrame > 0 { stats.maxNewFrameGapMs = max(stats.maxNewFrameGapMs, (now - lastNewFrame) * 1000) }
                lastNewFrame = now
            }
            return targets.filter { $0.value.visible }.map { ($0.key, $0.value.layer, $0.value.kind, $0.value.output) }
        }
        compositors = compositors.filter { id, _ in current.contains { $0.0 == id } }

        let params = engine.renderParams()
        let groups = engine.layerGroups()
        let compFX = engine.compEffects()
        let padFX = engine.padEffects()
        let kinds = Set(current.map { $0.2 })
        let clipGroups = kinds.contains(.clipPreview)
            ? engine.previewDraws().map { LayerGroup(draws: [$0], opacity: 1, blend: .normal, key: 1000) } : []
        let layerGroups = kinds.contains(.layer) ? engine.layerPreviewGroups() : []
        let sceneParts = kinds.contains(.scenePreview) ? engine.scenePreviewGroups() : nil
        let plain = RenderParams(homographyInverse: matrix_identity_float3x3, testPattern: false, master: 1)

        // 出力・コンポジションは中身が同じ。合成は 1 コマに 1 回だけ（縦横比が同じ画面のうち一番大きい大きさで）して、
        // 出力ウィンドウ・出力モニター・コンポジションのプレビューで使い回す（GPU を節約。見え方も必ず同じになる）
        // 解像度を決めていれば、どの画面にもその大きさで 1 回だけ合成する
        let fixedSize = params.format.size
        func sharedKey(_ w: Int, _ h: Int) -> Int { fixedSize == nil ? Self.aspectKey(w, h) : -1 }
        var shared: [Int: (size: (Int, Int), needs: Bool)] = [:]
        // 出力を分割しているときは、出力の画面は合成の形に関係ない（合成はコンポジションの形で 1 つ作って、そこから取る）
        let slicing = params.outputMap.active
        var sliceOutH = 0
        for (_, layer, kind, _) in current where kind == .output || kind == .composition {
            if slicing && kind == .output {
                sliceOutH = max(sliceOutH, Int(layer.drawableSize.height))
                continue
            }
            let w = Int(layer.drawableSize.width), h = Int(layer.drawableSize.height)
            guard w > 0, h > 0 else { continue }
            let key = sharedKey(w, h)
            let needs = kind == .composition || !params.testPattern
            let old = shared[key]
            let size = fixedSize ?? (old.map { $0.size.0 * $0.size.1 >= w * h ? $0.size : (w, h) } ?? (w, h))
            shared[key] = (size, (old?.needs ?? false) || needs)
        }
        var sliceKey: Int?
        if slicing && sliceOutH > 0 {
            if let best = shared.max(by: { $0.value.size.0 * $0.value.size.1 < $1.value.size.0 * $1.value.size.1 }) {
                sliceKey = best.key
                shared[best.key]?.needs = true
            } else {
                let h = min(max(sliceOutH, 720), 2160)
                let size = fixedSize ?? (max(Int((Double(h) * params.compAspect).rounded()), 2), h)
                let key = sharedKey(size.0, size.1)
                shared[key] = (size, true)
                sliceKey = key
            }
        }
        // 録画中は、画面が隠れていても合成する（録画の大きさで。同じ縦横比の画面があれば大きい方）
        let recSize = Recorder.shared.activeSize()
        var recKey: Int?
        if let (rw, rh) = recSize {
            let key = sharedKey(rw, rh)
            recKey = key
            let old = shared[key]
            let size = fixedSize ?? (old.map { $0.size.0 * $0.size.1 >= rw * rh ? $0.size : (rw, rh) } ?? (rw, rh))
            shared[key] = (size, true)
        }
        // Syphon・照明（Art-Net）で出しているときも合成する（出力・コンポジションの画面があれば、そのいちばん大きいものを使う）
        var syphonKey: Int?
        let syphonOn = SyphonOutput.shared.activeSize(outputSize: fixedSize, aspect: 16.0 / 9) != nil
        let dmxOn = ArtNetOutput.shared.isOn
        let ndiOn = NDIOutput.shared.isOn
        if syphonOn || dmxOn || ndiOn {
            if let best = shared.max(by: { $0.value.size.0 * $0.value.size.1 < $1.value.size.0 * $1.value.size.1 }) {
                syphonKey = best.key
                shared[best.key]?.needs = true
            } else {
                let (sw, sh) = fixedSize ?? (1920, 1080)
                let key = sharedKey(sw, sh)
                shared[key] = ((sw, sh), true)
                syphonKey = key
            }
        }
        var sharedTextures: [Int: MTLTexture] = [:]
        sharedCompositors = sharedCompositors.filter { shared[$0.key] != nil }
        padProcessors = padProcessors.filter { shared[$0.key] != nil }
        if !groups.isEmpty {
            for (key, v) in shared where v.needs {
                guard let cb = ctx.queue.makeCommandBuffer() else { continue }
                let comp = sharedCompositors[key] ?? Compositor()
                sharedCompositors[key] = comp
                if var t = comp.composite(groups, effects: compFX, width: v.size.0, height: v.size.1, cb: cb) {
                    // シーンのサムネイルにはパッドを入れない
                    lock.withLock { _lastComposite = t }
                    // 押しているパッドのエフェクトを最後にかける
                    if !padFX.isEmpty {
                        let fx = padProcessors[key] ?? EffectProcessor()
                        padProcessors[key] = fx
                        let now = CACurrentMediaTime()
                        for (n, pr) in padFX.enumerated() {
                            let out = fx.apply(pr.stack, to: t, key: "pad\(n)", cb: cb)
                            // 効き始め・消え方：かける前とかけた後を、今の効き具合で混ぜる
                            t = fx.mix(t, out, k: Float(pr.amount(at: now)), key: "padmix\(n)", cb: cb)
                        }
                    }
                    sharedTextures[key] = t
                }
                // GPU が使い終わるまで映像バッファを保持する
                cb.addCompletedHandler { _ in _ = groups }
                GPUProbe.track(cb, "合成\(v.size.0)x\(v.size.1)")
                cb.commit()
            }
        }

        // 出力の分割：元の絵がレイヤーのスライスがあれば、そのレイヤーだけを合成した絵を用意する（コンポジションと同じ大きさ）
        var sliceLayerTextures: [UUID: MTLTexture] = [:]
        if slicing && !params.testPattern && params.outputMap.slices.contains(where: { $0.enabled && $0.source.layerID != nil }),
           let cb = ctx.queue.makeCommandBuffer() {
            let size = sliceKey.flatMap { shared[$0]?.size }
                ?? (fixedSize ?? (max(Int((1080 * params.compAspect).rounded()), 2), 1080))
            sliceLayerTextures = sliceLayerSources.textures(for: params.outputMap, groups: groups,
                                                            layerIndex: { [engine] in engine.layerIndex(of: $0) },
                                                            width: size.0, height: size.1, cb: cb)
            cb.addCompletedHandler { _ in _ = groups }
            cb.commit()
        }

        // レイヤーが全部止まっているときは合成しないので、Syphon・NDI・照明には黒を送る
        // （録画が黒を描くのと同じ。送らないと、受け手に最後の絵が残る）
        let syphonTex = syphonKey.flatMap { k in
            sharedTextures[k] ?? (groups.isEmpty ? shared[k].flatMap { blackTexture($0.size.0, $0.size.1) } : nil)
        }
        if let tex = syphonTex, let cb = ctx.queue.makeCommandBuffer() {
            if syphonOn { SyphonOutput.shared.publish(tex, cb: cb) }
            if dmxOn { DMXSampler.shared.sample(tex, cb: cb) }
            if ndiOn { NDIOutput.shared.publish(tex, cb: cb) }
            cb.commit()
        }
        if let recKey, let (rw, rh) = recSize {
            // 縦横比が違う（解像度を決めているとき）なら、出力と同じ合わせ方で置く
            let tex = sharedTextures[recKey]
            let fitM = params.format.fitMatrix(screenAspect: Double(rw) / Double(rh))
            Recorder.shared.capture(tex, master: params.compMaster, fit: fitM, now: now)
        }

        for (id, layer, kind, output) in current {
            switch kind {
            case .output where slicing:
                // 出力の分割：この出力へ出すスライスを描く
                guard let drawable = layer.nextDrawable(), let cb = ctx.queue.makeCommandBuffer() else { continue }
                SliceRenderer.shared.draw(params.outputMap, output: output, composite: sliceKey.flatMap { sharedTextures[$0] },
                                          layers: sliceLayerTextures, master: params.master, testPattern: params.testPattern,
                                          guide: params.mapGuide, into: drawable.texture, cb: cb)
                cb.present(drawable)
                cb.commit()
            case .output where output != 0:
                // 分割していないときは、出力 2・3 は黒
                guard let drawable = layer.nextDrawable(), let cb = ctx.queue.makeCommandBuffer() else { continue }
                SliceRenderer.shared.draw(OutputMap(), output: output, composite: nil, master: 0, testPattern: false,
                                          into: drawable.texture, cb: cb)
                cb.present(drawable)
                cb.commit()
            case .output, .composition:
                let dw = Double(layer.drawableSize.width), dh = Double(layer.drawableSize.height)
                let tex = sharedTextures[sharedKey(Int(dw), Int(dh))]
                // 縦横比が違う画面には、合わせ方（収める・いっぱい・引き伸ばす）で置く
                let fitM = params.format.fitMatrix(screenAspect: dh > 0 ? dw / dh : 1)
                if kind == .output {
                    var p = params
                    p.homographyInverse = params.homographyInverse * fitM
                    present(layer, texture: params.testPattern ? nil : tex, params: p)
                } else {
                    var p = plain
                    p.master = params.compMaster
                    p.homographyInverse = fitM
                    present(layer, texture: tex, params: p)
                }
            case .layer, .clipPreview, .scenePreview:
                let comp = compositors[id] ?? Compositor()
                compositors[id] = comp
                if kind == .layer {
                    render(layer, compositor: comp, groups: layerGroups, effects: EffectStack(), params: plain)
                } else if kind == .clipPreview {
                    render(layer, compositor: comp, groups: clipGroups, effects: EffectStack(), params: plain)
                } else {
                    var p = plain
                    p.master = sceneParts?.master ?? 1
                    let t = render(layer, compositor: comp, groups: sceneParts?.groups ?? [],
                                   effects: sceneParts?.effects ?? EffectStack(), params: p)
                    lock.withLock { _lastScenePreview = t }
                }
            }
        }
    }

    /// 出力・コンポジションの合成（縦横比ごと。描画スレッドだけが触る）
    private var sharedCompositors: [Int: Compositor] = [:]
    /// パッドのエフェクト用（縦横比ごと。描画スレッドだけが触る）
    private var padProcessors: [Int: EffectProcessor] = [:]
    /// 出力の分割：元の絵がレイヤーのスライス用の合成（描画スレッドだけが触る）
    private let sliceLayerSources = SliceLayerSources()
    /// いちばん新しい出力の合成（シーンのサムネイル用。lock の中で）
    private var _lastComposite: MTLTexture?
    func lastComposite() -> MTLTexture? { lock.withLock { _lastComposite } }
    /// いちばん新しいシーン編集プレビューの合成（編集中のシーンのサムネイル用。lock の中で）
    private var _lastScenePreview: MTLTexture?
    func lastScenePreview() -> MTLTexture? { lock.withLock { _lastScenePreview } }
    /// テスト用：出力の合成を差し替える
    func setLastCompositeForTest(_ t: MTLTexture?) { lock.withLock { _lastComposite = t } }

    /// 縦横比を 1/100 に丸めた番号（同じ縦横比の画面は 1 つの合成を使い回す）
    private static func aspectKey(_ w: Int, _ h: Int) -> Int {
        h > 0 ? Int((Double(w) / Double(h) * 100).rounded()) : 0
    }

    /// できあがった合成の絵を画面に出す（コーナーピン・マスター・テストパターンはここで）
    private func present(_ layer: CAMetalLayer, texture: MTLTexture?, params: RenderParams) {
        guard let drawable = layer.nextDrawable(), let cb = ctx.queue.makeCommandBuffer() else { return }
        draw(drawable, composite: texture, params: params, cb: cb)
    }

    @discardableResult
    private func render(_ layer: CAMetalLayer, compositor: Compositor, groups: [LayerGroup], effects: EffectStack,
                        params: RenderParams) -> MTLTexture? {
        guard let drawable = layer.nextDrawable(), let cb = ctx.queue.makeCommandBuffer() else { return nil }
        let w = drawable.texture.width, h = drawable.texture.height
        let composite = groups.isEmpty ? nil
            : compositor.composite(groups, effects: effects, width: w, height: h, cb: cb)
        // GPU が使い終わるまで映像バッファを保持する
        cb.addCompletedHandler { _ in _ = groups }
        draw(drawable, composite: composite, params: params, cb: cb)
        return composite
    }

    private func draw(_ drawable: CAMetalDrawable, composite: MTLTexture?, params: RenderParams, cb: MTLCommandBuffer) {
        encodeDraw(into: drawable.texture, composite: composite, params: params, cb: cb)
        GPUProbe.track(cb, "画面\(drawable.texture.width)x\(drawable.texture.height)")
        cb.present(drawable)
        cb.commit()
    }

    /// 録画用：合成の絵を、録画の絵（target）にそのまま描く（コーナーピンなし。コミットは呼んだ側で）
    func drawComposite(_ composite: MTLTexture?, into target: MTLTexture, master: Float, fit: simd_float3x3,
                       cb: MTLCommandBuffer) {
        let p = RenderParams(homographyInverse: fit, testPattern: false, master: master)
        encodeDraw(into: target, composite: composite, params: p, cb: cb)
    }

    private func encodeDraw(into target: MTLTexture, composite: MTLTexture?, params: RenderParams, cb: MTLCommandBuffer) {
        let w = target.width, h = target.height
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let mode: Int32 = params.testPattern ? 2 : (composite == nil ? 0 : 1)
        var u = Uniforms(hinv: params.homographyInverse, viewSize: SIMD2(Float(w), Float(h)), mode: mode,
                         master: params.master)
        enc.setRenderPipelineState(ctx.pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(composite ?? ctx.dummyTexture, index: 0)
        enc.setFragmentSamplerState(ctx.sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
}

/// 出力ウィンドウとプレビューの描画先。描画は RenderLoop が専用スレッドで行う。
final class MetalLayerView: NSView {
    let metalLayer = CAMetalLayer()
    let kind: RenderLoop.TargetKind
    /// 何番の出力か（出力の分割。出力の画面のときだけ使う）
    private(set) var output = 0
    private var occlusionObserver: NSObjectProtocol?

    init(frame: NSRect, kind: RenderLoop.TargetKind = .output, output: Int = 0) {
        self.kind = kind
        self.output = output
        super.init(frame: frame)
        metalLayer.device = MetalContext.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.displaySyncEnabled = true
        metalLayer.maximumDrawableCount = 3
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { metalLayer }

    func setOutput(_ n: Int) {
        guard n != output else { return }
        output = n
        RenderLoop.shared.setOutput(metalLayer, n)
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else {
            RenderLoop.shared.remove(metalLayer)
            return
        }
        updateDrawableSize()
        RenderLoop.shared.add(metalLayer, visible: window.occlusionState.contains(.visible), kind: kind, output: output)
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self, let w = self.window else { return }
            RenderLoop.shared.setVisible(self.metalLayer, w.occlusionState.contains(.visible))
        }
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        RenderLoop.shared.remove(metalLayer)
    }
}

enum Homography {
    /// 単位正方形 (0,0)(1,0)(1,1)(0,1) を四隅 p0(TL) p1(TR) p2(BR) p3(BL) に写す行列
    static func squareToQuad(_ p: [SIMD2<Float>]) -> simd_float3x3 {
        let (x0, y0) = (p[0].x, p[0].y)
        let (x1, y1) = (p[1].x, p[1].y)
        let (x2, y2) = (p[2].x, p[2].y)
        let (x3, y3) = (p[3].x, p[3].y)
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        let den = dx1 * dy2 - dx2 * dy1
        let g = abs(den) < 1e-9 ? 0 : (dx3 * dy2 - dx2 * dy3) / den
        let h = abs(den) < 1e-9 ? 0 : (dx1 * dy3 - dx3 * dy1) / den
        let a = x1 - x0 + g * x1, b = x3 - x0 + h * x3, c = x0
        let d = y1 - y0 + g * y1, e = y3 - y0 + h * y3, f = y0
        return simd_float3x3(rows: [
            SIMD3(a, b, c),
            SIMD3(d, e, f),
            SIMD3(g, h, 1),
        ])
    }
}

/// 開発用：VJ_GPU_LOG=1 で、GPU の時間を何に使っているかを 2 秒ごとに書き出す（1 コマあたりの ms）
enum GPUProbe {
    static let on = ProcessInfo.processInfo.environment["VJ_GPU_LOG"] != nil
    private static let lock = NSLock()
    private static var sums: [String: (ms: Double, n: Int)] = [:]
    private static var ticks = 0
    private static var last = CACurrentMediaTime()

    /// commit の前に呼ぶ
    static func track(_ cb: MTLCommandBuffer, _ name: String) {
        guard on else { return }
        cb.addCompletedHandler { cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            lock.withLock { let o = sums[name] ?? (0, 0); sums[name] = (o.ms + ms, o.n + 1) }
        }
    }

    /// 描画ループが 1 コマごとに呼ぶ
    static func tick(extra: @autoclosure () -> String) {
        guard on else { return }
        let now = CACurrentMediaTime()
        let out: String? = lock.withLock {
            ticks += 1
            guard now - last >= 2 else { return nil }
            let t = Double(max(ticks, 1))
            let total = sums.values.reduce(0) { $0 + $1.ms }
            let parts = sums.sorted { $0.value.ms > $1.value.ms }
                .map { String(format: "%@ %.2f(×%.1f)", $0.key, $0.value.ms / t, Double($0.value.n) / t) }.joined(separator: "  ")
            let s = String(format: "GPU %.1f コマ/秒  合計 %.2f ms/コマ ｜ ", t / (now - last), total / t) + parts
            sums = [:]; ticks = 0; last = now
            return s
        }
        if let out { print(out + " ｜ " + extra()); fflush(stdout) }
    }
}
