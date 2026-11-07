import Metal
import QuartzCore
import simd

// 昔のアナログ映像機材をまねたエフェクト：
//   グリッチボックス（サーキットベンドした機材）・VHS テープ・ビデオフィードバック（カメラでモニターを撮る）・
//   ラスタースキャン（Rutt/Etra 風の映像シンセ）・CRT モニター

private let retroShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VO { float4 pos [[position]]; float2 uv; float4 col; };
vertex VO rt_full(uint vid [[vertex_id]]) {
    float2 c = float2(float(vid & 1), float(vid >> 1));
    VO o;
    o.pos = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.5, 1.0);
    o.uv = c; o.col = 0.0;
    return o;
}

static float h1(float x) { return fract(sin(x * 12.9898) * 43758.5453); }
static float h2(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float vn(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    return mix(mix(h2(i), h2(i + float2(1, 0)), w.x), mix(h2(i + float2(0, 1)), h2(i + float2(1, 1)), w.x), w.y);
}
static float3 toYIQ(float3 c) {
    return float3(dot(c, float3(0.299, 0.587, 0.114)), dot(c, float3(0.596, -0.274, -0.322)), dot(c, float3(0.211, -0.523, 0.312)));
}
static float3 fromYIQ(float3 y) {
    return float3(y.x + 0.956 * y.y + 0.621 * y.z, y.x - 0.272 * y.y - 0.647 * y.z, y.x - 1.106 * y.y + 1.703 * y.z);
}
static float rlum(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// a〜d = 値 / size = 絵の大きさ / time = 経過秒 / mixAmt = 不透明度
struct RU { float4 a, b, c, d; float2 size; float time; float mixAmt; };

// ============ グリッチボックス ============
// a = 同期くずし, 縦に流れる, ガクッとずれる, 色にじみ / b = 色ずれ(px), ゲイン, 折り返し, エンハンサー
// c = 色の発振, ノイズ, 走査線, 乱れる速さ
fragment float4 rt_glitch(VO in [[stage_in]], constant RU& u [[buffer(0)]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 px = in.pos.xy;
    float H = u.size.y, k = H / 1080.0;
    float T = u.time * max(u.c.w, 0.0);
    float2 uv = in.uv;
    float4 orig = tex.sample(s, uv);
    // 縦に流れる（同期が外れて画面がロールする）
    uv.y = fract(uv.y + u.a.y * u.time * 0.5);
    float yn = uv.y;
    // 同期くずし：行ごとに横へずれる（ゆっくりした曲がり ＋ ときどき裂ける帯）
    float line = floor(px.y / max(2.0 * k, 1.0));
    float slow = (vn(float2(yn * 6.0, T * 0.7)) - 0.5) * 0.05;
    float q = floor(T * 6.0);
    float band = step(1.0 - u.a.x * 0.35, vn(float2(yn * 4.0 + q * 1.7, q)));
    float tear = (h1(line + floor(T * 30.0)) - 0.5) * 0.3 * band;
    uv.x += u.a.x * slow + tear;
    // ガクッとずれる：ときどき帯ごと大きくずれる・全体が縦に跳ねる
    float jt = floor(T * 8.0);
    if (h1(jt * 1.3 + 0.1) < u.a.z * 0.5) {
        float b0 = h1(jt * 2.1), b1 = b0 + h1(jt * 3.7) * 0.3;
        if (yn > b0 && yn < b1) uv.x += (h1(jt * 5.3) - 0.5) * 0.6;
    }
    if (h1(jt * 7.7 + 0.3) < u.a.z * 0.15) uv.y = fract(uv.y + (h1(jt * 9.1) - 0.5) * 0.3);
    uv.x = fract(uv.x);
    float4 c0 = tex.sample(s, uv);
    float3 yiq = toYIQ(c0.rgb);
    // 色にじみ・色ずれ：色だけ、左から遅れて流れてくる
    float dx = 1.0 / u.size.x;
    float shift = u.b.x * k * dx;
    float2 iq = 0.0; float wsum = 0.0;
    for (int i = 0; i < 8; i++) {
        float w = exp(-float(i) * 0.35);
        float2 qq = uv - float2(shift + float(i) * u.a.w * 7.0 * k * dx, 0.0);
        iq += toYIQ(tex.sample(s, qq).rgb).yz * w; wsum += w;
    }
    iq /= wsum;
    // エンハンサー：輪郭を強める（行き過ぎて輪郭が二重に光る）
    float yl = toYIQ(tex.sample(s, uv - float2(2.5 * k * dx, 0)).rgb).x;
    float yr = toYIQ(tex.sample(s, uv + float2(2.5 * k * dx, 0)).rgb).x;
    float Y = yiq.x + (yiq.x - 0.5 * (yl + yr)) * u.b.w * 5.0 + (yiq.x - yr) * u.b.w * 1.2;
    // ゲイン：入れすぎると白く飽和。折り返しで、明るい所が反転して縞になる
    Y *= u.b.y; iq *= u.b.y;
    float fold = 1.0 - abs(fract(Y * 0.5) * 2.0 - 1.0);
    Y = mix(saturate(Y), fold, u.b.z * step(1.0, Y) + u.b.z * 0.25);
    // 色の発振：色の位相がうなって、虹色の帯になる
    float ph = u.c.x * (sin(yn * 40.0 + T * 5.0) * 0.5 + sin(px.x / u.size.x * 13.0 - T * 3.0 + Y * 8.0)) * 3.14159;
    iq = float2(iq.x * cos(ph) - iq.y * sin(ph), iq.x * sin(ph) + iq.y * cos(ph)) * (1.0 + u.c.x * 0.8);
    float3 rgb = fromYIQ(float3(Y, iq));
    // ノイズ：砂嵐と、ときどき走る白い線
    rgb += (h2(px + floor(T * 60.0) * 1.37) - 0.5) * u.c.y * 0.7;
    if (h1(line * 0.37 + floor(T * 20.0)) > 1.0 - u.c.y * 0.02) rgb = mix(rgb, float3(1.0), 0.75);
    // 走査線
    rgb *= 1.0 - u.c.z * 0.5 * (0.5 + 0.5 * cos(px.y * 3.14159 / max(1.5 * k, 1.0)));
    rgb = saturate(rgb);
    float a = max(c0.a, max(rgb.r, max(rgb.g, rgb.b)));
    return mix(orig, float4(min(rgb, float3(a)), a), saturate(u.mixAmt));
}

// ============ VHS ============
// a = トラッキングのずれ, 下のノイズ, 揺れ, にじみ / b = 色あせ, ドロップアウト, ノイズ, 画質
fragment float4 rt_vhs(VO in [[stage_in]], constant RU& u [[buffer(0)]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 px = in.pos.xy;
    float H = u.size.y, k = H / 1080.0;
    float T = u.time;
    float2 uv = in.uv;
    float4 orig = tex.sample(s, uv);
    float yn = uv.y;
    float dx = 1.0 / u.size.x;
    // テープの揺れ：ゆっくり横にゆらぐ
    float wob = ((vn(float2(yn * 2.0, T * 0.8)) - 0.5) * 0.012 + sin(yn * 30.0 + T * 2.0) * 0.0015) * u.a.z;
    // トラッキングのずれ：ノイズの帯が上から下へ流れ、その中は横に乱れる
    float bandPos = fract(T * 0.11) * 1.3 - 0.15;
    float band = u.a.x * smoothstep(0.07, 0.0, abs(yn - bandPos));
    float jit = (h1(floor(px.y / 2.0) + floor(T * 40.0)) - 0.5) * 0.05 * band;
    // 下のノイズ（ヘッドの切り替え）：画面のいちばん下がずれてざらつく
    float hs = smoothstep(0.955, 0.985, yn) * u.a.y;
    uv.x += wob + jit + hs * (0.03 + (h1(floor(px.y) + T) - 0.5) * 0.02);
    // 横の解像度が低い（明るさは少し、色はもっとぼける。色は右へ遅れる）
    float lw = (1.0 - u.b.w) * 4.0 * k * dx;
    float Y = 0.0;
    for (int i = -2; i <= 2; i++) Y += toYIQ(tex.sample(s, uv + float2(float(i) * lw, 0)).rgb).x;
    Y /= 5.0;
    float cw = (1.0 + u.a.w * 18.0) * k * dx;
    float2 iq = 0.0;
    for (int i = -4; i <= 4; i++) iq += toYIQ(tex.sample(s, uv + float2(float(i) * cw - u.a.w * 6.0 * k * dx, 0)).rgb).yz;
    iq /= 9.0;
    float a = tex.sample(s, uv).a;
    // 色あせ：色が薄く、黒が浮く
    iq *= 1.0 - u.b.x * 0.65;
    Y = Y * (1.0 - u.b.x * 0.18) + u.b.x * 0.07;
    float3 rgb = fromYIQ(float3(Y, iq));
    rgb += float3(0.02, 0.0, -0.015) * u.b.x;
    // ノイズ：ざらつき（帯と下のノイズの所は強く）
    float n = h2(px * 0.7 + floor(T * 30.0) * 3.1) - 0.5;
    rgb += n * (u.b.z * 0.18 + band * 0.6 + hs * 0.5);
    // ドロップアウト：短い白い線が走る
    float2 cell = floor(float2(px.x / (90.0 * k), px.y / max(1.5 * k, 1.0)));
    float dq = floor(T * 30.0);
    if (h2(cell + dq * 0.173) > 1.0 - u.b.y * 0.006) {
        float f = fract(px.x / (90.0 * k));
        rgb = mix(rgb, float3(0.95), smoothstep(0.0, 0.2, f) * smoothstep(1.0, 0.6, f));
    }
    rgb = saturate(rgb);
    a = max(a, max(band, hs) * 0.8);
    return mix(orig, float4(min(rgb, float3(a)), a), saturate(u.mixAmt));
}

// ============ ビデオフィードバック ============
// a = このコマの拡大, 回転（ラジアン）, ずれ x, ずれ y / b = 色相のずれ（0〜1）, 残る割合, 切り抜く明るさ, 重ね方
// c = コントラスト, ぼかし, 縦横比
static float3 hueRot(float3 c, float h) {
    float a = h * 6.2831853;
    float3 k = float3(0.57735);
    float ca = cos(a);
    return c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca);
}
fragment float4 rt_feedback(VO in [[stage_in]], constant RU& u [[buffer(0)]], texture2d<float> cur [[texture(0)]],
                            texture2d<float> prev [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_zero);
    float2 uv = in.uv;
    float A = u.c.z;
    float2 p = (uv - 0.5) * float2(A, 1.0);
    p /= max(u.a.x, 0.01);
    float cr = cos(-u.a.y), sr = sin(-u.a.y);
    p = float2(p.x * cr - p.y * sr, p.x * sr + p.y * cr);
    float2 pu = p / float2(A, 1.0) + 0.5 - u.a.zw;
    float4 f = prev.sample(s, pu);
    if (u.c.y > 0.001) {
        float r = u.c.y * 6.0 / u.size.y;
        f = f * 0.4 + (prev.sample(s, pu + float2(r, 0)) + prev.sample(s, pu - float2(r, 0))
                       + prev.sample(s, pu + float2(0, r)) + prev.sample(s, pu - float2(0, r))) * 0.15;
    }
    f.rgb = hueRot(f.rgb, u.b.x);
    f.rgb = (f.rgb - 0.5 * f.a) * u.c.x + 0.5 * f.a;
    f = max(f, 0.0) * u.b.y;
    float4 c = cur.sample(s, uv);
    // 切り抜く明るさより暗い所は透けて、前の絵が見える
    float l = rlum(c.rgb);
    float key = u.b.z;
    c *= key > 0.001 ? smoothstep(key - 0.04, key + 0.04, l) : 1.0;
    int m = int(u.b.w + 0.5);
    float4 r = m == 1 ? c + f : (m == 2 ? max(c, f) : c + f * (1.0 - c.a));
    return min(r, float4(1.5));
}
fragment float4 rt_out(VO in [[stage_in]], constant RU& u [[buffer(0)]], texture2d<float> cur [[texture(0)]],
                       texture2d<float> res [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 r = res.sample(s, in.uv);
    float a = saturate(r.a);
    r = float4(min(saturate(r.rgb), float3(a)), a);
    return mix(cur.sample(s, in.uv), r, saturate(u.mixAmt));
}

// ============ CRT モニター ============
// a = 走査線, 蛍光体の粒, 粒の大きさ(px), ふくらみ / b = にじむ光, 残光（このコマに残る割合）, 周辺を暗く, 明るさ / c = ちらつき
static float2 crtCurve(float2 uv, float c) {
    float2 p = uv * 2.0 - 1.0;
    p *= 1.0 + c * 0.22 * float2(p.y * p.y, p.x * p.x);
    p /= 1.0 + c * 0.22;
    return p * 0.5 + 0.5;
}
// 1. 蛍光面：ふくらませて、にじむ光を足し、前のコマの光を残す
fragment float4 rt_phosphor(VO in [[stage_in]], constant RU& u [[buffer(0)]], texture2d<float> tex [[texture(0)]],
                            texture2d<float> prev [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_zero);
    float2 uv = crtCurve(in.uv, u.a.w);
    float3 c = tex.sample(s, uv).rgb;
    if (u.b.x > 0.001) {
        float3 g = 0.0;
        float k = u.size.y / 1080.0;
        for (int i = 0; i < 12; i++) {
            float an = float(i) * 0.5235988;
            float2 d = float2(cos(an), sin(an)) / u.size;
            g += tex.sample(s, uv + d * 7.0 * k).rgb * 0.6 + tex.sample(s, uv + d * 18.0 * k).rgb * 0.4;
        }
        c += g / 12.0 * u.b.x * 1.3;
    }
    float3 p = prev.sample(s, in.uv).rgb * u.b.y;
    return float4(max(c, p), 1.0);
}
// 2. 映す：走査線・蛍光体の粒・まわりの暗さ・ちらつき
fragment float4 rt_crt(VO in [[stage_in]], constant RU& u [[buffer(0)]], texture2d<float> ph [[texture(0)]],
                       texture2d<float> cur [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 px = in.pos.xy;
    float k = u.size.y / 1080.0;
    float2 cuv = crtCurve(in.uv, u.a.w);
    float3 c = ph.sample(s, in.uv).rgb;
    // 走査線（明るい所は線が太って目立たない）
    float lines = u.size.y / max(3.0 * k, 1.0);
    float sl = 0.5 + 0.5 * cos(cuv.y * lines * 6.2831853);
    c *= 1.0 - u.a.x * (1.0 - sl) * (1.0 - saturate(rlum(c)) * 0.5);
    // 蛍光体の粒（縦の RGB の筋）
    float cell = max(u.a.z * k, 1.0);
    int idx = int(fmod(floor(px.x / cell), 3.0));
    float3 m = float3(0.3);
    if (idx == 0) m.r = 1.0; else if (idx == 1) m.g = 1.0; else m.b = 1.0;
    c *= mix(float3(1.0), m * 1.6, u.a.y);
    // 画面の外は黒、角は丸く、まわりを暗く
    float2 q = cuv * 2.0 - 1.0;
    float2 e = max(abs(q) - (1.0 - 0.06), 0.0);
    float corner = 1.0 - smoothstep(0.0, 0.02, length(e) - 0.04);
    if (any(cuv < 0.0) || any(cuv > 1.0)) corner = 0.0;
    c *= mix(1.0, smoothstep(1.6, 0.5, length(q)), u.b.z) * corner;
    c *= u.b.w * (1.0 - u.c.x * 0.12 * h1(floor(u.time * 60.0)));
    return mix(cur.sample(s, in.uv), float4(saturate(c), 1.0), saturate(u.mixAmt));
}

// ============ ラスタースキャン ============
// a = 線の数, 持ち上げる高さ, 線の太さ(px), 奥への傾き / b = 色の付け方, 明るさ, 波, 1 本の点の数
// c = 経過秒, 描くもの（0 = 線, 1 = 後ろを隠す黒）, 0, 0 / color = 1 色のときの色
struct RSU { float4 a, b, c; float4 color; float2 size; };
vertex VO rt_raster_v(uint vid [[vertex_id]], uint iid [[instance_id]], constant RSU& u [[buffer(0)]],
                      texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float N = u.a.x, M = u.b.w;
    float j = float(vid >> 1);
    float side = float(vid & 1);
    float x = j / M;
    float v = (float(iid) + 0.5) / N;
    float4 c = tex.sample(s, float2(x, v), level(0.0));
    float l = c.a > 1e-4 ? rlum(c.rgb / c.a) * c.a : 0.0;
    float tilt = u.a.w;
    // 奥（上）ほど線が詰まり、横幅が狭い
    float vy = mix(v, pow(v, 1.7), tilt);
    float depthScale = mix(1.0, 0.45 + 0.55 * v, tilt);
    float lift = u.a.y * (l + u.b.z * 0.25 * sin(x * 14.0 + u.c.x * 3.0 + v * 9.0)) * depthScale;
    float y = vy - lift;
    float xs = 0.5 + (x - 0.5) * depthScale * mix(1.0, 1.25, tilt);
    float thick = u.a.z / u.size.y;
    float yy;
    if (u.c.y > 0.5) {
        // 後ろを隠す黒：線から、自分の下の線のあたりまで
        yy = side < 0.5 ? y + thick * 0.5 : vy + 1.5 / N;
    } else {
        yy = y + (side - 0.5) * thick;
    }
    VO o;
    o.pos = float4(xs * 2.0 - 1.0, 1.0 - yy * 2.0, 1.0 - (float(iid) + 1.0) / (N + 2.0) - (u.c.y > 0.5 ? 0.0 : 0.5 / (N + 2.0)), 1.0);
    o.uv = float2(x, v);
    int mode = int(u.b.x + 0.5);
    float3 col = mode == 0 ? (c.a > 1e-4 ? c.rgb / c.a : float3(0.0)) : (mode == 1 ? u.color.rgb * (0.25 + 0.75 * l) : float3(l));
    col = max(col, float3(0.08)) * u.b.y;
    o.col = u.c.y > 0.5 ? float4(0.0, 0.0, 0.0, 1.0) : float4(col, 1.0);
    return o;
}
fragment float4 rt_raster_f(VO in [[stage_in]]) { return float4(saturate(in.col.rgb), 1.0); }
fragment float4 rt_under(VO in [[stage_in]], constant float& k [[buffer(0)]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv) * k;
}
"""

private struct RetroUniforms {
    var a = SIMD4<Float>.zero, b = SIMD4<Float>.zero, c = SIMD4<Float>.zero, d = SIMD4<Float>.zero
    var size = SIMD2<Float>.zero
    var time: Float = 0
    var mixAmt: Float = 1
}

private struct RasterUniforms {
    var a = SIMD4<Float>.zero, b = SIMD4<Float>.zero, c = SIMD4<Float>.zero
    var color = SIMD4<Float>(1, 1, 1, 1)
    var size = SIMD2<Float>.zero
}

final class RetroRenderer {
    static let shared = RetroRenderer()
    let device = MetalContext.shared.device
    let glitch, vhs, feedback16, out, phosphor16, crt, raster, rasterHide, under: MTLRenderPipelineState
    let depthOn: MTLDepthStencilState

    private init() {
        let dev = MetalContext.shared.device
        let lib: MTLLibrary
        do { lib = try dev.makeLibrary(source: retroShaderSource, options: nil) } catch {
            fatalError("アナログ機材のシェーダーを作れません: \(error)")
        }
        func r(_ v: String, _ f: String, _ fmt: MTLPixelFormat = .bgra8Unorm, depth: Bool = false,
               noColor: Bool = false) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = fmt
            if noColor { d.colorAttachments[0].writeMask = [] }
            if depth { d.depthAttachmentPixelFormat = .depth32Float }
            return try! dev.makeRenderPipelineState(descriptor: d)
        }
        glitch = r("rt_full", "rt_glitch")
        vhs = r("rt_full", "rt_vhs")
        feedback16 = r("rt_full", "rt_feedback", .rgba16Float)
        out = r("rt_full", "rt_out")
        phosphor16 = r("rt_full", "rt_phosphor", .rgba16Float)
        crt = r("rt_full", "rt_crt")
        raster = r("rt_raster_v", "rt_raster_f", depth: true)
        // 後ろの線を隠す：色は塗らずに奥行きだけ書く（線の間は透明のまま）
        rasterHide = r("rt_raster_v", "rt_raster_f", depth: true, noColor: true)
        under = r("rt_full", "rt_under", depth: true)
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthOn = dev.makeDepthStencilState(descriptor: dd)!
    }

    func canvas(_ w: Int, _ h: Int) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        return device.makeTexture(descriptor: td)
    }

    fileprivate func pass(_ dst: MTLTexture, _ pipe: MTLRenderPipelineState, cb: MTLCommandBuffer, clear: Bool = false,
                          _ setup: (MTLRenderCommandEncoder) -> Void) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = clear ? .clear : .dontCare
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        e.setRenderPipelineState(pipe)
        setup(e)
        e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        e.endEncoding()
    }

    /// 透明で埋める（作ったばかりの絵は中身が決まっていない）
    func clear(_ t: MTLTexture, cb: MTLCommandBuffer) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = t
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
    }

    /// 1 回描くだけのもの（グリッチボックス・VHS）
    func simple(_ e: Effect, input: MTLTexture, into dst: MTLTexture, now: Double, stack: EffectStack, mixAmt: Float,
                cb: MTLCommandBuffer) {
        func v(_ i: Int) -> Float { i < e.kind.params.count ? Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) : 0 }
        var u = RetroUniforms(a: SIMD4(v(0), v(1), v(2), v(3)), b: SIMD4(v(4), v(5), v(6), v(7)),
                              c: SIMD4(v(8), v(9), v(10), v(11)), size: SIMD2(Float(dst.width), Float(dst.height)),
                              time: Float(max(now - stack.origin, 0).truncatingRemainder(dividingBy: 10000)), mixAmt: mixAmt)
        pass(dst, e.kind == .glitchBox ? glitch : vhs, cb: cb) { enc in
            enc.setFragmentBytes(&u, length: MemoryLayout<RetroUniforms>.stride, index: 0)
            enc.setFragmentTexture(input, index: 0)
        }
    }
}

/// ビデオフィードバック：前のコマを覚えて、拡大・回転・ずらして重ね続ける
final class FeedbackSim {
    var canvas: [MTLTexture] = []
    var cur = 0
    var fresh = true

    func render(_ e: Effect, input: MTLTexture, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack,
                mixAmt: Float, cb: MTLCommandBuffer) {
        let r = RetroRenderer.shared
        func v(_ i: Int) -> Double { e.value(i, at: now, beat: stack.beat, origin: stack.origin) }
        if canvas.count != 2 || canvas[0].width != input.width || canvas[0].height != input.height {
            canvas = (0..<2).compactMap { _ in r.canvas(input.width, input.height) }
            fresh = true
        }
        guard canvas.count == 2 else { return }
        if fresh {
            for c in canvas { r.clear(c, cb: cb) }
            fresh = false
        }
        // 止まっている間は進めない（同じ絵のまま）
        if dt > 0 {
            // 値は「1 秒あたり」。このコマの分に直す（フレームレートが違っても同じ速さ）
            let step = min(dt, 0.1)
            let A = Double(input.width) / Double(max(input.height, 1))
            var u = RetroUniforms(
                a: SIMD4(Float(pow(max(v(0), 0.05), step)), Float(v(1) * .pi / 180 * step), Float(v(2) * step), Float(v(3) * step)),
                b: SIMD4(Float(v(4) / 360 * step), Float(pow(min(max(v(5), 0), 1), step)), Float(v(6)), Float(v(7).rounded())),
                c: SIMD4(Float(1 + (v(8) - 1) * step * 4), Float(v(9)), Float(A), 0),
                size: SIMD2(Float(input.width), Float(input.height)), time: 0, mixAmt: mixAmt)
            let next = 1 - cur
            r.pass(canvas[next], r.feedback16, cb: cb) { enc in
                enc.setFragmentBytes(&u, length: MemoryLayout<RetroUniforms>.stride, index: 0)
                enc.setFragmentTexture(input, index: 0)
                enc.setFragmentTexture(canvas[cur], index: 1)
            }
            cur = next
        }
        var o = RetroUniforms(); o.mixAmt = mixAmt
        r.pass(dst, r.out, cb: cb) { enc in
            enc.setFragmentBytes(&o, length: MemoryLayout<RetroUniforms>.stride, index: 0)
            enc.setFragmentTexture(input, index: 0)
            enc.setFragmentTexture(canvas[cur], index: 1)
        }
    }
}

/// CRT モニター：蛍光面（残光のために前のコマを覚える）に映して、走査線・蛍光体の粒をかける
final class CRTSim {
    var canvas: [MTLTexture] = []
    var cur = 0
    var fresh = true

    func render(_ e: Effect, input: MTLTexture, into dst: MTLTexture, dt: Double, now: Double, stack: EffectStack,
                mixAmt: Float, cb: MTLCommandBuffer) {
        let r = RetroRenderer.shared
        func v(_ i: Int) -> Float { Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) }
        if canvas.count != 2 || canvas[0].width != input.width || canvas[0].height != input.height {
            canvas = (0..<2).compactMap { _ in r.canvas(input.width, input.height) }
            fresh = true
        }
        guard canvas.count == 2 else { return }
        if fresh { for c in canvas { r.clear(c, cb: cb) } }
        // 残光：1/60 秒で残る割合を、このコマの分に
        let keep = Float(pow(Double(min(max(v(5), 0), 0.98)) * 0.95, max(dt, 0) * 60))
        var u = RetroUniforms(a: SIMD4(v(0), v(1), v(2), v(3)), b: SIMD4(v(4), fresh ? 0 : keep, v(6), v(7)),
                              c: SIMD4(v(8), 0, 0, 0), size: SIMD2(Float(input.width), Float(input.height)),
                              time: Float(max(now - stack.origin, 0).truncatingRemainder(dividingBy: 10000)), mixAmt: mixAmt)
        if dt > 0 || fresh {
            let next = 1 - cur
            r.pass(canvas[next], r.phosphor16, cb: cb) { enc in
                enc.setFragmentBytes(&u, length: MemoryLayout<RetroUniforms>.stride, index: 0)
                enc.setFragmentTexture(input, index: 0)
                enc.setFragmentTexture(canvas[cur], index: 1)
            }
            cur = next
            fresh = false
        }
        r.pass(dst, r.crt, cb: cb) { enc in
            enc.setFragmentBytes(&u, length: MemoryLayout<RetroUniforms>.stride, index: 0)
            enc.setFragmentTexture(canvas[cur], index: 0)
            enc.setFragmentTexture(input, index: 1)
        }
    }
}

/// ラスタースキャン：横の走査線を、明るい所ほど持ち上げて描く
final class RasterSim {
    var depth: MTLTexture?

    func render(_ e: Effect, input: MTLTexture, into dst: MTLTexture, now: Double, stack: EffectStack, mixAmt: Float,
                cb: MTLCommandBuffer) {
        let r = RetroRenderer.shared
        func v(_ i: Int) -> Float { Float(e.value(i, at: now, beat: stack.beat, origin: stack.origin)) }
        if depth?.width != dst.width || depth?.height != dst.height {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: dst.width, height: dst.height,
                                                              mipmapped: false)
            td.usage = [.renderTarget]
            td.storageMode = .private
            depth = r.device.makeTexture(descriptor: td)
        }
        guard let depth else { return }
        let N = max(v(0).rounded(), 2)
        let M = Float(min(max(dst.width / 2, 32), 960))
        let k = Float(dst.height) / 1080
        var u = RasterUniforms(a: SIMD4(N, v(1), max(v(2) * k, 0.75), v(3)), b: SIMD4(v(4).rounded(), v(5), v(6), M),
                               c: SIMD4(Float(max(now - stack.origin, 0).truncatingRemainder(dividingBy: 10000)), 0, 0, 0),
                               color: e.color.simd, size: SIMD2(Float(dst.width), Float(dst.height)))
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1
        rpd.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        // 下に元の絵を薄く（不透明度が低いときは、元の絵がそのまま見えてくる）
        var under = v(7) + (1 - mixAmt)
        if under > 0.001 {
            enc.setRenderPipelineState(r.under)
            enc.setFragmentBytes(&under, length: 4, index: 0)
            enc.setFragmentTexture(input, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.setRenderPipelineState(r.raster)
        enc.setDepthStencilState(r.depthOn)
        enc.setVertexTexture(input, index: 0)
        let count = Int(N)
        if mixAmt > 0.001 {
            if v(8) > 0.5 {
                enc.setRenderPipelineState(r.rasterHide)
                u.c.y = 1
                enc.setVertexBytes(&u, length: MemoryLayout<RasterUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Int(M + 1) * 2, instanceCount: count)
            }
            enc.setRenderPipelineState(r.raster)
            u.c.y = 0
            u.b.y *= mixAmt
            enc.setVertexBytes(&u, length: MemoryLayout<RasterUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Int(M + 1) * 2, instanceCount: count)
        }
        enc.endEncoding()
    }
}
